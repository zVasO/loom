import Testing
import LoomCore
@testable import LoomChromium
import Darwin
import Foundation

// The spawn against the real kernel, with /bin/sh standing in for Chromium:
// what matters is which descriptors, signals and group the child is born
// with, and a shell shows all of them.

/// Raw descriptors, bounded in time: a test that hangs is worse than one that fails.
private enum SpawnPipes {

    static func write(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// Until EOF, until `enough` says so, or until `timeout`.
    static func read(_ descriptor: Int32, timeout: Duration = .seconds(5),
                     until enough: (Data) -> Bool = { _ in false }) -> Data {
        let deadline = ContinuousClock.now + timeout
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !enough(collected) {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { break }
            let milliseconds = left.components.seconds * 1_000
                + left.components.attoseconds / 1_000_000_000_000_000
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, max(Int32(clamping: milliseconds), 1))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { break }   // EOF
            collected.append(contentsOf: chunk[0..<count])
        }
        return collected
    }

    /// The child's wait status, polled; nil if it still runs at `timeout`.
    static func waitStatus(_ pid: pid_t, timeout: Duration = .seconds(5)) -> Int32? {
        let deadline = ContinuousClock.now + timeout
        var status: Int32 = 0
        while ContinuousClock.now < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result < 0 && errno != EINTR { return nil }
            usleep(10_000)
        }
        return nil
    }
}

/// A spawned child and the descriptors still ours to close: each is closed
/// once, never a number another test has been handed since — nor the pid.
private final class SpawnedChild {
    let child: ChromiumSpawnedChild
    private var owned: Set<Int32>
    private var reaped = false

    init(_ executable: String, _ arguments: [String]) throws {
        child = try ChromiumSpawn.spawn(executable: executable, arguments: arguments,
                                        environment: ChromiumLaunchPlan.minimalEnvironment())
        owned = [child.readDescriptor, child.writeDescriptor, child.stderrDescriptor]
    }

    func close(_ descriptor: Int32) {
        if owned.remove(descriptor) != nil {
            _ = Darwin.close(descriptor)
        }
    }

    /// The child's wait status; nil if it still runs at `timeout`.
    func waitStatus(timeout: Duration = .seconds(5)) -> Int32? {
        let status = SpawnPipes.waitStatus(child.pid, timeout: timeout)
        if status != nil { reaped = true }
        return status
    }

    /// Closes what is left; kills and reaps the child unless a test reaped it.
    func finish() {
        for descriptor in owned {
            _ = Darwin.close(descriptor)
        }
        owned = []
        guard !reaped else { return }
        reaped = true
        var status: Int32 = 0
        if waitpid(child.pid, &status, WNOHANG) == 0 {
            _ = kill(child.pid, SIGKILL)
            _ = waitpid(child.pid, &status, 0)
        }
    }
}

@Suite("ChromiumSpawn — fds 3 and 4, and nothing else", .serialized)
struct ChromiumSpawnTests {

