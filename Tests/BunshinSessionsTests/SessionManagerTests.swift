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

    private func pollUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
