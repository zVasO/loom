import Testing
import BunshinCore
import BunshinTerminal
import BunshinTerminalTestSupport
import Foundation

// Intégration contre le vrai noyau : forkpty, DispatchIO, NOTE_EXIT. On passe par
// SessionRuntime entier — la conclusion exigeant exit ET EOF, un adapter qui rate
// l'un des deux fait échouer ces tests par construction.

@Suite("ForkPTYHost — process réels", .serialized)
struct ForkPTYHostTests {

    private func plan(_ script: String, extra: [String: String] = [:]) -> SessionLaunchPlan {
        SessionLaunchPlan(
            command: Command(executable: "/bin/sh", arguments: ["-c", script], environment: extra),
            workingDirectory: FileManager.default.temporaryDirectory)
    }

    @Test("un vrai process de bout en bout : sortie parsée, transcript complet, exit 0")
    func processReelDeBoutEnBout() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try SessionRuntime.launch(
            plan("printf 'bonjour du vrai pty'"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }
        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("pas de .terminated — exit ou EOF manquant à l'appel")
            return
        }
        #expect(report.exitStatus.code == 0)
        #expect(transcript.isFinished)
        #expect(transcript.text.contains("bonjour du vrai pty"))
        let screen = await runtime.snapshot()
        #expect(screen.lines[0].text.hasPrefix("bonjour du vrai pty"), "le moteur a parsé la vraie sortie")
    }

    @Test("l'environnement construit atteint le process enfant (PATH compris)")
    func environnementAtteintLEnfant() async throws {
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            plan("printf \"%s|%s\" \"$BUNSHIN_MARQUEUR\" \"${PATH:+path-present}\"",
                 extra: ["BUNSHIN_MARQUEUR": "vivant"]),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        guard case .terminated = await iterator.next() else { return }
        #expect(transcript.text.contains("vivant|path-present"),
                "overlay de session ET PATH garantis dans l'enfant (recherche §7.3)")
    }

    @Test("stop gracieux sur un vrai process : SIGINT suffit à un agent poli")
    func stopGracieuxSurVraiProcess() async throws {
        let (runtime, events) = try SessionRuntime.launch(
            plan("sleep 30"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: MemoryTranscriptSink()))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        try await Task.sleep(for: .milliseconds(150))   // laisser sh lancer sleep

        let report = await runtime.stop(.graceful)
        #expect(report.exitStatus.code != 0 || report.exitStatus.signal != nil,
                "le process est mort avant l'échéance des 30 s, tué par le SIGINT")
    }
}
