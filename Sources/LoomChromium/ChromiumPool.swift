import Darwin
import Dispatch
import Foundation

// ChromiumPool — every Chromium the agents' browsers run (ADR-0016).
//
//   init(profiles:network:executable:…)   sweeps `private/` (a Loom that died)
//   acquire(_ key) → ChromiumLease        launches lazily; a private key's lease
//                                         carries a fresh browser context
//   release(_ lease)                      the last one starts the idle grace (60 s)
//   setNetworkMode(_:)                    relaunches what runs on another mode
//   stop(_:reason:)                       e.g. browser tools turned off
//   clearProfile(_:), removeProfile(_:)   stop the project's process, then the disk
//   shutdownAll(grace:)                   app quit; nothing launches afterwards
//
// One process per key: a project's profile can be held by one Chromium only
// (SingletonLock), and its sessions are targets of that process, each in a
// window of its own. The private process serves every review and every
// session without a project, a browser context each. Launches are serialized
// per key: concurrent first acquires share one. A process that dies is not
// relaunched here — its owners hear `browserClosed` and the next acquire
// launches again, unless it died more than 3 times in 5 minutes.

/// Which Chromium a session's browser runs in.
public enum ChromiumProfileKey: Hashable, Sendable, CustomStringConvertible {
    /// A project's persistent profile, by its store identifier
    /// (`AgentBrowserProfile.storeIdentifier(forProject:)`).
    case project(UUID)
    /// The shared private process: reviews and sessions without a project.
    case privateShared

    public var description: String {
        switch self {
        case .project(let identifier): return "project \(identifier.uuidString)"
        case .privateShared: return "private"
        }
    }
}

/// A hold on a running Chromium: the process stays while one is held.
/// Released once, through the pool.
public final class ChromiumLease: Sendable {
    public let key: ChromiumProfileKey
    public let browser: ChromiumBrowser
    /// A private lease's own context: its targets are created in it. nil for a project.
    public let browserContextId: String?
    let generation: Int
    let id: Int

    init(key: ChromiumProfileKey, browser: ChromiumBrowser, browserContextId: String?, generation: Int, id: Int) {
        self.key = key
        self.browser = browser
        self.browserContextId = browserContextId
        self.generation = generation
        self.id = id
    }
}

/// What the pool asks a launcher to start.
public struct ChromiumLaunchRequest: Sendable {
    public let key: ChromiumProfileKey
    public let executable: ChromiumExecutable
    /// ChromiumFlags' set; the launch plan adds `--user-data-dir`.
    public let arguments: [String]
    public let userDataDirectory: URL
    public let readyTimeout: Duration
    public let log: @Sendable (String) -> Void

    public init(key: ChromiumProfileKey, executable: ChromiumExecutable, arguments: [String],
                userDataDirectory: URL, readyTimeout: Duration, log: @escaping @Sendable (String) -> Void) {
        self.key = key
        self.executable = executable
        self.arguments = arguments
        self.userDataDirectory = userDataDirectory
        self.readyTimeout = readyTimeout
        self.log = log
    }
}

/// Starts a Chromium and returns its browser, ready (it answered
/// `Browser.getVersion`) but not started: the pool checks the version, then
/// calls `start()`. Tests inject one; the app uses `ChromiumPool.spawn`.
public typealias ChromiumLauncher = @Sendable (ChromiumLaunchRequest) async throws -> ChromiumBrowser

public enum ChromiumPoolError: Error, Equatable, Sendable, CustomStringConvertible {
    case noExecutable
    case unsupportedVersion(product: String)
    /// Local-only mode could not be enforced: nothing was launched.
    case fenceUnavailable(String)
    /// More than 3 deaths in 5 minutes; the detail of the last.
    case keepsStopping(String)
    case launchFailed(String)
    case profileFailed(String)
    case shutDown
    /// Browser tools are off: nothing launches until they are back on.
    case toolsOff