    /// Blocks `number` on the calling thread around `body`: posix_spawn runs on it.
    private func withSignalBlocked<T>(_ number: Int32, _ body: () throws -> T) rethrows -> T {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, number)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &set, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return try body()
    }

    /// SIG_IGN survives exec. SIGUSR2: ForkPTYHost's suite ignores SIGUSR1 the same way.
    private func withSignalIgnored<T>(_ number: Int32, _ body: () throws -> T) rethrows -> T {
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignore.sa_mask)
        ignore.sa_flags = 0
        var previous = sigaction()
        sigaction(number, &ignore, &previous)
        defer { sigaction(number, &previous, nil) }
        return try body()
    }

    @Test("frames written on our end reach the child's fd 3 and come back from its fd 4")
    func tramesAllerRetour() throws {
        let spawned = try SpawnedChild("/bin/sh", ["-c", "exec cat <&3 >&4"])
        defer { spawned.finish() }
        var frames = Array(#"{"id":1,"method":"Browser.getVersion"}"#.utf8)
        frames.append(0)
        frames += Array(#"{"id":2,"method":"Target.getTargets","params":{}}"#.utf8)
        frames.append(0)

        #expect(SpawnPipes.write(frames, to: spawned.child.writeDescriptor))
        let echoed = SpawnPipes.read(spawned.child.readDescriptor) { $0.count >= frames.count }
        #expect(Array(echoed) == frames, "cat reads fd 3 and writes fd 4: the two directions are not crossed")
    }

    @Test("closing our write end is the child's EOF on fd 3: it exits")
    func finDuTuyau() throws {
        let spawned = try SpawnedChild("/bin/sh", ["-c", "exec cat <&3 >&4"])
        defer { spawned.finish() }

        spawned.close(spawned.child.writeDescriptor)

        let status = try #require(spawned.waitStatus(), "cat never saw EOF on fd 3")
        #expect(ChromiumExit(waitStatus: status) == .status(0))
        #expect(SpawnPipes.read(spawned.child.readDescriptor).isEmpty, "fd 4 ends with the child, nothing pending")
    }

    // POSIX_SPAWN_CLOEXEC_DEFAULT: a PTY master or the hook socket that Loom
    // left inheritable must not outlive an agent inside Chromium.
    @Test("a descriptor Loom left inheritable never reaches the child: only 0 to 4 are open")
    func descripteurEtrangerNonHerite() throws {
        var stray: [Int32] = [-1, -1]
        let piped = pipe(&stray)
        try #require(piped == 0)
        // High and inheritable: no CLOEXEC, and a number neither sh nor ls opens on its own.
        let inheritable = fcntl(stray[1], F_DUPFD, 200)
        defer {
            _ = Darwin.close(stray[0])
            _ = Darwin.close(stray[1])
            if inheritable >= 0 { _ = Darwin.close(inheritable) }
        }
        try #require(inheritable >= 200)
        #expect(fcntl(inheritable, F_GETFD) & FD_CLOEXEC == 0)

        let spawned = try SpawnedChild("/bin/sh", ["-c", "exec ls /dev/fd >&4"])
        defer { spawned.finish() }
        let listing = String(decoding: SpawnPipes.read(spawned.child.readDescriptor), as: UTF8.self)
        let open = Set(listing.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) })

        #expect(open.contains(3) && open.contains(4), "fds 3 and 4 are mapped — saw \(listing)")
        #expect(!open.contains(inheritable), "fd \(inheritable) was inherited — saw \(listing)")
        // ls opens /dev/fd itself, right above 4: nothing else is there.
        #expect(open.allSatisfy { $0 < 10 }, "only 0-4 and ls's own — saw \(listing)")
    }

    @Test("stdout goes nowhere, stderr comes to us, stdin reads nothing")
    func sortiesStandard() throws {
        let spawned = try SpawnedChild("/bin/sh", ["-c", "cat; echo out; echo err >&2"])
        defer { spawned.finish() }

        let errors = String(decoding: SpawnPipes.read(spawned.child.stderrDescriptor), as: UTF8.self)
        #expect(errors == "err\n", "stderr is our pipe, stdout /dev/null — saw \(errors)")
        let status = try #require(spawned.waitStatus(), "cat waited on an inherited stdin")
        #expect(ChromiumExit(waitStatus: status) == .status(0))
    }

    @Test("the child leads a process group of its own: kill(-pid) reaches its helpers")
    func groupePropre() throws {
        let spawned = try SpawnedChild("/bin/sleep", ["5"])
        defer { spawned.finish() }

        #expect(getpgid(spawned.child.pid) == spawned.child.pid)
        #expect(getpgid(spawned.child.pid) != getpgrp())
    }

    @Test("born from a thread that blocks SIGTERM, the child still dies of it")
    func masqueVide() throws {
        let spawned = try withSignalBlocked(SIGTERM) { try SpawnedChild("/bin/sleep", ["30"]) }
        defer { spawned.finish() }

        _ = kill(spawned.child.pid, SIGTERM)

        let status = try #require(spawned.waitStatus(timeout: .seconds(3)),
                                  "still asleep: the spawning thread's mask was inherited")
        #expect(ChromiumExit(waitStatus: status) == .signal(SIGTERM))
    }

    @Test("a signal Loom ignores is back to its default in the child")
    func dispositionsParDefaut() throws {
        let spawned = try withSignalIgnored(SIGUSR2) { try SpawnedChild("/bin/sleep", ["30"]) }
        defer { spawned.finish() }

        _ = kill(spawned.child.pid, SIGUSR2)

        let status = try #require(spawned.waitStatus(timeout: .seconds(3)),
                                  "still asleep: SIG_IGN survived the exec")
        #expect(ChromiumExit(waitStatus: status) == .signal(SIGUSR2))
    }

    @Test("a relative path is refused: posix_spawn searches no PATH")
    func cheminRelatifRefuse() {
        #expect(throws: ChromiumSpawnError.notAbsolute("sh")) {
            _ = try ChromiumSpawn.spawn(executable: "sh", arguments: [], environment: [:])
        }
    }

    @Test("a missing executable fails the spawn itself, with its errno")
    func executableAbsent() {
        #expect(throws: ChromiumSpawnError.spawnFailed(executable: "/nonexistent/loom-chrome", errno: ENOENT)) {
            _ = try ChromiumSpawn.spawn(executable: "/nonexistent/loom-chrome", arguments: [], environment: [:])
        }
    }
}

