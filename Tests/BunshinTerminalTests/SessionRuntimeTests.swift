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
}
