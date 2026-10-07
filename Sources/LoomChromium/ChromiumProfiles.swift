import Darwin
import Foundation

/// The agent's Chromium profiles on disk (ADR-0016), under
/// `<support>/agent-browser/chromium/`:
///
/// - `profiles/<store identifier>/`: a project's `--user-data-dir`, named by
///   `AgentBrowserProfile.storeIdentifier(forProject:)` like its WebKit store;
/// - `cache/<store identifier>/`: its `--disk-cache-dir`;
/// - `private/<launch UUID>/`: the shared private process's profile, whose
///   pages all live in throwaway browser contexts. Removed at its shutdown,
///   swept at the next launch should Loom have died first.
///
/// Every folder is 0700 and excluded from backups. Unlike WebKit's identifier
/// stores, which every Loom instance shares, these folders belong to this
/// support directory alone (`LOOM_SUPPORT_DIR` dev instances have their own).
public final class ChromiumProfiles: @unchecked Sendable {

    public let root: URL

    private let lock = NSLock()
    /// The profiles whose first-use folders this app run already cleared.
    private var preparedThisRun: Set<UUID> = []

    public init(root: URL) {
        self.root = root
    }

    /// `<support>/agent-browser/chromium`.
    public convenience init(supportDirectory: URL) {
        self.init(root: supportDirectory.appendingPathComponent("agent-browser/chromium", isDirectory: true))
    }

    public var profilesRoot: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var cachesRoot: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var privateRoot: URL { root.appendingPathComponent("private", isDirectory: true) }

    public func profileDirectory(for identifier: UUID) -> URL {
        profilesRoot.appendingPathComponent(identifier.uuidString, isDirectory: true)
    }

    public func cacheDirectory(for identifier: UUID) -> URL {
        cachesRoot.appendingPathComponent(identifier.uuidString, isDirectory: true)
    }

    // MARK: - Project profiles

    /// Deleted from a project's profile and cache the first time an app run
    /// launches it: what a page could leave behind to intercept the NEXT
    /// session's pages (a service worker, cached responses, compiled code).
    /// Logins — cookies, local storage, IndexedDB — stay. The parity of
    /// `AgentBrowserProfile.clearedOnFirstUse`.
    public static let clearedOnFirstUse = ["Default/Service Worker", "Default/Cache", "Default/Code Cache",
                                           "Default/GPUCache"]