@Suite("ChromiumProcess — exit, stderr, readiness, shutdown", .serialized, .timeLimit(.minutes(1)))
struct ChromiumProcessTests {

    /// The plan appends `--remote-debugging-pipe` and `--user-data-dir=…`:
    /// after `sh -c script` they are only $0 and $1.
    private func launch(_ executable: String, _ arguments: [String]) throws -> (ChromiumProcess, URL) {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-chromium-\(UUID().uuidString.prefix(8))")
        let plan = ChromiumLaunchPlan(executable: URL(fileURLWithPath: executable, isDirectory: false),
                                      arguments: arguments, userDataDirectory: profile)
        let process = try ChromiumProcess.launch(plan)
        return (process, profile)
    }

    // Exits are awaited bounded: `exited()` ignores cancellation, so a child
    // that never ends would outlive the suite's time limit and hang the run.

    @Test("a child that writes to stderr and exits 3: status 3, its words in the tail")
    func sortieEtStderr() async throws {
        let (process, profile) = try launch("/bin/sh", ["-c", "echo 'profile is busy' >&2; exit 3"])
        defer { try? FileManager.default.removeItem(at: profile) }

        let exit = await process.waitForExit(upTo: .seconds(10))
        #expect(exit == .status(3))
        if exit != nil {
            let known = await process.exited()
            #expect(known == .status(3), "once known, the exit is answered at once")
        }
        // Drained on a queue of its own: while the whole test run starts,
        // the words can take seconds to be read.
        let deadline = ContinuousClock.now + .seconds(10)
        while !process.stderrTail.contains("profile is busy"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(process.stderrTail.contains("profile is busy"))
        let permissions = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700, "the profile holds cookies: private from its creation")
        await process.shutdown()
    }

    @Test("shutdown takes a deaf child down with SIGTERM, within seconds")
    func arretParSigterm() async throws {
        let (process, profile) = try launch("/bin/sh", ["-c", "exec sleep 30"])
        defer { try? FileManager.default.removeItem(at: profile) }
        let start = ContinuousClock.now

        await process.shutdown(grace: .milliseconds(300))

        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(process.knownExit == .signal(SIGTERM), "Browser.close and EOF went unheard; SIGTERM did it")
    }

