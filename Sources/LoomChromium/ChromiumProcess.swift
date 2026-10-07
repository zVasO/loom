import LoomCore
import Darwin
import Dispatch
import Foundation

/// What to start (ADR-0016). `arguments` are the flags; the two the transport
/// depends on, `--remote-debugging-pipe` and `--user-data-dir`, are appended by
/// the launch unless the plan names them already. Branded Chrome refuses the
/// pipe on its default profile, so a profile is always given.
public struct ChromiumLaunchPlan: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var userDataDirectory: URL

    public init(executable: URL, arguments: [String],
                environment: [String: String] = ChromiumLaunchPlan.minimalEnvironment(),
                userDataDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.userDataDirectory = userDataDirectory
    }

    /// The command line as spawned. Appended rather than prepended: Chromium
    /// reads switches anywhere before `--`.
    public var spawnArguments: [String] {
        var result = arguments
        let pipeFlag = "--remote-debugging-pipe"
        if !arguments.contains(where: { $0 == pipeFlag || $0.hasPrefix(pipeFlag + "=") }) {
            result.append(pipeFlag)
        }
        if !arguments.contains(where: { $0.hasPrefix("--user-data-dir=") }) {
            result.append("--user-data-dir=\(userDataDirectory.path)")
        }
        return result
    }

    /// The few variables a browser needs. The rest of Loom's environment
    /// (tokens, agent settings, a developer's proxies) stays out of a process
    /// that runs untrusted pages.
    public static func minimalEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = base[key] { environment[key] = value }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }
}

/// `Browser.getVersion`'s answer.
public struct ChromiumVersion: Sendable, Equatable {
    /// "HeadlessChrome/141.0.7390.37", "Chrome/141.0.7390.37".
    public var product: String
    public var major: Int
    public var userAgent: String
    public var protocolVersion: String

    public init(product: String, major: Int, userAgent: String, protocolVersion: String) {
        self.product = product
        self.major = major
        self.userAgent = userAgent
        self.protocolVersion = protocolVersion
    }

    /// The oldest Chromium Loom drives. Newer events (`Page.frameStartedNavigating`,
    /// the dialog's `frameId`) are used when they show up, never required.
    public static let minimumMajor = 120

    public var isSupported: Bool { major >= Self.minimumMajor }
}

/// How the browser process ended: its exit status, or the signal that killed it.
public enum ChromiumExit: Sendable, Equatable, CustomStringConvertible {
    case status(Int32)
    case signal(Int32)

    /// waitpid's status decoded by hand: the W* macros are not imported into Swift.
    init(waitStatus: Int32) {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            self = .status((waitStatus >> 8) & 0xff)
        } else {
            self = .signal(signal)
        }
    }

    public var description: String {
        switch self {
        case .status(let code): return "status \(code)"
        case .signal(let number): return "signal \(number)"
        }
    }
}

public enum ChromiumProcessError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The process ended before it answered; its stderr says why.
    case exitedBeforeReady(ChromiumExit, stderrTail: String)
    /// No answer in time, or the pipe failed while the process lives on.
    case notReady(reason: String, stderrTail: String)
    /// It answered with a product no version could be read from.
    case unreadableVersion(product: String)

    /// Another Chromium holds the profile's SingletonLock: an orphan of a
    /// crashed Loom, to sweep before one retry.
    public var isProfileInUse: Bool {
        let tail: String
        switch self {
        case .exitedBeforeReady(_, let stderrTail), .notReady(_, let stderrTail): tail = stderrTail
        case .unreadableVersion: return false
        }
        return tail.contains("ProcessSingleton") || tail.contains("SingletonLock")
            || tail.contains("profile appears to be in use")
    }

    public var description: String {
        switch self {
        case .exitedBeforeReady(let exit, let tail):
            return "Chromium exited (\(exit)) before answering" + Self.lastLines(tail)
        case .notReady(let reason, let tail):
            return "Chromium did not answer: \(reason)" + Self.lastLines(tail)
        case .unreadableVersion(let product):
            return "Chromium answered with an unreadable version: \"\(product)\""
        }
    }

    private static func lastLines(_ tail: String) -> String {
        let lines = tail.split(separator: "\n").suffix(8)
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }
}

