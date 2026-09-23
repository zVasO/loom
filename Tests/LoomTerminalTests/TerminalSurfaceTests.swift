import Testing
import LoomCore
@testable import LoomTerminal
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

    // TRM-06 — a full-screen agent takes the mouse and scrolls its own viewport.
    // The pane must learn about it, or the wheel dies in a ScrollView that has
    // nothing left to scroll.
    @Test("mouse tracking reaches the surface, and wheel and click reach the PTY")
    func souriRelayeeALAgent() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty,
                transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in
                    SwiftTermEngine(geometry: geometry, scrollback: 100)
                })
        ).runtime
        let surface = runtime.surface()
        surface.attach()

        #expect(surface.mouseReporting == false, "nothing is tracking yet")
        pty.emit("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(await pollUntil { surface.mouseReporting },
                "the pane must know the agent took the mouse")

        surface.sendWheel(.up, atCol: 3, row: 5)
        #expect(await pollUntil {
            String(decoding: pty.writtenBytes, as: UTF8.self).contains("\u{1B}[<64;4;6M")
        }, "the notch must land on the PTY, or the agent never scrolls")

        surface.sendClick(atCol: 3, row: 5)
        #expect(await pollUntil {
            String(decoding: pty.writtenBytes, as: UTF8.self).contains("\u{1B}[<0;4;6M\u{1B}[<0;4;6m")
        }, "the click must land on the PTY, or the agent's own targets are unreachable")
    }

    // The key capture reads the modes off the surface: bracketed paste, cursor
    // keys and the kitty flags must travel the same road as the mouse.
    @Test("the negotiated input modes reach the surface")
    func modesRelayesALaSurface() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty,
                transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in
                    SwiftTermEngine(geometry: geometry, scrollback: 100)
                })
        ).runtime
        let surface = runtime.surface()
        surface.attach()

        #expect(surface.modes == .none, "legacy defaults before the program speaks")
        pty.emit("\u{1B}[?2004h\u{1B}[>1u")
        #expect(await pollUntil { surface.modes.bracketedPaste },
                "⌘V must know to bracket the paste")
        #expect(await pollUntil { surface.modes.keyboardEnhancement.contains(.disambiguate) },
                "the encoder must know the program expects CSI u reports")
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
        let watcher = surface.attach()
        pty.emit("first")
        _ = await pollUntil { surface.screen.lines[0].text.hasPrefix("first") }

        surface.detach(watcher)
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

    // P1-5: a chunk that moves no visible cell — a DSR reply, a mode toggle —
    // never becomes a frame: nothing crosses to the main actor, nothing
    // invalidates the watchers.
    @Test("a frame carrying no visible change is not delivered")
    func frameSansChangementNonLivree() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty, transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in SwiftTermEngine(geometry: geometry, scrollback: 100) })
        ).runtime
        let surface = runtime.surface()
        let watcher = surface.attach()
        pty.emit("hello")
        #expect(await pollUntil { surface.screen.lines.first?.text.hasPrefix("hello") == true })
        let delivered = surface.framesReceived

        pty.emit("\u{1B}[6n")   // DSR: answered on the PTY, nothing on screen
        try await Task.sleep(for: .milliseconds(150))
        #expect(surface.framesReceived == delivered, "no visible change, no frame")
        #expect(String(decoding: pty.writtenBytes, as: UTF8.self).contains("\u{1B}[1;6R"),
                "the reply still went out")

        pty.emit(" world")
        #expect(await pollUntil { surface.framesReceived > delivered })
        #expect(surface.screen.lines.first?.text.hasPrefix("hello world") == true)
        surface.detach(watcher)
    }

    // P1-11: a preview asks for its own cadence — a burst that streams for
    // half a second reaches it a handful of times, not sixty.
    @Test("a preview watcher receives frames at its cadence, not the pane's")
    func cadenceDApercu() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty, transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in SwiftTermEngine(geometry: geometry, scrollback: 100) })
        ).runtime
        let surface = runtime.surface()
        let watcher = surface.attach(cadence: .preview(.milliseconds(200)))
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<40 {
            pty.emit("burst \(index)\r\n")
            try await Task.sleep(for: .milliseconds(10))
        }
        let burst = clock.now - start
        try await Task.sleep(for: .milliseconds(250))
        // The attach frame, the leading edge, then one trailing edge per
        // 200 ms the burst lasted (rounded up) — however long a loaded
        // machine took to run it; a fixed count flaked under load.
        let budget = 2 + Int(burst / .milliseconds(200)) + 1
        #expect(surface.framesReceived <= budget,
                "\(burst) of burst at a 200 ms cadence: the attach frame, a leading edge and a trailing edge per interval — saw \(surface.framesReceived)")
        #expect(surface.screen.lines.contains { $0.text.hasPrefix("burst 39") }, "and the last frame is current")
        surface.detach(watcher)
    }

    // A pane and a Mission Control card share one surface; at a tab switch the
    // newcomer attaches in the same commit that cancels the other. With one
    // flag per surface the survivor ended up detached — frozen on its last
    // screen for as long as the tab stayed open.
    @Test("two watchers overlap: the second keeps frames when the first leaves")
    func deuxObservateursSeChevauchent() async throws {
        let pty = ScriptedPTYHost()
        let runtime = try makeRuntime(pty: pty)
        let surface = runtime.surface()

        let card = Task { await surface.attached(cadence: .preview(.milliseconds(250))) }
        #expect(await pollUntil { surface.isAttached })
        let pane = Task { await surface.attached() }
        try await Task.sleep(for: .milliseconds(20))
        card.cancel()
        _ = await card.value
        #expect(surface.isAttached, "the pane still watches")

        pty.emit("after the switch")
        #expect(await pollUntil { surface.screen.lines[0].text.hasPrefix("after the switch") },
                "frames keep flowing to the watcher that stayed")

        pane.cancel()
        #expect(await pollUntil { !surface.isAttached }, "the last to leave detaches")
    }
}
