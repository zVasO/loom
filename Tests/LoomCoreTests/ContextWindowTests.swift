import Testing
import LoomCore
import Foundation

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

@Suite("ContextWindow — the window a summary measures against")
struct ReportedWindowTests {

    private func turn(model: String, read: Int) -> UsageTurn {
        UsageTurn(messageID: "m", requestID: "r", timestamp: Date(timeIntervalSince1970: 0),
                  model: model, sessionID: "s", cwd: nil, input: 1, cacheWrite5m: 0,
                  cacheWrite1h: 0, cacheRead: read, output: 1)
    }

    @Test("Opus 5.5 is served with 1M")
    func opus55() {
        #expect(ContextWindow.tokens(for: "claude-opus-5-5") == 1_000_000)
    }

    @Test("a context past 200k proves a larger window, whatever the table says")
    func planchers() {
        let unknown = SessionUsageSummary(turns: [turn(model: "claude-unicorn-9", read: 350_000)])
        #expect(unknown?.windowTokens == 1_000_000, "350k in use: the window is not 200k")
        let small = SessionUsageSummary(turns: [turn(model: "claude-unicorn-9", read: 50_000)])
        #expect(small?.windowTokens == 200_000, "no proof: the standard window")
    }

    @Test("the window claude reported replaces the table's")
    func fenetreRapportee() {
        let summary = SessionUsageSummary(turns: [turn(model: "claude-haiku-4-5", read: 100_000)])
        #expect(summary?.reportingWindow(nil).windowTokens == 200_000, "nothing reported: unchanged")
        let reported = summary?.reportingWindow(1_000_000)
        #expect(reported?.windowTokens == 1_000_000)
        #expect(reported?.fraction == 100_001.0 / 1_000_000.0, "the fraction follows the reported window")
    }
}
