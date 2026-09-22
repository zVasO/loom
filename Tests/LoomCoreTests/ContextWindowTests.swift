import Testing
import LoomCore

// Seam: the window size the percentage is measured against, resolved from the
// model ID exactly as claude writes it.

@Suite("ContextWindow — window size by model")
struct ContextWindowTests {

    @Test("the current generation is served with 1M, haiku and the older ones with 200k")
    func parFamille() {
        #expect(ContextWindow.tokens(for: "claude-fable-5-1") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-mythos-5") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-opus-5") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-opus-4-6") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-sonnet-4-6") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-haiku-4-5") == 200_000)
        #expect(ContextWindow.tokens(for: "claude-opus-4-5") == 200_000)
        #expect(ContextWindow.tokens(for: "claude-sonnet-4-5-20250929") == 200_000, "dated ID, same family")
    }

    @Test("the [1m] suffix opts in, whatever the family")
    func suffixe1m() {
        #expect(ContextWindow.tokens(for: "claude-sonnet-4-5[1m]") == 1_000_000)
        #expect(ContextWindow.tokens(for: "claude-haiku-4-5[1M]") == 1_000_000, "insensible à la casse")
    }

    @Test("an unknown model gets the standard window, never a guess above")
    func modeleInconnu() {
        #expect(ContextWindow.tokens(for: "claude-unicorn-9") == 200_000)
        #expect(ContextWindow.tokens(for: "") == 200_000)
    }

    @Test("the four bands: 50, 75 and 90 percent are the edges")
    func niveaux() {
        #expect(ContextWindow.level(fraction: 0) == .normal)
        #expect(ContextWindow.level(fraction: 0.499) == .normal)
        #expect(ContextWindow.level(fraction: 0.5) == .elevated)
        #expect(ContextWindow.level(fraction: 0.749) == .elevated)
        #expect(ContextWindow.level(fraction: 0.75) == .high)
        #expect(ContextWindow.level(fraction: 0.9) == .critical)
        #expect(ContextWindow.level(fraction: 1.2) == .critical)
    }
}
