import Testing
import LoomCore
import Foundation

// Seam: the pure summary of one session's turns — the last window is the
// context, the rest accumulates, the cost is honest or absent.

@Suite("SessionUsageSummary — one session's window")
struct SessionUsageSummaryTests {

    private func turn(_ id: String, model: String = "claude-opus-5", at: TimeInterval = 0,
                      input: Int = 0, w5m: Int = 0, w1h: Int = 0, read: Int = 0, output: Int = 0) -> UsageTurn {
        UsageTurn(messageID: id, requestID: "r-\(id)", timestamp: Date(timeIntervalSince1970: at),
                  model: model, sessionID: "s", cwd: nil, input: input, cacheWrite5m: w5m,
                  cacheWrite1h: w1h, cacheRead: read, output: output)
    }

    @Test("no turn — no summary, never zeros passed off as truth")
    func vide() {
        #expect(SessionUsageSummary(turns: []) == nil)
    }

    @Test("the LAST turn gives the context and its breakdown; the rest accumulates")
    func dernierTourEtCumuls() {
        let summary = SessionUsageSummary(turns: [
            turn("m1", at: 100, input: 2, w5m: 100, read: 50, output: 10),
            turn("m2", at: 160, input: 5, w5m: 30, w1h: 10, read: 160, output: 25),
        ])
        #expect(summary?.contextTokens == 205, "5 + 30 + 10 + 160")
        #expect(summary?.lastTurnInput == 5)
        #expect(summary?.lastTurnCacheWrite == 40)
        #expect(summary?.lastTurnCacheRead == 160)
        #expect(summary?.lastTurnOutput == 25)
        #expect(summary?.inputTokens == 7)
        #expect(summary?.cacheWriteTokens == 140)
        #expect(summary?.cacheReadTokens == 210)
        #expect(summary?.outputTokens == 35)
        #expect(summary?.turnCount == 2)
        #expect(summary?.firstTurnAt == Date(timeIntervalSince1970: 100))
        #expect(summary?.lastTurnAt == Date(timeIntervalSince1970: 160))
        #expect(summary?.duration == 60)
    }

    @Test("window, fraction and remaining follow the last turn's model")
    func fenetre() {
        let summary = SessionUsageSummary(turns: [turn("m1", model: "claude-haiku-4-5", read: 150_000)])
        #expect(summary?.windowTokens == 200_000)
        #expect(summary?.fraction == 0.75)
        #expect(summary?.remainingTokens == 50_000)
        #expect(summary?.level == .high)
        #expect(summary?.cacheHitRate == 1)
    }

    @Test("past the window the fraction caps at 1 and nothing remains")
    func plafond() {
        // The window claude reported (a transcript past 200k alone would raise
        // the table's window to 1M: the context cannot exceed what is served).
        let summary = SessionUsageSummary(turns: [turn("m1", model: "claude-haiku-4-5", input: 250_000)])?
            .reportingWindow(200_000)
        #expect(summary?.fraction == 1)
        #expect(summary?.remainingTokens == 0)
        #expect(summary?.level == .critical)
    }

    @Test("a session that switched model lists each one once, in order; the last one is the model")
    func modeles() {
        let summary = SessionUsageSummary(turns: [
            turn("m1", model: "claude-sonnet-5"), turn("m2", model: "claude-opus-5"),
            turn("m3", model: "claude-sonnet-5"),
        ])
        #expect(summary?.models == ["claude-sonnet-5", "claude-opus-5"])
        #expect(summary?.model == "claude-sonnet-5")
    }

    @Test("the cost sums the priced turns; one unpriced turn and it is nil")
    func cout() {
        // opus-5: 1000 in × 5 + 300 out × 25 = 12500 / 1e6 = 0.0125, twice.
        let priced = SessionUsageSummary(turns: [
            turn("m1", input: 1000, output: 300), turn("m2", input: 1000, output: 300),
        ])
        #expect(priced?.cost == Decimal(string: "0.025"))
        let mixed = SessionUsageSummary(turns: [
            turn("m1", input: 1000, output: 300), turn("m2", model: "claude-unicorn-9", input: 1),
        ])
        #expect(mixed?.cost == nil)
    }

    @Test("without any input the cache hit rate is unknown, not zero")
    func tauxCacheInconnu() {
        #expect(SessionUsageSummary(turns: [turn("m1", output: 3)])?.cacheHitRate == nil)
    }
}