/// One Chromium: its pipe, its exit, its stderr, its shutdown ladder.
///
/// The object lives as long as its child: the exit and stderr handlers hold
/// it until the child is reaped and its stderr closed, so a dropped instance
/// never leaves a zombie or a blocked writer behind.
public final class ChromiumProcess: @unchecked Sendable {

    public let pid: pid_t
    /// Created on the spawned fds and already started.
    public let connection: CDPConnection

    /// The stderr kept for diagnostics: Chromium's last words before an early exit.
    static let stderrTailBytes = 64 << 10

    private let log: @Sendable (String) -> Void
    private let exitQueue: DispatchQueue
    private let stderrQueue: DispatchQueue
    private let exitSource: DispatchSourceProcess
    private let stderrChannel: DispatchIO

    private let lock = NSLock()
    private var exitStorage: ChromiumExit?
    private var exitWaiters: [CheckedContinuation<ChromiumExit, Never>] = []
    private var cancellableWaiters: [Int: CheckedContinuation<ChromiumExit, Error>] = [:]
    private var nextWaiter = 0
    private var stderrBuffer = Data()
    private var stderrClosed = false

    public static func launch(_ plan: ChromiumLaunchPlan,
                              log: @escaping @Sendable (String) -> Void = { _ in }) throws -> ChromiumProcess {
        // Chromium would create it with Loom's umask; the profile holds cookies.
        // One left by an earlier run with wider rights is tightened too.
        let profile = plan.userDataDirectory
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        let child = try ChromiumSpawn.spawn(executable: plan.executable.path, arguments: plan.spawnArguments,
                                            environment: plan.environment)
        let pid = child.pid
        log("chromium \(pid): started \(plan.executable.lastPathComponent)")
        let process = ChromiumProcess(child: child, log: log)
        process.connection.start(onClose: { reason in log("chromium \(pid): pipe closed (\(reason))") })
        return process
    }

    private init(child: ChromiumSpawnedChild, log: @escaping @Sendable (String) -> Void) {
        pid = child.pid
        self.log = log
        exitQueue = DispatchQueue(label: "app.loom.chromium.exit.\(child.pid)")
        stderrQueue = DispatchQueue(label: "app.loom.chromium.stderr.\(child.pid)", qos: .utility)
        connection = CDPConnection(read: child.readDescriptor, write: child.writeDescriptor,
                                   label: "\(child.pid)", log: log)
        exitSource = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: exitQueue)
        let stderrDescriptor = child.stderrDescriptor
        // The fd is closed ONLY by the cleanup handler (ForkPTYChannel's rule).
        stderrChannel = DispatchIO(type: .stream, fileDescriptor: stderrDescriptor, queue: stderrQueue,
                                   cleanupHandler: { _ in Darwin.close(stderrDescriptor) })

        // Handler installed BEFORE activate(): a child that exits at once is still reaped.
        exitSource.setEventHandler { self.reap(afterExitNote: true) }
        exitSource.activate()
        // A child gone before its source existed: reaped here should the note never come.
        exitQueue.async { self.reap(afterExitNote: false) }

