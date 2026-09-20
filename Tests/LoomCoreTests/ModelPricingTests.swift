import Testing
import LoomCore
import Foundation

// Seam: the public price table (platform.claude.com, 2026-09-02) and the
// resolution of model identifiers the way claude writes them.

@Suite("ModelPricing — public prices")
struct ModelPricingTests {

    @Test("dated identifiers and the legacy ordering resolve to one family")
    func familles() {
        #expect(ModelPricing.family(for: "claude-fable-5-1") == "fable-5-1")
        #expect(ModelPricing.family(for: "claude-opus-4-1-20250805") == "opus-4-1")
        #expect(ModelPricing.family(for: "claude-3-5-haiku-20241022") == "haiku-3-5")
        #expect(ModelPricing.family(for: "claude-sonnet-5") == "sonnet-5")
        #expect(ModelPricing.family(for: "Claude-Opus-5") == "opus-5", "insensible à la casse")
    }

    @Test("fable-5-1 reads cache at 0.025×, fable-5 at 0.1× — the table is not derived")
    func lectureCacheFable() {
        #expect(ModelPricing.rates(for: "claude-fable-5-1")?.cacheRead == Decimal(string: "0.25"))
        #expect(ModelPricing.rates(for: "claude-fable-5")?.cacheRead == Decimal(1))
        #expect(ModelPricing.rates(for: "claude-fable-5-1")?.output == Decimal(50))
    }

    @Test("cost of an opus-5 turn, computed by hand")
    func coutTour() {
        // 1000 in × 5 + 2000 w5m × 6.25 + 500 w1h × 10 + 100000 read × 0.5 + 300 out × 25
        // = 5000 + 12500 + 5000 + 50000 + 7500 = 80000 / 1e6 = 0.08
        let cost = ModelPricing.cost(input: 1000, cacheWrite5m: 2000, cacheWrite1h: 500,
                                     cacheRead: 100_000, output: 300, modelID: "claude-opus-5")
        #expect(cost == Decimal(string: "0.08"))
    }

    @Test("an unknown model is not worth zero: nil, never an invented figure")
    func modeleInconnu() {
        #expect(ModelPricing.rates(for: "claude-unicorn-9") == nil)
        #expect(ModelPricing.cost(input: 1, cacheWrite5m: 0, cacheWrite1h: 0,
                                  cacheRead: 0, output: 0, modelID: "claude-unicorn-9") == nil)
        #expect(ModelPricing.family(for: "claude-unicorn-9") == "unicorn-9")
    }

    @Test("retired Sonnet 3.x keep the $3/$15 tier — history is not “unpriced”")
    func sonnetRetires() {
        #expect(ModelPricing.rates(for: "claude-3-5-sonnet-20241022")?.input == Decimal(3))
        #expect(ModelPricing.rates(for: "claude-3-7-sonnet-20250219")?.output == Decimal(15))
        #expect(ModelPricing.family(for: "opus-5") == "opus-5", "un nom de famille nu passe tel quel")
    }

    @Test("the table is dated")
    func datee() {
        #expect(ModelPricing.asOf == "2026-09-02")
    }
}
