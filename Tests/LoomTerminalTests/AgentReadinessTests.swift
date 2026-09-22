import Testing
import LoomCore
import LoomTerminal
import Foundation

// When an outside caller may type into the agent (the review setup command,
// a quick action): never on "the screen changed", only once claude's input is
// really up — painted, bracketed paste on, prompt on screen, output settled.

@Suite("AgentReadiness — ready for a typed line")
struct AgentReadinessTests {

    private func sample(bytes: Int = 4096, silence: Duration = .seconds(1),
                        bracketed: Bool = true,
                        tail: [String] = ["Claude Code v2.1", "> "]) -> SessionRuntime.ReadinessSample {
        SessionRuntime.ReadinessSample(bytesReceived: bytes, silence: silence,
                                       modes: TerminalModes(bracketedPaste: bracketed),
                                       visibleTail: tail.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    @Test("a booted claude — banner, prompt, bracketed paste, settled — is ready")
    func claudeDemarreEstPret() {
        #expect(AgentReadiness.isReady(sample()))
        #expect(AgentReadiness.isReady(sample(tail: ["…", "❯"])))
    }

    @Test("the prompt under a status line, or with a placeholder, still counts")
    func promptSousStatusLine() {
        // What the drawer showed: the input line, then two status-line rows.
        #expect(AgentReadiness.isReady(sample(tail: [
            "high · /effort", "❯", "[OMC#4.9.3] | 5h:37%(4h28m) | ses…",
            "▶▶ auto mode on (shift+tab to cycle)",
        ])))
        #expect(AgentReadiness.isReady(sample(tail: ["> Try \"fix lint errors\"", "? for shortcuts"])))
        #expect(!AgentReadiness.isReady(sample(tail: ["Try \"fix lint errors\"", "? for shortcuts"])),
                "no input line, no prompt")
    }

    @Test("a blank screen is not ready, whatever the engine's revision says")
    func ecranVideNEstPasPret() {
        #expect(!AgentReadiness.isReady(sample(bytes: 0, tail: [])))
        #expect(!AgentReadiness.isReady(sample(bytes: 0)))
    }

    @Test("without bracketed paste the input is not mounted yet: not ready")
    func sansBracketedPastePasPret() {
        #expect(!AgentReadiness.isReady(sample(bracketed: false)))
    }

    @Test("a spinner or a plugin loading line is not a prompt")
    func chargementNEstPasUnPrompt() {
        #expect(!AgentReadiness.isReady(sample(tail: ["Loading plugins…"])))
        #expect(!AgentReadiness.isReady(sample(tail: ["Claude Code v2.1", "Loading 4 MCP servers"])))
    }

    @Test("output still flowing: wait for it to settle")
    func sortieEnCoursAttend() {
        #expect(!AgentReadiness.isReady(sample(silence: .milliseconds(100))))
        #expect(AgentReadiness.isReady(sample(silence: AgentReadiness.settleDuration)))
    }
}