    @Test("a child that ignores SIGTERM is killed with its group")
    func arretParSigkill() async throws {
        let (process, profile) = try launch("/bin/sh", ["-c", "trap '' TERM; echo trapped >&2; sleep 30; exit 0"])
        defer { try? FileManager.default.removeItem(at: profile) }
        // The signal goes out once the trap is installed, never on a timer's guess.
        var polls = 0
        while !process.stderrTail.contains("trapped") && polls < 500 {
            try await Task.sleep(for: .milliseconds(20))
            polls += 1
        }
        let start = ContinuousClock.now

        await process.shutdown(grace: .milliseconds(200))

        #expect(ContinuousClock.now - start < .seconds(6))
        #expect(process.knownExit == .signal(SIGKILL))
    }

    @Test("ready reports an exit before any answer, with the stderr tail")
    func sortieAvantReponse() async throws {
        let (process, profile) = try launch(
            "/bin/sh", ["-c", "echo 'Failed to create a ProcessSingleton for your profile directory' >&2; exit 21"])
        defer { try? FileManager.default.removeItem(at: profile) }

        do {
            let version = try await process.ready(timeout: .seconds(10))
            Issue.record("ready answered \(version.product) for a child that exited")
        } catch let error as ChromiumProcessError {
            guard case .exitedBeforeReady(let exit, let tail) = error else {
                Issue.record("expected an early exit, got \(error)")
                return
            }
            #expect(exit == .status(21))
            #expect(tail.contains("ProcessSingleton"))
            #expect(error.isProfileInUse, "the pool sweeps the orphan holding the profile, then retries once")
        }
        await process.shutdown()
    }