        stderrChannel.setLimit(lowWater: 1)
        stderrChannel.read(offset: 0, length: Int.max, queue: stderrQueue) { done, data, _ in
            if let data, !data.isEmpty {
                self.keepStderr(Array(data))
            }
            if done {
                self.lock.withLock { self.stderrClosed = true }
                self.stderrChannel.close(flags: [])
            }
        }
    }

    // MARK: - Readiness

    /// The first answer to `Browser.getVersion`: pipe mode prints no
    /// "DevTools listening" line. An exit before it throws with the stderr tail.
    public func ready(timeout: Duration) async throws -> ChromiumVersion {
        let deadline = ContinuousClock.now + timeout
        let connection = self.connection
        let outcome = await withTaskGroup(of: ReadyOutcome.self, returning: ReadyOutcome.self) { group in
            group.addTask {
                do {
                    let result = try await connection.call("Browser.getVersion",
                                                           options: CDPCallOptions(deadline: deadline))
                    return .answered(result)
                } catch let error as CDPError {
                    return .failed(error)
                } catch {
                    return .failed(.disconnected(String(describing: error)))
                }
            }
            group.addTask {
                if let exit = try? await self.cancellableExit() { return .exited(exit) }
                return .cancelled
            }
            // A backstop, should the transport's own deadline never fire.
            group.addTask {
                do {
                    try await Task.sleep(for: timeout + .milliseconds(500))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            var first = ReadyOutcome.cancelled
            while let next = await group.next() {
                if case .cancelled = next { continue }
                first = next
                break
            }
            group.cancelAll()
            return first
        }

        switch outcome {
        case .answered(let result):
            let product = result.string("product") ?? ""
            guard let version = Self.parseVersion(product: product,
                                                  userAgent: result.string("userAgent") ?? "",
                                                  protocolVersion: result.string("protocolVersion") ?? "") else {
                throw ChromiumProcessError.unreadableVersion(product: product)
            }
            log("chromium \(pid): ready, \(version.product)")
            return version
        case .exited(let exit):
            let error = await earlyExitError(exit)
            throw error
        case .failed(let error):
            if Task.isCancelled { throw CancellationError() }
            if case .timeout = error {
                throw ChromiumProcessError.notReady(reason: "no answer to Browser.getVersion within \(timeout)",
                                                    stderrTail: stderrTail)
            }
            // A broken pipe is most often a process on its way out: its exit says more.
            if let exit = await waitForExit(upTo: .seconds(1)) {
                let early = await earlyExitError(exit)
                throw early
            }
            throw ChromiumProcessError.notReady(reason: "\(error)", stderrTail: stderrTail)
        case .timedOut:
            throw ChromiumProcessError.notReady(reason: "no answer to Browser.getVersion within \(timeout)",
                                                stderrTail: stderrTail)
        case .cancelled:
            throw CancellationError()
        }
    }

    private enum ReadyOutcome: Sendable {
        case answered(CDPObject)
        case failed(CDPError)
        case exited(ChromiumExit)
        case timedOut
        case cancelled
    }

    private func earlyExitError(_ exit: ChromiumExit) async -> ChromiumProcessError {
        await stderrSettled(within: .milliseconds(500))
        return .exitedBeforeReady(exit, stderrTail: stderrTail)
    }

    /// "HeadlessChrome/141.0.7390.37" → 141, the number after the product's
    /// last slash; the user agent's `Chrome/` token when the product has none.
    public static func parseVersion(product: String, userAgent: String, protocolVersion: String) -> ChromiumVersion? {
        var major: Int? = nil
        if let slash = product.lastIndex(of: "/") {
            major = leadingNumber(in: product[product.index(after: slash)...])
        }
        if major == nil, let token = userAgent.range(of: "Chrome/") {
            major = leadingNumber(in: userAgent[token.upperBound...])
        }
        guard let major else { return nil }
        return ChromiumVersion(product: product, major: major, userAgent: userAgent, protocolVersion: protocolVersion)
    }

    /// The digits the text starts with, up to the first non-digit; nil for none or zero.
    private static func leadingNumber(in text: Substring) -> Int? {
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        guard let number = Int(digits), number > 0 else { return nil }
        return number
    }

    // MARK: - Exit

    /// The exit, once it happened; nil while the process runs.
    public var knownExit: ChromiumExit? { lock.withLock { exitStorage } }

    /// Waits for the exit. Not cancellable: the process always ends, and
    /// `shutdown` makes sure of it.
    public func exited() async -> ChromiumExit {
        await withCheckedContinuation { (continuation: CheckedContinuation<ChromiumExit, Never>) in
            lock.lock()
            if let exit = exitStorage {
                lock.unlock()
                continuation.resume(returning: exit)
                return
            }
            exitWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// The exit, if it comes within `limit`.
    func waitForExit(upTo limit: Duration) async -> ChromiumExit? {
        if let exit = knownExit { return exit }
        let first = await withTaskGroup(of: ChromiumExit?.self, returning: ChromiumExit?.self) { group in
            group.addTask { try? await self.cancellableExit() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let next = await group.next() ?? nil
            group.cancelAll()
            return next
        }
        return first ?? knownExit
    }

    /// `exited()` for task groups: a cancelled wait throws instead of
    /// holding its group open until the process ends.
    private func cancellableExit() async throws -> ChromiumExit {
        let token: Int = lock.withLock {
            nextWaiter += 1
            return nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChromiumExit, Error>) in
                lock.lock()
                if let exit = exitStorage {
                    lock.unlock()
                    continuation.resume(returning: exit)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancellableWaiters[token] = continuation
                lock.unlock()
            }
        } onCancel: {
            let waiter = lock.withLock { cancellableWaiters.removeValue(forKey: token) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// On `exitQueue`. A WNOHANG that finds nothing right after the exit note
    /// falls back to a blocking wait: the child has exited, so it returns at once.
    private func reap(afterExitNote: Bool) {
        if knownExit != nil {
            exitSource.cancel()
            return
        }
        var status: Int32 = 0
        var result: pid_t = 0
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 && afterExitNote {
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
        }
        if result == pid {
            record(ChromiumExit(waitStatus: status))
        } else if result < 0 && afterExitNote {
            // Reaped by someone else (SIGCHLD ignored): gone, status unknown.
            record(.status(-1))
        }
    }

    private func record(_ exit: ChromiumExit) {
        lock.lock()
        guard exitStorage == nil else {
            lock.unlock()
            return
        }
        exitStorage = exit
        let waiters = exitWaiters
        exitWaiters = []
        let cancellable = Array(cancellableWaiters.values)
        cancellableWaiters = [:]
        lock.unlock()
        exitSource.cancel()
        log("chromium \(pid): exited, \(exit)")
        for waiter in waiters { waiter.resume(returning: exit) }
        for waiter in cancellable { waiter.resume(returning: exit) }
    }

    // MARK: - Shutdown

    /// `Browser.close`, the clean exit that flushes cookies, given `grace`;
    /// then the pipe's EOF, which Chromium also treats as a clean close, for a
    /// second at most; then SIGTERM to the group for 2 s; then SIGKILL.
    /// Returns once the process is gone, or 2 s after the SIGKILL.
    public func shutdown(grace: Duration = .seconds(2)) async {
        // In a task of its own: a cancelled caller must not skip the waits
        // that let Chromium flush its profile.
        await Task { await self.climbShutdownLadder(grace: grace) }.value
    }

    private func climbShutdownLadder(grace: Duration) async {
        defer { connection.close() }
        guard knownExit == nil else { return }
        if !connection.isClosed {
            connection.post("Browser.close")
        }
        if await waitForExit(upTo: grace) != nil { return }
        connection.close()
        if await waitForExit(upTo: min(grace, Duration.seconds(1))) != nil { return }
        log("chromium \(pid): no exit after Browser.close and EOF, SIGTERM to its group")
        signalGroup(SIGTERM)
        if await waitForExit(upTo: .seconds(2)) != nil { return }
        log("chromium \(pid): SIGKILL to its group")
        signalGroup(SIGKILL)
        _ = await waitForExit(upTo: .seconds(2))
    }

    /// The whole group: renderers and the GPU process go with the browser.
    /// Never once the child is reaped: its pid, and so its group's number,
    /// may belong to a stranger by then.
    private func signalGroup(_ number: Int32) {
        guard knownExit == nil else { return }
        if kill(-pid, number) != 0 && errno == ESRCH {
            _ = kill(pid, number)
        }
    }

    // MARK: - stderr

    /// The last 64 KB Chromium wrote to stderr. Drained continuously on a
    /// queue of its own, so a chatty Chromium never blocks on a full pipe.
    public var stderrTail: String {
        let bytes = lock.withLock { stderrBuffer.suffix(Self.stderrTailBytes) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func keepStderr(_ bytes: [UInt8]) {
        lock.lock()
        stderrBuffer.append(contentsOf: bytes)
        // Trimmed by halves, not on every write: one copy per 64 KB received.
        if stderrBuffer.count > 2 * Self.stderrTailBytes {
            stderrBuffer = Data(stderrBuffer.suffix(Self.stderrTailBytes))
        }
        lock.unlock()
    }

    /// An exit is noticed before the last of its stderr is read: waits, a
    /// bounded time, for stderr's end.
    func stderrSettled(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if lock.withLock({ stderrClosed }) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
