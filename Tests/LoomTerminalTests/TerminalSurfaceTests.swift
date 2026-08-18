import Testing
import LoomCore
import LoomTerminal
import LoomTerminalTestSupport
import Foundation

// The MainActor projection of the terminal for SwiftUI (design C chosen, ADR-0008):
// screen never empty, structured attach/detach lifecycle, no frame while detached.

@MainActor
@Suite("TerminalSurface — @Observable projection")
struct TerminalSurfaceTests {

    private func makeRuntime(pty: ScriptedPTYHost = ScriptedPTYHost()) throws -> SessionRuntime {
        try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink())
        ).runtime
    }

    @Test("surface() is idempotent and its screen is never empty")
    func surfaceIdempotenteEtEcranJamaisVide() throws {
        let runtime = try makeRuntime()
        let surface = runtime.surface()
        #expect(runtime.surface() === surface, "same TerminalID → same instance, shareable across views")
        #expect(surface.screen.geometry == TerminalGeometry(cols: 40, rows: 6),
                "before any attachment: blank screen at the right geometry — no loading state")
        #expect(surface.screen.lines.count == 6)
        #expect(surface.isAttached == false)
    }

    @Test("attached, the surface receives frames: the screen follows the agent's output")
    func surfaceAttacheeRecoitLesFrames() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        let surface = runtime.surface()
        surface.attach()
        #expect(surface.isAttached)

        pty.emit("Analyzing…")
        let arrived = await pollUntil { surface.screen.lines[0].text.hasPrefix("Analyzing…") }
        #expect(arrived, "the surface's screen must reproduce the parsed output")
    }

    // What the view scrolls through: output pushed off the top must reach the
    // surface as history, or the session pane has nothing to scroll.
    @Test("output scrolled off the screen reaches the surface as history")
    func surfaceExposeLHistorique() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)   // 6 rows
        let surface = runtime.surface()
        surface.attach()

        for index in 1...40 { pty.emit("line \(index)\r\n") }

        let hasHistory = await pollUntil { !surface.history.isEmpty }
        #expect(hasHistory, "the scrollback tail must reach the view layer")
        #expect(surface.history.count >= 30, "one line per scrolled-off row")
        #expect(surface.history.last?.text.contains("line 3") == true,
                "history ends just above the visible screen")
        #expect(surface.historyBase >= 0)
    }

    @Test("detached, the surface freezes on the last known screen — no frame produced")
    func surfaceDetacheeNeRecoitPlusRien() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        let surface = runtime.surface()
        surface.attach()
        pty.emit("first")
        _ = await pollUntil { surface.screen.lines[0].text.hasPrefix("first") }

        surface.detach()
        pty.emit(" second")
        try await Task.sleep(for: .milliseconds(80))
        #expect(surface.screen.lines[0].text.hasPrefix("first"),
                "after detaching: last known screen, no update (TRM-03)")
        #expect(!surface.screen.lines[0].text.contains("second"))
    }

    @Test("send() types into the PTY without requiring an attached view (SES-05, quick message)")
    func sendEcritDansLePty() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        runtime.surface().send("continue\r")
        let written = await pollUntil { String(decoding: pty.writtenBytes, as: UTF8.self) == "continue\r" }
        #expect(written, "the keystroke reaches the PTY via the session queue")
    }

    @Test("attached() follows structured cancellation: cancelling the task detaches")
    func attachedSuitLAnnulationStructuree() async throws {
        let runtime = try makeRuntime()
        let surface = runtime.surface()

        let lifecycle = Task { await surface.attached() }
        let attached = await pollUntil { surface.isAttached }
        #expect(attached, "entering attached() attaches")

        lifecycle.cancel()
        let detached = await pollUntil { !surface.isAttached }
        #expect(detached, "cancelling the task (SwiftUI's .task) detaches — impossible to forget")
    }

    /// Bounded active wait (2 s) — the queue → MainActor path is asynchronous by nature.
    private func pollUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
