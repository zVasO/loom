import Testing
import BunshinCore
import BunshinTerminal
import Foundation

// Tests au seam convenu : l'interface publique de SessionRuntime, via ScriptedPTYHost.
// Aucun test ne franchit la queue de session ni ne touche le moteur.

@Suite("SessionRuntime — cycle de vie")
struct SessionRuntimeTests {

    @Test("launch démarre l'agent et émet .started en premier")
    func launchEmetStarted() async throws {
        let pty = ScriptedPTYHost()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("le premier événement doit être .started")
            return
        }
    }

    @Test("l'exit conclut : transcript complet et flushé avant .terminated, flux terminé après")
    func exitConclutAvecTranscriptComplet() async throws {
        let pty = ScriptedPTYHost()
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        pty.emit("Analyse du dépôt…\r\n")
        pty.emit("Correctif appliqué, 42 tests verts.\r\n")
        pty.exit(code: 0)

        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("l'exit du process doit émettre .terminated")
            return
        }
        #expect(report.exitStatus.code == 0)
        #expect(transcript.isFinished, "le transcript est flushé et fermé AVANT .terminated (NFR-R)")
        #expect(transcript.text.contains("42 tests verts"),
                "aucun octet émis avant l'exit ne manque au transcript")
        #expect(await iterator.next() == nil, "le flux se termine juste après .terminated")
    }

    @Test("un agent sourd à SIGINT et SIGTERM finit SIGKILLé, dans l'ordre de l'échelle (SES-06)")
    func escaladeJusquAuKill() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .kill = signal { host.exit(bySignal: 9) }   // seul SIGKILL a raison de lui
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let ladder = ShutdownLadder(steps: [
            .init(signal: .interrupt, grace: .milliseconds(20)),
            .init(signal: .terminate, grace: .milliseconds(20)),
            .init(signal: .kill, grace: .milliseconds(200)),
        ])
        let report = await runtime.stop(ladder)

        #expect(pty.receivedSignals == [.interrupt, .terminate, .kill])
        #expect(report.exitStatus.code == nil)
        #expect(report.exitStatus.signal == 9)
    }

    @Test("l'escalade s'arrête dès que l'agent sort")
    func escaladeInterrompueParLaSortie() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .interrupt = signal { host.exit(code: 130) }   // agent poli
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let report = await runtime.stop(.graceful)

        #expect(pty.receivedSignals == [.interrupt], "ni SIGTERM ni SIGKILL pour un agent qui obéit")
        #expect(report.exitStatus.code == 130)
    }

    @Test("les octets du PTY alimentent le moteur ; snapshot() rend l'écran courant")
    func snapshotRefleteLEcran() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty,
                                               transcript: MemoryTranscriptSink(),
                                               makeEngine: { geometry, _ in LineEngine(geometry: geometry) }))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        pty.emit("Analyse du dépôt…\r\n")
        pty.emit("Correctif appliqué.")

        let screen = await runtime.snapshot()
        let texts = screen.lines.map(\.text)
        #expect(texts.contains("Analyse du dépôt…"))
        #expect(texts.contains("Correctif appliqué."), "le dernier chunk est déjà parsé au retour du snapshot")
    }
}