    /// The profile's folder, created if need be, its first-use folders
    /// cleared once per identifier per app run. The clearing runs outside
    /// the lock: callers serialize launches of one profile (ChromiumPool).
    @discardableResult
    public func prepareProfile(_ identifier: UUID) throws -> URL {
        let profile = profileDirectory(for: identifier)
        let cache = cacheDirectory(for: identifier)
        try Self.makeOwnedDirectory(profile)
        try Self.makeOwnedDirectory(cache)
        let first: Bool = lock.withLock { preparedThisRun.insert(identifier).inserted }
        if first {
            for base in [profile, cache] {
                for relative in Self.clearedOnFirstUse {
                    let folder = base.appendingPathComponent(relative, isDirectory: true)
                    if FileManager.default.fileExists(atPath: folder.path) {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            }
        }
        return profile
    }

    /// Whether this app run already prepared the profile.
    public func wasPrepared(_ identifier: UUID) -> Bool {
        lock.withLock { preparedThisRun.contains(identifier) }
    }

    /// The profile and its cache gone from disk. No process may use it:
    /// ChromiumPool stops the project's Chromium first.
    public func removeProfile(_ identifier: UUID) throws {
        for directory in [profileDirectory(for: identifier), cacheDirectory(for: identifier)]
            where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Signed out of everything: removed, then created again, empty.
    public func clearProfile(_ identifier: UUID) throws {
        try removeProfile(identifier)
        try Self.makeOwnedDirectory(profileDirectory(for: identifier))
        try Self.makeOwnedDirectory(cacheDirectory(for: identifier))
    }

    /// The identifiers with a profile or a cache folder on disk. A name that
    /// is not a UUID is someone else's and left alone.
    public func profilesOnDisk() -> [UUID] {
        var found = Set<UUID>()
        for directory in [profilesRoot, cachesRoot] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                if let identifier = UUID(uuidString: name) { found.insert(identifier) }
            }
        }
        return found.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - Orphans

    /// The profiles to forget (pure): every one on disk or in the registry
    /// (stores.json) that no existing project owns. `active` holds the store
    /// identifiers of the projects that exist — callers skip the sweep when
    /// the projects could not be read: an empty read is not proof every
    /// project is gone. A folder here is this support directory's own, so
    /// one on disk is an orphan whether the registry lists it or not.
    public static func orphanedProfiles(onDisk: [UUID], registered: [UUID], active: [UUID]) -> [UUID] {
        let kept = Set(active)
        var seen = Set<UUID>()
        var orphans: [UUID] = []
        for identifier in registered + onDisk where !kept.contains(identifier) {
            if seen.insert(identifier).inserted { orphans.append(identifier) }
        }
        return orphans
    }

    /// At launch, before any Chromium: removes the orphans' folders. Returns
    /// the identifiers now gone from disk — the ones the caller may drop from
    /// the registry; one whose removal failed is kept for the next launch.
    @discardableResult
    public func sweepOrphans(registered: [UUID], active: [UUID]) -> [UUID] {
        let orphans = Self.orphanedProfiles(onDisk: profilesOnDisk(), registered: registered, active: active)
        return orphans.filter { identifier in
            (try? removeProfile(identifier)) != nil
        }
    }

    // MARK: - The shared private process

    /// A fresh profile for one launch of the private process. Its pages live
    /// in browser contexts, in memory: the folder holds only the browser's
    /// own state, and goes with the process.
    public func makePrivateDirectory() throws -> URL {
        let directory = privateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makeOwnedDirectory(directory)
        return directory
    }

    /// Only ever a folder directly under `private/`: a wrong URL deletes nothing.
    public func removePrivateDirectory(_ directory: URL) {
        let parent = directory.standardizedFileURL.deletingLastPathComponent().path
        guard parent == privateRoot.standardizedFileURL.path,
              directory.lastPathComponent != "", directory.lastPathComponent != ".." else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// At launch, before the private process starts: what a Loom that died
    /// left in `private/`. Returns how many folders went.
    @discardableResult
    public func sweepPrivateDirectories() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: privateRoot.path)) ?? []
        var removed = 0
        for name in names {
            if (try? FileManager.default.removeItem(at: privateRoot.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - A stale Chromium holding a profile

    /// `SingletonLock`'s target: who holds the profile.
    public struct LockOwner: Equatable, Sendable {
        public let host: String
        public let pid: pid_t

        public init(host: String, pid: pid_t) {
            self.host = host
            self.pid = pid
        }
    }

    /// "<host>-<pid>" → (host, pid). The host may itself hold dashes: the
    /// pid is after the last one. nil for anything else, pid 0 and 1 included.
    public static func parseSingletonLock(_ destination: String) -> LockOwner? {
        guard let dash = destination.lastIndex(of: "-") else { return nil }
        let host = String(destination[..<dash])
        let digits = destination[destination.index(after: dash)...]
        guard !host.isEmpty, !digits.isEmpty, digits.count <= 10,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int32(digits), pid > 1 else { return nil }
        return LockOwner(host: host, pid: pid)
    }

    /// The holder named by the profile's `SingletonLock` symlink, if any.
    public static func lockOwner(of userDataDirectory: URL) -> LockOwner? {
        let lock = userDataDirectory.appendingPathComponent("SingletonLock").path
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: lock) else { return nil }
        return parseSingletonLock(destination)
    }

    /// After Loom died, a Chromium it started may live on (an agent's child
    /// held its pipe) and keep the profile locked. Ends it — but only a
    /// process that runs `executable` with this very `--user-data-dir`: a
    /// reused pid, or the person's own Chrome, is never touched. SIGTERM to
    /// its group, then SIGKILL past `grace`. True once it is gone.
    public func terminateStaleProcess(holding userDataDirectory: URL, executable: URL,
                                      grace: Duration = .seconds(2)) async -> Bool {
        guard let owner = Self.lockOwner(of: userDataDirectory) else { return false }
        let pid = owner.pid
        guard Self.isStaleChromium(pid: pid, userDataDirectory: userDataDirectory, executable: executable) else {
            return false
        }
        // Spawned in a group of its own (ChromiumSpawn): its renderers go too.
        let ownGroup = getpgid(pid) == pid
        Self.sendSignal(pid, SIGTERM, group: ownGroup)
        if await Self.waitUntilGone(pid, userDataDirectory: userDataDirectory, executable: executable, upTo: grace) {
            return true
        }
        Self.sendSignal(pid, SIGKILL, group: ownGroup)
        return await Self.waitUntilGone(pid, userDataDirectory: userDataDirectory, executable: executable,
                                        upTo: .seconds(1))
    }

    /// The live process `pid` runs `executable` with this profile — and is not Loom.
    static func isStaleChromium(pid: pid_t, userDataDirectory: URL, executable: URL) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        guard let running = executablePath(of: pid),
              let arguments = processArguments(of: pid)?.arguments else { return false }
        return isSameExecutable(running, executable.path)
            && namesProfile(arguments, userDataDirectory: userDataDirectory)
    }

    /// Paths compared as given, then with symlinks resolved.
    static func isSameExecutable(_ running: String, _ expected: String) -> Bool {
        if running == expected { return true }
        let resolvedRunning = URL(fileURLWithPath: running).resolvingSymlinksInPath().path
        let resolvedExpected = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        return resolvedRunning == resolvedExpected
    }

    /// The command line carries `--user-data-dir=<this folder>`.
    static func namesProfile(_ arguments: [String], userDataDirectory: URL) -> Bool {
        let wanted = userDataDirectory.standardizedFileURL.path
        let resolved = userDataDirectory.resolvingSymlinksInPath().path
        let prefix = "--user-data-dir="
        for argument in arguments where argument.hasPrefix(prefix) {
            let value = String(argument.dropFirst(prefix.count))
            let given = URL(fileURLWithPath: value).standardizedFileURL.path
            if given == wanted || given == resolved
                || URL(fileURLWithPath: value).resolvingSymlinksInPath().path == resolved {
                return true
            }
        }
        return false
    }

    /// `proc_pidpath`, looked up at run time so this file needs no libproc
    /// module. nil for a process gone, a zombie, or one not ours to inspect.
    public static func executablePath(of pid: pid_t) -> String? {
        typealias ProcPidPath = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return nil }
        let procPidPath = unsafeBitCast(symbol, to: ProcPidPath.self)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            procPidPath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0, Int(length) <= buffer.count else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// The process's executable and argv (`KERN_PROCARGS2`); nil once it is gone.
    public static func processArguments(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard read == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`'s layout: argc (32 bits, host order), the executable
    /// path, NUL padding, then argc NUL-terminated arguments (the environment
    /// follows, unread).
    static func parseProcessArguments(_ bytes: [UInt8]) -> (executable: String, arguments: [String])? {
        guard bytes.count > 4 else { return nil }
        // Byte by byte, each typed: one expression of shifts and ors is
        // more than the type checker likes.
        let byte0: UInt32 = UInt32(bytes[0])
        let byte1: UInt32 = UInt32(bytes[1]) << 8
        let byte2: UInt32 = UInt32(bytes[2]) << 16
        let byte3: UInt32 = UInt32(bytes[3]) << 24
        let count = Int(byte0 | byte1 | byte2 | byte3)
        var index = 4
        func nextString() -> String? {
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return nil }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return text
        }
        guard let executable = nextString(), !executable.isEmpty else { return nil }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < min(count, 4096), let argument = nextString() {
            arguments.append(argument)
        }
        return (executable, arguments)
    }

    private static func sendSignal(_ pid: pid_t, _ number: Int32, group: Bool) {
        if group {
            if kill(-pid, number) != 0 { _ = kill(pid, number) }
        } else {
            _ = kill(pid, number)
        }
    }

    /// Polls until `pid` no longer is that Chromium: exited, reaped, or the
    /// pid taken by another program.
    private static func waitUntilGone(_ pid: pid_t, userDataDirectory: URL, executable: URL,
                                      upTo limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while true {
            if !isStaleChromium(pid: pid, userDataDirectory: userDataDirectory, executable: executable) {
                return true
            }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Folders

    /// 0700 — the intermediate folders too — tightened if it existed wider,
    /// and kept out of backups: cookies and caches have no place in Time Machine.
    static func makeOwnedDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            // Made meanwhile by another caller: as good.
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw error
            }
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = directory
        try? marked.setResourceValues(values)
    }
}
