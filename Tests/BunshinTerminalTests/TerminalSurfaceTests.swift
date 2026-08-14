import Testing
import BunshinCore
import BunshinTerminal
import Foundation

// La projection MainActor du terminal pour SwiftUI (design C retenu, ADR-0008) :
// screen jamais vide, cycle de vie attach/detach structuré, aucune frame quand détaché.

@MainActor
@Suite("TerminalSurface — projection @Observable")
struct TerminalSurfaceTests {

    private func makeRuntime(pty: ScriptedPTYHost = ScriptedPTYHost()) throws -> SessionRuntime {
        try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink())
        ).runtime
    }

    @Test("surface() est idempotente et son écran n'est jamais vide")
    func surfaceIdempotenteEtEcranJamaisVide() throws {
        let runtime = try makeRuntime()
        let surface = runtime.surface()
        #expect(runtime.surface() === surface, "même TerminalID → même instance, partageable entre vues")
        #expect(surface.screen.geometry == TerminalGeometry(cols: 40, rows: 6),
                "avant tout attachement : écran vierge à la bonne géométrie — pas d'état de chargement")
        #expect(surface.screen.lines.count == 6)
        #expect(surface.isAttached == false)
    }

    @Test("attachée, la surface reçoit les frames : l'écran suit la sortie de l'agent")
    func surfaceAttacheeRecoitLesFrames() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        let surface = runtime.surface()
        surface.attach()
        #expect(surface.isAttached)

        pty.emit("Analyse en cours…")
        let arrived = await pollUntil { surface.screen.lines[0].text.hasPrefix("Analyse en cours…") }
        #expect(arrived, "l'écran de la surface doit reproduire la sortie parsée")
    }

    @Test("détachée, la surface gèle sur le dernier écran connu — aucune frame produite")
    func surfaceDetacheeNeRecoitPlusRien() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        let surface = runtime.surface()
        surface.attach()
        pty.emit("premier")
        _ = await pollUntil { surface.screen.lines[0].text.hasPrefix("premier") }

        surface.detach()
        pty.emit(" second")
        try await Task.sleep(for: .milliseconds(80))
        #expect(surface.screen.lines[0].text.hasPrefix("premier"),
                "après détachement : dernier écran connu, pas de mise à jour (TRM-03)")
        #expect(!surface.screen.lines[0].text.contains("second"))
    }

    @Test("send() tape dans le PTY sans exiger de vue attachée (SES-05, message rapide)")
    func sendEcritDansLePty() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        runtime.surface().send("continue\r")
        let written = await pollUntil { String(decoding: pty.writtenBytes, as: UTF8.self) == "continue\r" }
        #expect(written, "la frappe atteint le PTY via la queue de session")
    }

    @Test("attached() suit l'annulation structurée : l'annulation de la tâche détache")
    func attachedSuitLAnnulationStructuree() async throws {
        let runtime = try makeRuntime()
        let surface = runtime.surface()

        let lifecycle = Task { await surface.attached() }
        let attached = await pollUntil { surface.isAttached }
        #expect(attached, "entrer dans attached() attache")

        lifecycle.cancel()
        let detached = await pollUntil { !surface.isAttached }
        #expect(detached, "annuler la tâche (.task de SwiftUI) détache — impossible d'oublier")
    }

    /// Attente active bornée (2 s) — le chemin queue → MainActor est asynchrone par nature.
    private func pollUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
