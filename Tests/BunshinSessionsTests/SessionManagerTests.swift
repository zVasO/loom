import Testing
import BunshinCore
import BunshinPersistence
import BunshinSessions
import BunshinTerminal
import BunshinTerminalTestSupport
import Foundation

// Seam convenu : l'interface publique de SessionManager — l'orchestrateur qui relie
// SessionRuntime (process vivant) et StateEngine (vérité des états). UC-1/UC-2.

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

    @Test("lancer une session : elle est listée, en starting, avec un runtime vivant (UC-1)")
    func lancerUneSession() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())
        #expect(await manager.sessions() == [id])
        #expect(await manager.state(of: id) == .starting)
    }

    @Test("l'exit du process remonte dans l'état : completed ou failed (STA-05)")
    func exitRemonteDansLEtat() async throws {
        let pty = ScriptedPTYHost()
        let manager = makeManager(pty: pty)
        let id = try await manager.launch(spec())

        pty.exit(code: 0)
        let completed = await pollUntil { await manager.state(of: id) == .completed }
        #expect(completed, "le pump d'événements traduit l'exit en transition d'état")
    }

    @Test("les hooks arrivent par le manager et priment (STA-01/STA-03)")
    func hooksArriventParLeManager() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(await manager.state(of: id) == .working)

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(await manager.state(of: id) == .needsInput)
    }

    @Test("arrêter une session via le manager (SES-06)")
    func arreterUneSession() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .interrupt = signal { host.exit(code: 130) }
        }
        let manager = makeManager(pty: pty)
        let id = try await manager.launch(spec())

        await manager.stop(id)
        let failed = await pollUntil { await manager.state(of: id) == .failed }
        #expect(failed, "exit 130 ≠ 0 → failed, décidé par le StateEngine, pas par le runtime")
    }

    @Test("le circuit hooks complet : token par session, payload brut → état (STA-01)")
    func circuitHooksComplet() async throws {
        let manager = makeManager()
        let id = try await manager.launch(spec())
        let token = try #require(await manager.hookToken(for: id), "chaque session naît avec son token")
        #expect(await manager.session(forToken: token) == id)

        let stop = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "last_assistant_message": "Deux pistes possibles — laquelle veux-tu ?",
        ])
        await manager.ingestHookPayload(stop, token: token)
        #expect(await manager.state(of: id) == .needsInput, "payload brut → interpret → réducteur → badge")

        let prompt = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit"])
        await manager.ingestHookPayload(prompt, token: "token-forgé")
        #expect(await manager.state(of: id) == .needsInput, "un token forgé ne produit aucune transition")
    }

    @Test("la vérité des états atterrit en base : record, journal, issue (DAT-02, STA-06)")
    func etatsEnBase() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-mgr-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        let id = try await manager.launch(spec())
        #expect(try store.session(id: id)?.state == .starting, "la session naît en base")

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(try store.session(id: id)?.state == .working, "chaque transition met la base à jour")

        pty.exit(code: 0)
        let recorded = await pollUntil {
            (try? store.session(id: id))??.state == .completed
        }
        #expect(recorded)
        let record = try #require(try store.session(id: id))
        #expect(record.exitCode == 0)
        #expect(record.endedAt != nil)

        let journal = try store.transitions(session: id)
        #expect(journal.map(\.to) == [.working, .completed], "le journal STA-06 raconte l'histoire")
        #expect(journal.map(\.source) == [.hook, .process])
    }

    @Test("agent sans hooks : les échantillons traversent l'interprète jusqu'au badge (STA-02)")
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

        pty.emit("Que voulez-vous faire ?\r\n❯ ")

        let badged = await pollUntil { await manager.state(of: id) == .needsInput }
        #expect(badged, "silence + motif d'invite, soutenus : la carte se badge sans aucun hook")
    }

    @Test("l'UI observe les états par un flux : chaque transition réelle est poussée")
    func fluxDEtatsPourLUI() async throws {
        let manager = makeManager()
        let updates = await manager.stateUpdates()
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)   // sans effet : pas de doublon

        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first?.id == id)
        #expect(first?.state == .working)
        #expect(second?.state == .needsInput, "seules les transitions réelles sont poussées")
    }

    @Test("UC-1 complet : le lancement crée le worktree et la session y travaille isolée")
    func lancementSurWorktree() async throws {
        let repo = try await makeFixtureRepo()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-wt-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        var spec = spec()
        spec.worktree = .create(repo: repo, slug: "corrige-le-cache")
        let id = try await manager.launch(spec)

        let opened = try #require(pty.openedWorkingDirectory)
        #expect(opened.lastPathComponent == "corrige-le-cache",
                "l'agent démarre DANS le worktree, pas dans le repo")
        #expect(FileManager.default.fileExists(atPath: opened.appendingPathComponent("README.md").path),
                "le worktree est un checkout complet")
        let record = try #require(try store.session(id: id))
        #expect(record.branch == "bunshin/corrige-le-cache", "la branche de session est en base")
        #expect(record.worktreePath == opened.path)
    }

    @Test("needs_input déclenche la notification, et elle seule (STA-04)")
    func notificationSurNeedsInput() async throws {
        let spy = SpyNotifier()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ScriptedPTYHost(),
                                                             transcript: MemoryTranscriptSink()),
            notifier: spy)
        let id = try await manager.launch(spec())

        await manager.apply(.hook(.userPromptSubmit), to: id)
        #expect(spy.all().isEmpty, "working ne notifie pas")

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(spy.all().map(\.session) == [id], "le badge needs_input part en notification")

        await manager.apply(.hook(.stop(awaitsReply: true)), to: id)
        #expect(spy.all().count == 1, "pas de spam : une transition, une notification")
    }

    @Test("la Reprise relance la session interrompue sous le MÊME identifiant (UC-7)")
    func repriseDeSessionInterrompue() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-resume-\(UUID().uuidString.prefix(8)).sqlite")
        let store = try SessionStore(path: dbURL.path)
        let pty = ScriptedPTYHost()
        let manager = SessionManager(
            runtimeDependencies: SessionRuntime.Dependencies(ptyHost: pty,
                                                             transcript: MemoryTranscriptSink()),
            store: store)

        let id = SessionID()
        let record = SessionRecord(id: id, title: "reprise-moi", agentID: "claude-code",
                                   state: .interrupted, createdAt: Date())
        try store.insert(record)

        let command = Command(executable: "claude",
                              arguments: ["--resume", id.rawValue.uuidString])
        try await manager.resume(record, command: command,
                                 workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))

        #expect(await manager.sessions() == [id], "même identifiant : l'historique reste un fil continu")
        #expect(await manager.state(of: id) == .starting)
        #expect(try store.session(id: id)?.state == .starting, "la base suit la reprise")
    }

    @Test("archiver via le manager : état + base (SES-07)")
    func archiverUneSession() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-arch-\(UUID().uuidString.prefix(8)).sqlite")
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
            .appendingPathComponent("bunshin-mgr-repo-\(UUID().uuidString.prefix(8))")
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
