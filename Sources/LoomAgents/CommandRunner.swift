import Darwin
import Foundation
import LoomAPI
import LoomCore

/// A workflow's command step (ADR-0019): one shell line in the run's folder
/// — tests, a linter — its exit code and the end of its output. Never a
/// template in the line: what it needs comes as `LOOM_*` variables. The
/// environment loses what would tie it to a session or to Loom's socket.
public enum CommandRunner {

    public struct Request: Sendable, Equatable {
        public var command: String
        public var workingDirectory: URL
        public var timeout: TimeInterval
        /// On top of the user's environment (`LOOM_PR_NUMBER`…).
        public var environment: [String: String]
        /// Bytes kept from the end of stdout and of stderr each.
        public var outputLimit: Int

        public init(command: String, workingDirectory: URL, timeout: TimeInterval = 600,
                    environment: [String: String] = [:], outputLimit: Int = 8_192) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.timeout = timeout
            self.environment = environment
            self.outputLimit = outputLimit
        }
    }

    public struct Result: Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case launchFailed(String)
        case cancelled

        public var description: String {
            switch self {
            case .launchFailed(let message): return "the command could not start: \(message)"
            case .cancelled: return "the command was stopped"
            }
        }
    }

    /// The user's environment, less Loom's own keys, plus the step's.
    public static func environment(from base: [String: String], adding extra: [String: String]) -> [String: String] {
        var environment = ClaudeOneShot.environment(from: base)
        environment[APIProtocol.workflowRoleEnvironmentKey] = nil
        environment[APIProtocol.browserEngineEnvironmentKey] = nil
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// The last `limit` bytes, as text.
    static func tail(_ data: Data, limit: Int) -> String {
        let kept = data.count > limit ? data.suffix(limit) : data
        let text = String(decoding: kept, as: UTF8.self)
        return data.count > limit ? "…" + text : text
    }

    /// Runs the line with `shell -lc` and waits. A timeout stops it and its
    /// children and answers `timedOut`; cancelling the task does the same
    /// and throws `.cancelled`.
    public static func run(_ request: Request, shell: URL = URL(fileURLWithPath: "/bin/zsh"),
                           environment base: [String: String] = ProcessInfo.processInfo.environment) async throws -> Result {
        let process = Process()
        process.executableURL = shell
        process.arguments = ["-lc", request.command]
        process.currentDirectoryURL = request.workingDirectory
        process.environment = environment(from: base, adding: request.environment)
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let run = Stopper()
        let outcome: (Int32, Data, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, out, err in
                        run.finished()
                        continuation.resume(returning: (status, out, err))
                    }
                } catch {
                    continuation.resume(throwing: Failure.launchFailed("\(error)"))
                    return
                }
                run.started(process)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + request.timeout) {
                    run.stop(cancelled: false)
                }
            }
        } onCancel: {
            run.stop(cancelled: true)
        }
        if run.wasCancelled { throw Failure.cancelled }
        let (status, out, err) = outcome
        return Result(exitCode: status, stdout: tail(out, limit: request.outputLimit),
                      stderr: tail(err, limit: request.outputLimit), timedOut: run.timedOut)
    }

    /// The process, and whether it was stopped — shared between the caller,
    /// the timeout and the cancellation handler.
    private final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var pending: Bool?
        private var isFinished = false
        private(set) var timedOut = false
        private(set) var wasCancelled = false

        func started(_ process: Process) {
            lock.lock()
            self.process = process
            let stopNow = pending != nil
            lock.unlock()
            if stopNow { Self.terminate(process) }
        }

        func finished() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        func stop(cancelled: Bool) {
            lock.lock()
            guard !isFinished, !timedOut, !wasCancelled else { lock.unlock(); return }
            if cancelled { wasCancelled = true } else { timedOut = true }
            let process = self.process
            if process == nil { pending = cancelled }
            lock.unlock()
            if let process { Self.terminate(process) }
        }

        /// The shell and everything it started — a test runner's workers
        /// would keep the pipes open — SIGTERM, then SIGKILL.
        private static func terminate(_ process: Process) {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            let tree = descendants(of: pid)
            for child in tree { kill(child, SIGTERM) }
            process.terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                for child in tree { kill(child, SIGKILL) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        /// Every process under `pid`, deepest last.
        private static func descendants(of pid: pid_t) -> [pid_t] {
            var found: [pid_t] = []
            var queue = [pid]
            while let parent = queue.popLast(), found.count < 512 {
                let children = childPIDs(of: parent)
                found += children
                queue += children
            }
            return found
        }

        private static func childPIDs(of pid: pid_t) -> [pid_t] {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", String(pid)]
            let out = Pipe()
            pgrep.standardOutput = out
            pgrep.standardError = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            pgrep.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .compactMap { pid_t(String($0)) }
        }
    }
}
