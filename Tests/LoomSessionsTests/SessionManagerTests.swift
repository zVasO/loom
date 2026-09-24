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
        #expect(await manager.runtime(for: id) != nil)
        #expect(await manager.state(of: id) == .starting)
    }

    @Test("a terminated session drops its token, keeps its screen, and frees the runtime once archived")
    func sessionTermineeLibereSesRessources() async throws {
        let pty = ScriptedPTYHost()
        let manager = makeManager(pty: pty)
        let id = try await manager.launch(spec())
        let token = try #require(await manager.hookToken(for: id))
        #expect(await manager.runtime(for: id) != nil)

        pty.exit(code: 0)
        _ = await pollUntil { await manager.state(of: id) == .completed }

        #expect(await manager.hookToken(for: id) == nil)
        #expect(await manager.session(forToken: token) == nil,
                "the token of a dead session no longer validates")
        #expect(await manager.runtime(for: id) != nil,
                "a closed session still shows its last screen until it is archived")

        await manager.archive(id)
        #expect(await manager.runtime(for: id) == nil,
                "archiving a dead session releases its runtime and scrollback")
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

    @Test("a state is announced only once the database holds it")
    func laBaseEstEcriteAvantLAnnonce() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-order-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)
        let updates = await manager.stateUpdates()
        let id = try await manager.launch(spec())

        // The UI reloads the store the moment it receives a terminal state
        // (AppModel.observeStates): reading it here reproduces that exactly.
        let persisted = Task { () -> SessionState? in
            for await update in updates where update.state == .completed {
                return ((try? store.session(id: id)) ?? nil)?.state
            }
            return nil
        }
        pty.exit(code: 0)

        #expect(await persisted.value == .completed,
                "announcing before writing makes the reader see the previous state")
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

    // A PR review runs in a worktree somebody else prepared. The record must
    // still say so: the git panel and the ship actions only work on sessions
    // that carry a worktree path.
    @Test("a session on an existing worktree records it, without creating anything")
    func lancementSurWorktreeExistant() async throws {
        let repo = try await makeFixtureRepo()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-wte-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        var spec = spec()
        spec.worktree = .existing(path: repo, branch: "feature/pr-7")
        let id = try await manager.launch(spec)

        #expect(pty.openedWorkingDirectory == repo, "the agent starts where it was told")
        let record = try #require(try store.session(id: id))
        #expect(record.worktreePath == repo.path)
        #expect(record.branch == "feature/pr-7")
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
        let native = SessionID()   // the conversation a `/resume <id>` moved it to, last time
        let record = SessionRecord(id: id, title: "resume-me", agentID: "claude-code",
                                   state: .interrupted, createdAt: Date(), nativeSessionID: native)
        try store.insert(record)

        let command = Command(executable: "claude",
                              arguments: ["--resume", native.rawValue.uuidString])
        try await manager.resume(record, command: command,
                                 workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))

        #expect(await manager.runtime(for: id) != nil,
                "same identifier: the history stays one continuous thread")
        #expect(await manager.state(of: id) == .starting)
        #expect(try store.session(id: id)?.state == .starting, "the database follows the resume")
        #expect(await manager.nativeSessionID(of: id) == native,
                "the manager picks the resume up where the record left it: on the native conversation")
    }

    @Test("`/resume <id>` in the terminal: SessionStart moves the session onto another native conversation")
    func resumeNatifDepuisLeTerminal() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-native-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let manager = makeManagerWithStore(store: store, pty: ScriptedPTYHost())
        let updates = await manager.identityUpdates()

        let imposed = SessionID()
        var spec = spec()
        spec.sessionID = imposed
        let id = try await manager.launch(spec)
        let token = try #require(await manager.hookToken(for: id))
        #expect(await manager.nativeSessionID(of: id) == imposed, "at birth, the imposed UUID")

        func sessionStart(_ native: SessionID, source: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionStart", "source": source,
                "session_id": native.rawValue.uuidString, "cwd": "/tmp",
            ])
        }

        // The first SessionStart of a fresh launch: the UUID we imposed — noise.
        await manager.ingestHookPayload(sessionStart(imposed, source: "startup"), token: token)
        #expect(try store.session(id: id)?.nativeSessionID == nil)

        // The user types `/resume <other>`: same process, another conversation.
        let other = SessionID()
        await manager.ingestHookPayload(sessionStart(other, source: "resume"), token: token)
        #expect(await manager.nativeSessionID(of: id) == other)
        #expect(try store.session(id: id)?.nativeSessionID == other,
                "the record follows: the next Resume must replay THIS conversation")
        #expect(await manager.state(of: id) == .starting, "identity is not state")
        var iterator = updates.makeAsyncIterator()
        let announced = await iterator.next()
        #expect(announced == SessionManager.IdentityUpdate(id: id, nativeSessionID: other),
                "the UI hears about the switch — ring, info panel and lists follow")

        // `compact` repeats the current id: nothing written, nothing announced.
        await manager.ingestHookPayload(sessionStart(other, source: "compact"), token: token)
        #expect(try store.session(id: id)?.nativeSessionID == other)

        // Back on the imposed conversation: the column returns to NULL.
        await manager.ingestHookPayload(sessionStart(imposed, source: "resume"), token: token)
        #expect(try store.session(id: id)?.nativeSessionID == nil)
        let restored = await iterator.next()
        #expect(restored == SessionManager.IdentityUpdate(id: id, nativeSessionID: imposed),
                "one announcement per switch: compact was silent, the way back is not")

        await manager.ingestHookPayload(sessionStart(SessionID(), source: "resume"), token: "forged")
        #expect(await manager.nativeSessionID(of: id) == imposed, "a forged token moves nothing")
    }

    @Test("a status line update reports the window once, and moves no state")
    func fenetreRapportee() async throws {
        let manager = makeManager()
        let updates = await manager.windowUpdates()
        let id = try await manager.launch(spec())
        let token = try #require(await manager.hookToken(for: id))
        let update = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "LoomStatusLine",
            "context_window": ["context_window_size": 1_000_000],
        ])

        await manager.ingestHookPayload(update, token: token)
        await manager.ingestHookPayload(update, token: token)   // every message: same size
        #expect(await manager.contextWindow(of: id) == 1_000_000)
        #expect(await manager.state(of: id) == .starting, "a window is not a state")

        let smaller = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "LoomStatusLine",
            "context_window": ["context_window_size": 200_000],
        ])
        await manager.ingestHookPayload(smaller, token: token)   // /model to a 200k model
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == SessionManager.WindowUpdate(id: id, windowTokens: 1_000_000))
        #expect(second == SessionManager.WindowUpdate(id: id, windowTokens: 200_000),
                "one update per change: the repeat was silent")

        await manager.ingestHookPayload(update, token: "forged")
        #expect(await manager.contextWindow(of: id) == 200_000, "a forged token reports nothing")
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