    // A peer in bash: reads one NUL-terminated frame on fd 3, answers its id on
    // fd 4, then waits for EOF on fd 3 like Chromium does.
    @Test("ready reads the version a peer answers on fd 4; EOF on fd 3 ends the peer",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/bash")))
    func pretAvecUnPair() async throws {
        let script = #"""
        IFS= read -r -d '' frame <&3
        id=$(printf '%s' "$frame" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
        result='{"protocolVersion":"1.3","product":"HeadlessChrome/141.0.7390.37","userAgent":"HeadlessChrome/141"}'
        printf '{"id":%s,"result":%s}\n' "$id" "$result" | tr '\n' '\000' >&4
        exec cat <&3 >/dev/null
        """#
        let (process, profile) = try launch("/bin/bash", ["-c", script])
        defer { try? FileManager.default.removeItem(at: profile) }

        let version = try await process.ready(timeout: .seconds(10))
        #expect(version.major == 141)
        #expect(version.product == "HeadlessChrome/141.0.7390.37")
        #expect(version.protocolVersion == "1.3")

        await process.shutdown(grace: .seconds(1))
        #expect(process.knownExit == .status(0), "the peer left on the pipe's EOF, before any signal")
    }

    private static var realChromium: String? {
        guard let path = ProcessInfo.processInfo.environment["LOOM_CHROMIUM"],
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    @Test("a real Chromium answers Browser.getVersion, then leaves on shutdown",
          .enabled(if: realChromium != nil))
    func vraiChromium() async throws {
        let path = try #require(Self.realChromium)
        let kind = ChromiumLocator.kind(ofExecutableAt: path)
        let headless: [String] = kind == .headlessShell ? [] : ["--headless=new"]
        let (process, profile) = try launch(path, headless + ["--no-first-run", "--no-default-browser-check",
                                                              "--use-mock-keychain"])
        defer { try? FileManager.default.removeItem(at: profile) }

        let version = try await process.ready(timeout: .seconds(30))
        #expect(version.isSupported, "\(version.product) is below the floor")

        await process.shutdown(grace: .seconds(5))
        #expect(process.knownExit != nil)
    }
}

@Suite("Browser.getVersion — the major version and the floor")
struct ChromiumVersionTests {

    @Test("chrome-headless-shell's product")
    func produitHeadless() {
        let version = ChromiumProcess.parseVersion(product: "HeadlessChrome/141.0.7390.37",
                                                   userAgent: "", protocolVersion: "1.3")
        #expect(version?.major == 141)
        #expect(version?.protocolVersion == "1.3")
    }

    @Test("a full browser's product")
    func produitNavigateur() {
        let version = ChromiumProcess.parseVersion(product: "Chrome/120.0.6099.71", userAgent: "",
                                                   protocolVersion: "1.3")
        #expect(version?.major == 120)
    }

    @Test("a product without a version: the user agent's Chrome token")
    func repliSurUserAgent() {
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/131.0.0.0 Safari/537.36 Edg/131.0.2903.70"
        let version = ChromiumProcess.parseVersion(product: "Edge", userAgent: userAgent, protocolVersion: "1.3")
        #expect(version?.major == 131)
    }

    @Test("nothing to read a version from: nil")
    func illisible() {
        #expect(ChromiumProcess.parseVersion(product: "", userAgent: "Mozilla/5.0", protocolVersion: "") == nil)
        #expect(ChromiumProcess.parseVersion(product: "Chrome/", userAgent: "", protocolVersion: "") == nil)
    }

    @Test("the floor is 120")
    func plancher() {
        let below = ChromiumVersion(product: "Chrome/119.0", major: 119, userAgent: "", protocolVersion: "1.3")
        let floor = ChromiumVersion(product: "Chrome/120.0", major: 120, userAgent: "", protocolVersion: "1.3")
        #expect(!below.isSupported)
        #expect(floor.isSupported)
    }

    @Test("waitpid's status decoded by hand: exit code, signal, signal with a core")
    func statutDeWaitpid() {
        #expect(ChromiumExit(waitStatus: 3 << 8) == .status(3))
        #expect(ChromiumExit(waitStatus: 0) == .status(0))
        #expect(ChromiumExit(waitStatus: SIGTERM) == .signal(SIGTERM))
        #expect(ChromiumExit(waitStatus: 0x80 | SIGSEGV) == .signal(SIGSEGV))
    }
}

@Suite("ChromiumLaunchPlan — the command line and the environment")
struct ChromiumLaunchPlanTests {

    private let profile = URL(fileURLWithPath: "/tmp/loom-profile", isDirectory: true)
    private let executable = URL(fileURLWithPath: "/Applications/Chromium.app/Contents/MacOS/Chromium",
                                 isDirectory: false)

    @Test("the pipe and the profile are added once, after the flags")
    func pipeEtProfilAjoutes() {
        let plan = ChromiumLaunchPlan(executable: executable, arguments: ["--headless=new"],
                                      environment: [:], userDataDirectory: profile)
        #expect(plan.spawnArguments == ["--headless=new", "--remote-debugging-pipe",
                                        "--user-data-dir=/tmp/loom-profile"])
    }

    @Test("a plan that names them already is left as it is")
    func pasDeDoublon() {
        let arguments = ["--user-data-dir=/elsewhere", "--remote-debugging-pipe", "--mute-audio"]
        let plan = ChromiumLaunchPlan(executable: executable, arguments: arguments,
                                      environment: [:], userDataDirectory: profile)
        #expect(plan.spawnArguments == arguments)
    }

    @Test("the minimal environment keeps HOME and the locale, drops tokens and proxies")
    func environnementMinimal() {
        let base = ["HOME": "/Users/ada", "LANG": "fr_FR.UTF-8", "TMPDIR": "/var/folders/x",
                    "ANTHROPIC_API_KEY": "sk-secret", "HTTPS_PROXY": "http://proxy:8080",
                    "PATH": "/Users/ada/bin:/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        let environment = ChromiumLaunchPlan.minimalEnvironment(from: base)
        #expect(environment["HOME"] == "/Users/ada")
        #expect(environment["LANG"] == "fr_FR.UTF-8")
        #expect(environment["TMPDIR"] == "/var/folders/x")
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
    }
}
