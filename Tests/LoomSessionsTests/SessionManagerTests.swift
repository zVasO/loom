import Testing
import LoomCore
import LoomPersistence
import LoomSessions
import LoomTerminal
import LoomTerminalTestSupport
import Foundation

// Agreed seam: SessionManager's public interface — the orchestrator linking
// SessionRuntime (live process) and StateEngine (source of truth for states). UC-1/UC-2.

@Suite("SessionManager — orchestration")
struct SessionManagerTests {

    private func makeManager(pty: ScriptedPTYHost = ScriptedPTYHost()) -> SessionManager {
        SessionManager(runtimeDependencies: SessionRuntime.Dependencies(
            ptyHost: pty, transcript: MemoryTranscriptSink()))
    }

    private func spec() -> SessionManager.SessionSpec {
        SessionManager.SessionSpec(command: Command(executable: "/fake/claude"),
                                   workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))
    }

    @Test("launching a session: it is listed, in starting, with a live runtime (UC-1)")
    func lancerUneSession() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())
        #expect(await manager.sessions() == [id])
        #expect(await manager.state(of: id) == .starting)
    }

    @Test("process exit surfaces in the state: completed or failed (STA-05)")
    func exitRemonteDansLEtat() async throws {
        let pty = ScriptedPTYHost()
        let manager = makeManager(pty: pty)
        let id = try await manager.launch(spec())

        pty.exit(code: 0)
        let completed = await pollUntil { await manager.state(of: id) == .completed }
        #expect(completed, "the event pump translates the exit into a state transition")
    }

    @Test("hooks arrive through the manager and take priority (STA-01/STA-03)")
    func hooksArriventParLeManager() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(await manager.state(of: id) == .working)

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(await manager.state(of: id) == .needsInput)
    }

    @Test("stopping a session via the manager (SES-06)")
    func arreterUneSession() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .interrupt = signal { host.exit(code: 130) }
        }
        let manager = makeManager(pty: pty)
        let id = try await manager.launch(spec())

        await manager.stop(id)
        let failed = await pollUntil { await manager.state(of: id) == .failed }
        #expect(failed, "exit 130 ≠ 0 → failed, decided by the StateEngine, not by the runtime")
    }

    @Test("the full hooks circuit: per-session token, raw payload → state (STA-01)")
    func circuitHooksComplet() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())
        let token = try #require(await manager.hookToken(for: id), "every session is born with its token")
        #expect(await manager.session(forToken: token) == id)

        let stop = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "last_assistant_message": "Two possible approaches — which one do you want?",
        ])
        await manager.ingestHookPayload(stop, token: token)
        #expect(await manager.state(of: id) == .needsInput, "raw payload → interpret → reducer → badge")

        let prompt = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit"])
        await manager.ingestHookPayload(prompt, token: "forged-token")
        #expect(await manager.state(of: id) == .needsInput, "a forged token produces no transition")
    }

    @Test("the state truth lands in the database: record, journal, outcome (DAT-02, STA-06)")
    func etatsEnBase() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-mgr-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        let id = try await manager.launch(spec())
        #expect(try store.session(id: id)?.state == .starting, "the session is born in the database")

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(try store.session(id: id)?.state == .working, "every transition updates the database")

        pty.exit(code: 0)
        let recorded = await pollUntil {
            (try? store.session(id: id))??.state == .completed
        }
        #expect(recorded)
        let record = try #require(try store.session(id: id))
        #expect(record.exitCode == 0)
        #expect(record.endedAt != nil)

        let journal = try store.transitions(session: id)
        #expect(journal.map(\.to) == [.working, .completed], "the STA-06 journal tells the story")
        #expect(journal.map(\.source) == [.hook, .process])
    }

    @Test("agent without hooks: samples travel through the interpreter to the badge (STA-02)")
    func canalHeuristiqueDeBoutEnBout() async throws {
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            tuning: StateEngine.Tuning(hookPriorityWindow: .milliseconds(50),
                                       heuristicHysteresis: .milliseconds(40),
                                       heuristicStaleness: .milliseconds(500)),
            interpreter: HeuristicInterpreter(silenceThreshold: .milliseconds(30)))

        var spec = spec()
        spec.samplingInterval = .milliseconds(25)
        let id = try await manager.launch(spec)

        pty.emit("What do you want to do?\r\n❯ ")

        let badged = await pollUntil { await manager.state(of: id) == .needsInput }
        #expect(badged, "silence + prompt pattern, sustained: the card gets badged without any hook")
    }

    @Test("the UI observes states through a stream: every real transition is pushed")
    func fluxDEtatsPourLUI() async throws {
        let manager = makeManager()
        let updates = await manager.stateUpdates()
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)   // no effect: no duplicate

        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first?.id == id)
        #expect(first?.state == .working)
        #expect(second?.state == .needsInput, "only real transitions are pushed")
    }

    @Test("full UC-1: launch creates the worktree and the session works there in isolation")
    func lancementSurWorktree() async throws {
        let repo = try await makeFixtureRepo()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-wt-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        var spec = spec()
        spec.worktree = .create(repo: repo, slug: "fix-the-cache")
        let id = try await manager.launch(spec)

        let opened = try #require(pty.openedWorkingDirectory)
        #expect(opened.lastPathComponent == "fix-the-cache",
                "the agent starts IN the worktree, not in the repo")
        #expect(FileManager.default.fileExists(atPath: opened.appendingPathComponent("README.md").path),
                "the worktree is a full checkout")
        let record = try #require(try store.session(id: id))
        #expect(record.branch == "loom/fix-the-cache", "the session branch is in the database")
        #expect(record.worktreePath == opened.path)
    }

    @Test("needs_input triggers the notification, and it alone (STA-04)")
    func notificationSurNeedsInput() async throws {
        let spy = SpyNotifier()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ScriptedPTYHost(),
                                                             transcript: MemoryTranscriptSink()),
            notifier: spy)
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(spy.all().isEmpty, "working does not notify")

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(spy.all().map(\.session) == [id], "the needs_input badge goes out as a notification")

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(spy.all().count == 1, "no spam: one transition, one notification")
    }

    @Test("the identifier imposed on the CLI IS the session's — otherwise Resume is dead")
    func identifiantUnique() async throws {
        let manager = makeManager()
        let imposed = SessionID()   // the one the app puts in `claude --session-id`
        var spec = spec()
        spec.sessionID = imposed
        let id = try await manager.launch(spec)
        #expect(id == imposed,
                "a single UUID end to end: command, manager, database — the one --resume will replay")
    }

    @Test("Resume relaunches the interrupted session under the SAME identifier (UC-7)")
    func repriseDeSessionInterrompue() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-resume-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        let id = SessionID()
        let record = SessionRecord(id: id, title: "resume-me", agentID: "claude-code",
                                   state: .interrupted, createdAt: Date())
        try store.insert(record)

        let command = Command(executable: "claude",
                              arguments: ["--resume", id.rawValue.uuidString])
        try await manager.resume(record, command: command,
                                 workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))

        #expect(await manager.sessions() == [id], "same identifier: the history stays one continuous thread")
        #expect(await manager.state(of: id) == .starting)
        #expect(try store.session(id: id)?.state == .starting, "the database follows the resume")
    }

    @Test("archiving via the manager: state + database (SES-07)")
    func archiverUneSession() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-arch-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = makeManagerWithStore(store: store, pty: pty)
        let id = try await manager.launch(spec())
        pty.exit(code: 0)
        _ = await pollUntil { await manager.state(of: id) == .completed }

        await manager.archive(id)
        #expect(await manager.state(of: id) == .archived)
        #expect(try store.session(id: id)?.state == .archived)
    }

    private func makeManagerWithStore(store: SessionStore, pty: ScriptedPTYHost) -> SessionManager {
        SessionManager(runtimeDependencies: SessionRuntime.Dependencies(
            ptyHost: pty, transcript: MemoryTranscriptSink()), store: store)
    }

    private final class SpyNotifier: SessionNotifier, @unchecked Sendable {
        struct Entry { let session: SessionID; let title: String }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func sessionNeedsInput(_ session: SessionID, title: String) {
            lock.withLock { entries.append(Entry(session: session, title: title)) }
        }
        func all() -> [Entry] { lock.withLock { entries } }
    }

    private func makeFixtureRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-mgr-repo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        @discardableResult func git(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = dir
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        try git(["init", "-b", "main"])
        try "# Fixture".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-m", "init"])
        return dir
    }

    private func pollUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