    public var description: String {
        switch self {
        case .noExecutable:
            return "No Chromium-family browser was found for the agent's browser; "
                + "Settings ▸ Agents can install one, or switch the agent browser to WebKit"
        case .unsupportedVersion(let product):
            return "\(product) is too old for the agent's browser: Loom needs Chromium "
                + "\(ChromiumVersion.minimumMajor) or newer (Settings ▸ Agents)"
        case .fenceUnavailable(let detail):
            return "Local sites only could not be enforced (\(detail)), so the agent's browser stays closed"
        case .keepsStopping(let detail):
            return "Chromium keeps stopping (\(detail)); Settings ▸ Agents can switch the agent browser to WebKit"
        case .launchFailed(let detail):
            return "Chromium could not start: \(detail)"
        case .profileFailed(let detail):
            return "The agent browser's profile folder failed: \(detail)"
        case .shutDown:
            return "Loom is quitting: the agent's browser is closed"
        case .toolsOff:
            return "Browser tools are turned off in Loom's Settings: the agent's browser stays closed"
        }
    }
}

public actor ChromiumPool {

    /// More deaths than this within `crashWindow` and launches stop.
    public static let crashLimit = 3
    public static let crashWindow: Duration = .seconds(300)

    private struct Running {
        let generation: Int
        let browser: ChromiumBrowser
        let network: ChromiumNetworkMode
        let privateDirectory: URL?
        var leases: Set<Int>
        var idleTimer: Task<Void, Never>?
    }

    private struct Launching {
        let generation: Int
        let task: Task<ChromiumBrowser, Error>
    }

    private struct Stopping {
        let generation: Int
        let task: Task<Void, Never>
    }

    private struct Launched {
        let browser: ChromiumBrowser
        let privateDirectory: URL?
    }

    private let profiles: ChromiumProfiles
    private let executableProvider: @Sendable () -> ChromiumExecutable?
    private let launcher: ChromiumLauncher
    private let idleGrace: Duration
    private let readyTimeout: Duration
    private let log: @Sendable (String) -> Void

    private var network: ChromiumNetworkMode
    private var fence: ChromiumFence?
    private var running: [ChromiumProfileKey: Running] = [:]
    private var launching: [ChromiumProfileKey: Launching] = [:]
    private var stopping: [ChromiumProfileKey: Stopping] = [:]
    private var deaths: [ChromiumProfileKey: [ContinuousClock.Instant]] = [:]
    private var lastDeath: [ChromiumProfileKey: String] = [:]
    private var nextGeneration = 0
    private var nextLease = 0
    private var isShutDown = false
    /// A project's session cookies, read when Loom stopped its process on
    /// purpose (the network setting, tools off, the idle grace) and put
    /// back at its next launch: a relaunch does not sign the agent out of
    /// a dev app, as WebKit keeps them for the app run too. Never written
    /// to disk; Clear data and a removed project forget them.
    private var savedSessionCookies: [ChromiumProfileKey: [CDPObject]] = [:]
    /// Off while browser tools are: a launch already under way when they went
    /// off (an acquire in flight) does not start Chromium again after the stop.
    private var launchesAllowed = true

    /// `network` is required: local-only must hold from the very first launch.
    /// `executable` is asked at each launch (the Settings' choice may change).
    public init(profiles: ChromiumProfiles, network: ChromiumNetworkMode,
                executable: @escaping @Sendable () -> ChromiumExecutable?,
                idleGrace: Duration = .seconds(60), readyTimeout: Duration = .seconds(15),
                launcher: ChromiumLauncher? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.profiles = profiles
        self.network = network
        self.executableProvider = executable
        self.idleGrace = idleGrace
        self.readyTimeout = readyTimeout
        self.log = log
        if let launcher {
            self.launcher = launcher
        } else {
            self.launcher = { request in try await ChromiumPool.spawn(request) }
        }
        // A private profile left by a Loom that died: never reused, nothing to keep.
        profiles.sweepPrivateDirectories()
    }

    /// The real launcher: spawn, then wait for `Browser.getVersion`. A
    /// Chromium that never answers is shut down before the error goes up.
    public static func spawn(_ request: ChromiumLaunchRequest) async throws -> ChromiumBrowser {
        let plan = ChromiumLaunchPlan(executable: request.executable.url, arguments: request.arguments,
                                      userDataDirectory: request.userDataDirectory)
        let process = try ChromiumProcess.launch(plan, log: request.log)
        do {
            let version = try await process.ready(timeout: request.readyTimeout)
            return ChromiumBrowser(process: process, version: version, log: request.log)
        } catch {
            await process.shutdown(grace: .milliseconds(200))
            throw error
        }
    }

    // MARK: - Leases

    /// A hold on the key's Chromium, launched if need be. Throws
    /// `ChromiumPoolError` (or the private context's `ChromiumBrowserError`).
    public func acquire(_ key: ChromiumProfileKey) async throws -> ChromiumLease {
        for _ in 0..<3 {
            if isShutDown { throw ChromiumPoolError.shutDown }
            let browser = try await runningBrowser(for: key)
            // Died, or stopped, between its launch and now: once more.
            guard var entry = running[key], entry.browser === browser else { continue }
            nextLease += 1
            let leaseID = nextLease
            entry.leases.insert(leaseID)
            entry.idleTimer?.cancel()
            entry.idleTimer = nil
            running[key] = entry
            let generation = entry.generation
            var contextID: String? = nil
            if key == .privateShared {
                do {
                    contextID = try await browser.createBrowserContext()
                } catch {
                    dropLease(key, generation: generation, id: leaseID)
                    throw error
                }
            }
            return ChromiumLease(key: key, browser: browser, browserContextId: contextID,
                                 generation: generation, id: leaseID)
        }
        throw ChromiumPoolError.launchFailed(lastDeath[key] ?? "Chromium stopped right after it started")
    }

    /// The lease's context goes with it; the last lease starts the idle grace.
    /// A lease of a process already gone, or released already, changes nothing.
    public func release(_ lease: ChromiumLease) {
        guard dropLease(lease.key, generation: lease.generation, id: lease.id) else { return }
        if let context = lease.browserContextId, !lease.browser.isClosed {
            lease.browser.disposeBrowserContext(context)
        }
    }

    public var networkMode: ChromiumNetworkMode { network }

    public func isRunning(_ key: ChromiumProfileKey) -> Bool {
        running[key] != nil
    }

    public func leaseCount(_ key: ChromiumProfileKey) -> Int {
        running[key]?.leases.count ?? 0
    }

    /// The local-only proxy's port while one listens.
    public var fencePort: UInt16? {
        fence?.port
    }

    // MARK: - Settings and lifecycle

    /// Every process launched on another mode is stopped — its owners hear
    /// `browserClosed`, and their next acquire launches on the new flags: the
    /// pages reload, as under WebKit. Returns once they are gone.
    public func setNetworkMode(_ mode: ChromiumNetworkMode) async {
        guard mode != network else { return }
        network = mode
        let outdated = running.filter { $0.value.network != mode }.map { $0.key }
        var tasks: [Task<Void, Never>] = []
        for key in outdated {
            if let task = beginStop(key, reason: "The agent browser's network setting changed; its pages reload",
                                    keepingCookies: true) {
                tasks.append(task)
            }
        }
        for task in tasks {
            await task.value
        }
        releaseFenceIfUnused()
    }

    /// Browser tools off (false): every acquire that would launch throws
    /// `toolsOff` — set before the processes are stopped. Back on: launches
    /// again.
    public func setLaunchesAllowed(_ allowed: Bool) {
        launchesAllowed = allowed
    }

    /// Stops the key's process now (browser tools turned off, a session's
    /// last panel and lease gone early). The next acquire launches again.
    public func stop(_ key: ChromiumProfileKey, reason: String) async {
        if let launch = launching[key] {
            _ = try? await launch.task.value
        }
        if let task = beginStop(key, reason: reason, keepingCookies: true) {
            await task.value
        }
    }

    /// Clear agent browser data: the project's process stops, its profile is
    /// emptied, the next acquire starts it signed out.
    public func clearProfile(_ identifier: UUID) async throws {
        try await maintainProfile(identifier, reason: "The agent browser's data was cleared") { profiles in
            try profiles.clearProfile(identifier)
        }
    }

    /// A removed project: its process stops, its profile goes from disk.
    public func removeProfile(_ identifier: UUID) async throws {
        try await maintainProfile(identifier, reason: "The project was removed from Loom") { profiles in
            try profiles.removeProfile(identifier)
        }
    }

    /// App quit: every process gets `Browser.close` and `grace` to flush its
    /// profile; past `grace` + 1 s this returns anyway (Loom's exit closes the
    /// pipes, and Chromium exits on their EOF). No launch afterwards.
    public func shutdownAll(grace: Duration = .milliseconds(1500)) async {
        isShutDown = true
        var tasks: [Task<Void, Never>] = []
        for key in Array(running.keys) {
            if let task = beginStop(key, reason: "Loom is quitting", grace: grace) {
                tasks.append(task)
            }
        }
        for pending in stopping.values {
            tasks.append(pending.task)
        }
        let finished = await Self.waitAll(tasks, upTo: grace + .seconds(1))
        if finished && launching.isEmpty && running.isEmpty {
            fence?.stop()
            fence = nil
        }
    }

    // MARK: - Launch

    private func runningBrowser(for key: ChromiumProfileKey) async throws -> ChromiumBrowser {
        while true {
            if isShutDown { throw ChromiumPoolError.shutDown }
            if let entry = running[key] { return entry.browser }
            if let pending = stopping[key] {
                await pending.task.value
                continue
            }
            if let launch = launching[key] {
                return try await launch.task.value
            }
            guard launchesAllowed else { throw ChromiumPoolError.toolsOff }
            try admitLaunch(key)
            nextGeneration += 1
            let generation = nextGeneration
            let task = Task { try await self.performLaunch(key, generation: generation) }
            launching[key] = Launching(generation: generation, task: task)
            return try await task.value
        }
    }

    /// The crash-loop cap: past it, the person decides (Settings), not a loop.
    private func admitLaunch(_ key: ChromiumProfileKey) throws {
        let now = ContinuousClock.now
        let recent = (deaths[key] ?? []).filter { $0.duration(to: now) < Self.crashWindow }
        deaths[key] = recent
        if recent.count > Self.crashLimit {
            throw ChromiumPoolError.keepsStopping(Self.brief(lastDeath[key] ?? "no detail"))
        }
    }

    private func performLaunch(_ key: ChromiumProfileKey, generation: Int) async throws -> ChromiumBrowser {
        defer {
            if launching[key]?.generation == generation {
                launching[key] = nil
            }
        }
        var attempt = 0
        while true {
            attempt += 1
            let mode = network
            let launched = try await launchOnce(key, mode: mode)
            if let cookies = savedSessionCookies[key] {
                await launched.browser.restoreCookies(cookies)
            }
            if isShutDown {
                await discard(launched, reason: "Loom is quitting")
                throw ChromiumPoolError.shutDown
            }
            if mode != network {
                // The setting changed during the launch: these flags are stale.
                await discard(launched, reason: "The agent browser's network setting changed")
                if attempt >= 3 {
                    throw ChromiumPoolError.launchFailed("the network setting kept changing during the launch")
                }
                continue
            }
            savedSessionCookies[key] = nil
            running[key] = Running(generation: generation, browser: launched.browser, network: mode,
                                   privateDirectory: launched.privateDirectory, leases: [], idleTimer: nil)
            watch(launched.browser, key: key, generation: generation)
            // Until its first lease: an acquirer that went away leaves no process behind.
            scheduleIdleStop(key, generation: generation)
            log("chromium pool: \(key) runs \(launched.browser.version.product)"
                + (launched.browser.pid.map { " (pid \($0))" } ?? ""))
            return launched.browser
        }
    }

    private func launchOnce(_ key: ChromiumProfileKey, mode: ChromiumNetworkMode) async throws -> Launched {
        guard let executable = executableProvider() else { throw ChromiumPoolError.noExecutable }
        // Fail closed: local-only launches nothing without a listening fence.
        var launchFence: ChromiumFence? = nil
        if case .localOnly = mode {
            launchFence = try ensureFence()
        }

        var privateDirectory: URL? = nil
        let userDataDirectory: URL
        let cacheDirectory: URL?
        do {
            switch key {
            case .project(let identifier):
                // First use in this app run: service workers and caches go, logins stay.
                userDataDirectory = try profiles.prepareProfile(identifier)
                cacheDirectory = profiles.cacheDirectory(for: identifier)
            case .privateShared:
                let directory = try profiles.makePrivateDirectory()
                privateDirectory = directory
                userDataDirectory = directory
                cacheDirectory = nil
            }
        } catch {
            throw ChromiumPoolError.profileFailed(Self.describe(error))
        }

        let arguments: [String]
        do {
            arguments = try ChromiumFlags.arguments(kind: executable.kind, network: mode, fence: launchFence,
                                                    cacheDirectory: cacheDirectory)
        } catch {
            removePrivate(privateDirectory)
            throw ChromiumPoolError.fenceUnavailable(Self.describe(error))
        }

        let request = ChromiumLaunchRequest(key: key, executable: executable, arguments: arguments,
                                            userDataDirectory: userDataDirectory, readyTimeout: readyTimeout,
                                            log: log)
        let browser: ChromiumBrowser
        do {
            browser = try await launchFreeingProfile(request)
        } catch {
            removePrivate(privateDirectory)
            let detail = Self.describe(error)
            recordDeath(key, detail: detail)
            throw ChromiumPoolError.launchFailed(detail)
        }

        guard browser.version.isSupported else {
            await browser.shutdown(grace: .milliseconds(500), reason: "This Chromium is too old for Loom")
            removePrivate(privateDirectory)
            throw ChromiumPoolError.unsupportedVersion(product: browser.version.product)
        }
        do {
            try await browser.start()
        } catch {
            await browser.shutdown(grace: .milliseconds(500), reason: "Chromium refused Loom's settings")
            removePrivate(privateDirectory)
            let detail = Self.describe(error)
            recordDeath(key, detail: detail)
            throw ChromiumPoolError.launchFailed(detail)
        }
        return Launched(browser: browser, privateDirectory: privateDirectory)
    }

    /// A Chromium of a Loom that died may still hold the profile: on that
    /// failure, the stale process is ended — only if it runs this executable
    /// on this profile — and the launch tried once more.
    private func launchFreeingProfile(_ request: ChromiumLaunchRequest) async throws -> ChromiumBrowser {
        do {
            return try await launcher(request)
        } catch let error as ChromiumProcessError where error.isProfileInUse {
            log("chromium pool: \(request.key)'s profile is in use; ending the stale Chromium, then one more try")
            let ended = await profiles.terminateStaleProcess(holding: request.userDataDirectory,
                                                             executable: request.executable.url)
            log("chromium pool: stale Chromium " + (ended ? "ended" : "not found or not ours"))
            return try await launcher(request)
        }
    }

    private func discard(_ launched: Launched, reason: String) async {
        await launched.browser.shutdown(grace: .milliseconds(500), reason: reason)
        removePrivate(launched.privateDirectory)
    }

    private func removePrivate(_ directory: URL?) {
        if let directory {
            profiles.removePrivateDirectory(directory)
        }
    }

    private func ensureFence() throws -> ChromiumFence {
        if let fence, fence.isListening { return fence }
        do {
            let started = try ChromiumFence.start()
            fence = started
            log("chromium pool: local-only fence on 127.0.0.1:\(started.port)")
            return started
        } catch {
            throw ChromiumPoolError.fenceUnavailable(String(describing: error))
        }
    }

    /// Back to open mode with nothing left on the fence: its port is released.
    private func releaseFenceIfUnused() {
        guard case .open = network, launching.isEmpty, stopping.isEmpty else { return }
        guard !running.values.contains(where: { $0.network != .open }) else { return }
        if let fence {
            fence.stop()
            self.fence = nil
        }
    }

    // MARK: - Deaths and stops

    private func watch(_ browser: ChromiumBrowser, key: ChromiumProfileKey, generation: Int) {
        Task { [weak self] in
            let reason = await browser.waitUntilClosed()
            await self?.browserDidClose(key, generation: generation, reason: reason, stderr: browser.stderrTail)
        }
    }

    /// Unexpected only: a stop of ours removed the entry first.
    private func browserDidClose(_ key: ChromiumProfileKey, generation: Int, reason: String, stderr: String) {
        guard let entry = running[key], entry.generation == generation else { return }
        running[key] = nil
        entry.idleTimer?.cancel()
        removePrivate(entry.privateDirectory)
        let detail = Self.detail(reason, stderr: stderr)
        recordDeath(key, detail: detail)
        log("chromium pool: \(key) stopped unexpectedly: \(detail)")
    }

    private func recordDeath(_ key: ChromiumProfileKey, detail: String) {
        deaths[key, default: []].append(ContinuousClock.now)
        lastDeath[key] = detail
    }

    @discardableResult
    private func dropLease(_ key: ChromiumProfileKey, generation: Int, id: Int) -> Bool {
        guard var entry = running[key], entry.generation == generation else { return false }
        guard entry.leases.remove(id) != nil else { return false }
        running[key] = entry
        if entry.leases.isEmpty {
            scheduleIdleStop(key, generation: generation)
        }
        return true
    }

    private func scheduleIdleStop(_ key: ChromiumProfileKey, generation: Int) {
        guard var entry = running[key], entry.generation == generation, entry.leases.isEmpty else { return }
        entry.idleTimer?.cancel()
        let grace = idleGrace
        entry.idleTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            await self?.idleExpired(key, generation: generation)
        }
        running[key] = entry
    }

    private func idleExpired(_ key: ChromiumProfileKey, generation: Int) {
        guard let entry = running[key], entry.generation == generation, entry.leases.isEmpty else { return }
        let seconds = idleGrace.components.seconds
        beginStop(key, reason: "Chromium was stopped after \(seconds) s without a session", keepingCookies: true)
    }

    /// The process leaves `running` at once — it is no death — and its
    /// shutdown runs in a task that a launch of the same key waits for.
    /// `force` makes the task even with nothing running; `work` runs after
    /// the shutdown, before any launch of the key.
    @discardableResult
    private func beginStop(_ key: ChromiumProfileKey, reason: String, grace: Duration = .seconds(2),
                           force: Bool = false, keepingCookies: Bool = false,
                           then work: (@Sendable () -> Void)? = nil) -> Task<Void, Never>? {
        let entry = running.removeValue(forKey: key)
        if entry == nil && !force {
            return stopping[key]?.task
        }
        entry?.idleTimer?.cancel()
        let browser = entry?.browser
        let directory = entry?.privateDirectory
        let profiles = self.profiles
        nextGeneration += 1
        let generation = nextGeneration
        let keeps: Bool
        if case .project = key { keeps = keepingCookies } else { keeps = false }
        let task = Task { [weak self] in
            if let browser {
                // Read before the stop, kept before any launch of the key
                // (a launch waits for this task).
                if keeps {
                    let cookies = await browser.sessionCookies()
                    await self?.saveSessionCookies(cookies, for: key)
                }
                await browser.shutdown(grace: grace, reason: reason)
            }
            if let directory {
                profiles.removePrivateDirectory(directory)
            }
            work?()
            await self?.stopFinished(key, generation: generation)
        }
        stopping[key] = Stopping(generation: generation, task: task)
        return task
    }

    private func saveSessionCookies(_ cookies: [CDPObject], for key: ChromiumProfileKey) {
        savedSessionCookies[key] = cookies.isEmpty ? nil : cookies
    }

    private func stopFinished(_ key: ChromiumProfileKey, generation: Int) {
        if stopping[key]?.generation == generation {
            stopping[key] = nil
        }
        releaseFenceIfUnused()
    }

    /// The project's process stopped, no launch or stop in between, then
    /// `work` on its profile — before any launch of it can start.
    private func maintainProfile(_ identifier: UUID, reason: String,
                                 _ work: @escaping @Sendable (ChromiumProfiles) throws -> Void) async throws {
        let key = ChromiumProfileKey.project(identifier)
        while true {
            if let launch = launching[key] {
                _ = try? await launch.task.value
                continue
            }
            if let pending = stopping[key] {
                await pending.task.value
                continue
            }
            break
        }
        // Signed out (Clear data) or gone: no cookie of it comes back.
        savedSessionCookies[key] = nil
        let failure = ChromiumOnce<String?>()
        let profiles = self.profiles
        let task = beginStop(key, reason: reason, force: true) {
            do {
                try work(profiles)
                failure.set(nil)
            } catch {
                failure.set(ChromiumPool.describe(error))
            }
        }
        if let task {
            await task.value
        }
        if let message = failure.value ?? nil {
            throw ChromiumPoolError.profileFailed(message)
        }
    }

    // MARK: - Helpers

    /// True once every task finished, false past `limit`; never cancels them.
    static func waitAll(_ tasks: [Task<Void, Never>], upTo limit: Duration) async -> Bool {
        let done = ChromiumOnce<Bool>()
        Task {
            for task in tasks {
                await task.value
            }
            done.set(true)
        }
        Task {
            try? await Task.sleep(for: limit)
            done.set(false)
        }
        return await done.wait()
    }

    static func describe(_ error: Error) -> String {
        if let poolError = error as? ChromiumPoolError { return poolError.description }
        if let spawnError = error as? ChromiumSpawnError {
            switch spawnError {
            case .notAbsolute(let path):
                return "\(path) is not an absolute path"
            case .pipeFailed(let code), .descriptorFailed(let code):
                return "no pipe for Chromium: \(String(cString: strerror(code)))"
            case .spawnFailed(let executable, let code):
                return "\(executable) could not be started: \(String(cString: strerror(code)))"
            }
        }
        if let processError = error as? ChromiumProcessError { return processError.description }
        if let flagsError = error as? ChromiumFlagsError { return flagsError.description }
        if error is CDPError || error is ChromiumBrowserError { return ChromiumBrowser.describe(error) }
        return String(describing: error)
    }

    /// The reason — "signal 11" rather than "Chromium stopped (signal 11)" —
    /// and the last thing Chromium wrote on stderr.
    static func detail(_ reason: String, stderr: String) -> String {
        var core = reason
        let wrapper = "Chromium stopped ("
        if core.hasPrefix(wrapper), core.hasSuffix(")") {
            core = String(core.dropFirst(wrapper.count).dropLast())
        }
        let lastLine = stderr.split(separator: "\n")
            .last(where: Self.isChromiumsOwn)
            .map { String($0.prefix(200)) }
        guard let lastLine else { return core }
        return "\(core): \(lastLine)"
    }

    /// A warning or an error Chromium itself logged ("[…:ERROR:file.cc(12)] …").
    /// Never a page's console message — the headless shell writes them all
    /// to stderr ("[…:INFO:CONSOLE:1] "token=…", source: http://…") — nor a
    /// line it continues: a page's text does not reach Loom's log, nor the
    /// error another session of the same Chromium reads.
    static func isChromiumsOwn(_ line: Substring) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        let head = line[..<close]
        guard !head.contains("CONSOLE") else { return false }
        return head.contains(":ERROR:") || head.contains(":FATAL:") || head.contains(":WARNING:")
    }

    /// One line for the crash-loop message: the first and the last of a detail.
    static func brief(_ detail: String) -> String {
        let lines = detail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return detail }
        guard lines.count > 1, let last = lines.last else { return String(first.prefix(300)) }
        return String((first + " … " + last).prefix(300))
    }
}
