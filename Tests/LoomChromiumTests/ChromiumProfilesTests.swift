import Testing
@testable import LoomChromium
import Darwin
import Foundation

// The profiles' folders in a throwaway root; the stale-process check against
// this very test process and a shell it starts. No Chromium, no network.

private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("loom-profiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func permissions(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

private func isExcludedFromBackup(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
}

@Suite("ChromiumProfiles — the agent's Chromium profiles on disk")
struct ChromiumProfilesTests {

    @Test("a project's profile and cache live under profiles/ and cache/, 0700, out of backups")
    func emplacementEtDroits() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let identifier = UUID()

        let profile = try profiles.prepareProfile(identifier)
        #expect(profile.path == root.appendingPathComponent("profiles/\(identifier.uuidString)").path)
        let cache = profiles.cacheDirectory(for: identifier)
        #expect(cache.path == root.appendingPathComponent("cache/\(identifier.uuidString)").path)
        for folder in [profile, cache] {
            #expect(exists(folder))
            #expect(permissions(folder) == 0o700, "\(folder.lastPathComponent): cookies are the person's")
            #expect(isExcludedFromBackup(folder))
        }
        #expect(permissions(profiles.profilesRoot) == 0o700, "the folders made on the way too")
    }

    @Test("a profile opened wider is tightened back to 0700")
    func droitsResserres() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let identifier = UUID()
        let profile = profiles.profileDirectory(for: identifier)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try profiles.prepareProfile(identifier)
        #expect(permissions(profile) == 0o700)
    }

    @Test("the support directory's layout: agent-browser/chromium")
    func racineDuSupport() {
        let support = URL(fileURLWithPath: "/Users/ada/Library/Application Support/Loom", isDirectory: true)
        let profiles = ChromiumProfiles(supportDirectory: support)
        #expect(profiles.root.path == "/Users/ada/Library/Application Support/Loom/agent-browser/chromium")
        #expect(profiles.privateRoot.path.hasSuffix("agent-browser/chromium/private"))
    }

    @Test("first use in a run: service workers and caches go, logins stay — once per run")
    func premierUsage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID()
        let run = ChromiumProfiles(root: root)
        let profile = run.profileDirectory(for: identifier)
        let cache = run.cacheDirectory(for: identifier)
        let cleared = ChromiumProfiles.clearedOnFirstUse.map { profile.appendingPathComponent($0).appendingPathComponent("data") }
            + [cache.appendingPathComponent("Default/Cache/index"), cache.appendingPathComponent("Default/Code Cache/js"),
               // chrome-headless-shell's HTTP cache, at the cache folder's root (measured).
               cache.appendingPathComponent("Cache_Data/index")]
        let kept = [profile.appendingPathComponent("Default/Cookies"),
                    profile.appendingPathComponent("Default/Local Storage/leveldb/000003.log"),
                    profile.appendingPathComponent("Local State")]
        for file in cleared + kept { try touch(file) }

        #expect(!run.wasPrepared(identifier))
        try run.prepareProfile(identifier)
        #expect(run.wasPrepared(identifier))
        for file in cleared { #expect(!exists(file), "\(file.path) cleared") }
        for file in kept { #expect(exists(file), "\(file.path) kept") }

        // The same run launches it again (after an idle stop): nothing more goes.
        try touch(cleared[0])
        try run.prepareProfile(identifier)
        #expect(exists(cleared[0]), "once per identifier per run")

        // The next app run clears again.
        let nextRun = ChromiumProfiles(root: root)
        try nextRun.prepareProfile(identifier)
        #expect(!exists(cleared[0]))
        for file in kept { #expect(exists(file)) }
    }

    @Test("concurrent first uses clear once, and every caller gets the folder")
    func premierUsageConcurrent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let identifier = UUID()
        let folders = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<8 {
                group.addTask { try profiles.prepareProfile(identifier) }
            }
            var result: [URL] = []
            for try await folder in group { result.append(folder) }
            return result
        }
        #expect(folders.count == 8)
        #expect(Set(folders.map(\.path)).count == 1)
        #expect(profiles.wasPrepared(identifier))
    }

    @Test("clear empties the profile and keeps the folder; remove deletes profile and cache")
    func viderEtSupprimer() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let identifier = UUID()
        let profile = try profiles.prepareProfile(identifier)
        let cookies = profile.appendingPathComponent("Default/Cookies")
        try touch(cookies)
        try touch(profiles.cacheDirectory(for: identifier).appendingPathComponent("Default/Cache/index"))

        try profiles.clearProfile(identifier)
        #expect(!exists(cookies), "signed out of everything")
        #expect(exists(profile))
        #expect(permissions(profile) == 0o700)
        let profileContents = try FileManager.default.contentsOfDirectory(atPath: profile.path)
        let cacheContents = try FileManager.default.contentsOfDirectory(
            atPath: profiles.cacheDirectory(for: identifier).path)
        #expect(profileContents.isEmpty)
        #expect(cacheContents.isEmpty)

        try profiles.removeProfile(identifier)
        #expect(!exists(profile))
        #expect(!exists(profiles.cacheDirectory(for: identifier)))
        try profiles.removeProfile(identifier)   // gone already: no error
    }

    @Test("orphans: whatever is on disk or registered that no existing project owns")
    func orphelinsPurs() {
        let active = UUID()
        let removed = UUID()
        let leftover = UUID()
        let registeredOnly = UUID()
        let orphans = ChromiumProfiles.orphanedProfiles(onDisk: [active, removed, leftover],
                                                        registered: [active, removed, registeredOnly],
                                                        active: [active])
        #expect(Set(orphans) == [removed, leftover, registeredOnly])
        #expect(orphans.count == 3, "each once")
        #expect(ChromiumProfiles.orphanedProfiles(onDisk: [active], registered: [active], active: [active]).isEmpty)
    }

    @Test("the sweep removes the orphans' folders, keeps the active ones and anything not a profile")
    func balayageDesOrphelins() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let active = UUID()
        let removed = UUID()
        let cacheOnly = UUID()
        try profiles.prepareProfile(active)
        try profiles.prepareProfile(removed)
        try FileManager.default.createDirectory(at: profiles.cacheDirectory(for: cacheOnly),
                                                withIntermediateDirectories: true)
        let stranger = profiles.profilesRoot.appendingPathComponent("not-a-profile")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        #expect(Set(profiles.profilesOnDisk()) == [active, removed, cacheOnly])
        let gone = profiles.sweepOrphans(registered: [removed], active: [active])
        #expect(Set(gone) == [removed, cacheOnly])
        #expect(exists(profiles.profileDirectory(for: active)))
        #expect(exists(profiles.cacheDirectory(for: active)))
        #expect(!exists(profiles.profileDirectory(for: removed)))
        #expect(!exists(profiles.cacheDirectory(for: removed)))
        #expect(!exists(profiles.cacheDirectory(for: cacheOnly)))
        #expect(exists(stranger), "a name that is not a UUID is someone else's")
    }

    @Test("the private process gets a fresh folder per launch; removed alone, swept at launch")
    func dossiersPrives() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let first = try profiles.makePrivateDirectory()
        let second = try profiles.makePrivateDirectory()
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == profiles.privateRoot.path)
        #expect(permissions(first) == 0o700)
        #expect(isExcludedFromBackup(first))

        profiles.removePrivateDirectory(first)
        #expect(!exists(first))
        #expect(exists(second))

        // Never a folder elsewhere, whatever URL it is handed.
        let project = try profiles.prepareProfile(UUID())
        profiles.removePrivateDirectory(project)
        profiles.removePrivateDirectory(profiles.privateRoot)
        profiles.removePrivateDirectory(second.appendingPathComponent(".."))
        #expect(exists(project))
        #expect(exists(profiles.privateRoot))

        try touch(second.appendingPathComponent("Default/Cookies"))
        let swept = ChromiumProfiles(root: root).sweepPrivateDirectories()
        #expect(swept == 1)
        #expect(!exists(second))
        #expect(exists(project), "projects are not the private sweep's")
    }

    @Test("SingletonLock: <host>-<pid>, the host may hold dashes")
    func verrouLu() {
        #expect(ChromiumProfiles.parseSingletonLock("Adas-MacBook-Pro.local-4242")
                == ChromiumProfiles.LockOwner(host: "Adas-MacBook-Pro.local", pid: 4242))
        #expect(ChromiumProfiles.parseSingletonLock("ci-runner-17") == ChromiumProfiles.LockOwner(host: "ci-runner", pid: 17))
        for invalid in ["", "nohyphen", "host-", "-4242", "host-42a", "host-+42", "host- 42", "host-0", "host-1",
                        "host-99999999999"] {
            #expect(ChromiumProfiles.parseSingletonLock(invalid) == nil, "\(invalid)")
        }
    }

    @Test("the lock's owner is read from the symlink, and none without one")
    func verrouSurLeDisque() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ChromiumProfiles(root: root).prepareProfile(UUID())
        #expect(ChromiumProfiles.lockOwner(of: profile) == nil)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "builder.local-31337")
        #expect(ChromiumProfiles.lockOwner(of: profile) == ChromiumProfiles.LockOwner(host: "builder.local", pid: 31337))
    }

    @Test("KERN_PROCARGS2 is read: argc, the executable, padding, then the arguments")
    func argumentsDuProcessus() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/opt/chrome".utf8) + [0, 0, 0, 0]
        for argument in ["chrome", "--headless", "--user-data-dir=/tmp/p"] {
            bytes += Array(argument.utf8) + [0]
        }
        bytes += Array("HOME=/Users/ada".utf8) + [0]
        let parsed = ChromiumProfiles.parseProcessArguments(bytes)
        #expect(parsed?.executable == "/opt/chrome")
        #expect(parsed?.arguments == ["chrome", "--headless", "--user-data-dir=/tmp/p"], "the environment is not argv")
        #expect(ChromiumProfiles.parseProcessArguments([1, 0]) == nil)
        #expect(ChromiumProfiles.parseProcessArguments([1, 0, 0, 0] + Array("/no/terminator".utf8)) == nil)

        // This very process, for real.
        let own = ChromiumProfiles.processArguments(of: getpid())
        #expect(own?.arguments.isEmpty == false)
        #expect(ChromiumProfiles.executablePath(of: getpid())?.hasPrefix("/") == true)
        #expect(ChromiumProfiles.isSameExecutable("/usr/bin/../bin/true", "/usr/bin/true"))
    }

    @Test("--user-data-dir is matched as a path, not as text")
    func profilNomme() {
        let profile = URL(fileURLWithPath: "/tmp/loom/profiles/A", isDirectory: true)
        #expect(ChromiumProfiles.namesProfile(["chrome", "--user-data-dir=/tmp/loom/profiles/A"], userDataDirectory: profile))
        #expect(ChromiumProfiles.namesProfile(["--user-data-dir=/tmp/loom/profiles/./A/"], userDataDirectory: profile))
        #expect(!ChromiumProfiles.namesProfile(["--user-data-dir=/tmp/loom/profiles/AB"], userDataDirectory: profile))
        #expect(!ChromiumProfiles.namesProfile(["/tmp/loom/profiles/A"], userDataDirectory: profile))
        #expect(!ChromiumProfiles.namesProfile([], userDataDirectory: profile))
    }

    @Test("no SingletonLock, or one naming Loom itself: nothing is killed")
    func rienATuer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ChromiumProfiles(root: root).prepareProfile(UUID())
        let profiles = ChromiumProfiles(root: root)
        let ownPath = try #require(ChromiumProfiles.executablePath(of: getpid()))
        let ownExecutable = URL(fileURLWithPath: ownPath)
        #expect(await profiles.terminateStaleProcess(holding: profile, executable: ownExecutable) == false)

        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "host-\(getpid())")
        #expect(await profiles.terminateStaleProcess(holding: profile, executable: ownExecutable) == false,
                "never Loom itself")
    }

    @Test("a live process holding the profile is ended only if it runs that executable on that profile")
    func processusPerime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let profile = try profiles.prepareProfile(UUID())
        let elsewhere = try profiles.prepareProfile(UUID())

        // Stands in for an orphaned Chromium: a shell blocked on its stdin,
        // with this profile on its command line.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "read line", "bash", "--user-data-dir=\(profile.path)"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        let pid = process.processIdentifier
        let shellPath = try #require(ChromiumProfiles.executablePath(of: pid))
        let shell = URL(fileURLWithPath: shellPath)
        for folder in [profile, elsewhere] {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("SingletonLock").path,
                                                       withDestinationPath: "orphan-host-\(pid)")
        }

        #expect(await profiles.terminateStaleProcess(holding: profile,
                                                     executable: URL(fileURLWithPath: "/usr/bin/true")) == false,
                "another executable: a reused pid, left alone")
        #expect(await profiles.terminateStaleProcess(holding: elsewhere, executable: shell) == false,
                "another profile on its command line: not this profile's holder")
        #expect(process.isRunning)

        #expect(await profiles.terminateStaleProcess(holding: profile, executable: shell))
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
    }
}
