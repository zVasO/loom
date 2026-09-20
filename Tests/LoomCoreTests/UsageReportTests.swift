import Testing
import LoomCore
import Foundation

// Seam: the windowed, priced aggregation. All in UTC so it stays deterministic.

@Suite("UsageReport — civil windows and per-model breakdown")
struct UsageReportTests {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // 2026-09-02 12:00 UTC
    private let today = Date(timeIntervalSince1970: 1_788_350_400)

    private func totals(_ day: String, _ model: String, output: Int) -> DailyModelTotals {
        DailyModelTotals(day: day, model: model, input: 0, cacheWrite5m: 0, cacheWrite1h: 0,
                         cacheRead: 0, output: output)
    }

    @Test("today, 7 days and 30 days are inclusive civil windows")
    func fenetres() {
        // opus-5: 1M output = $25
        let report = UsageReport(totals: [
            totals("2026-09-02", "claude-opus-5", output: 1_000_000),   // today
            totals("2026-08-27", "claude-opus-5", output: 1_000_000),   // 7th day, included
            totals("2026-08-26", "claude-opus-5", output: 1_000_000),   // outside 7 days
            totals("2026-08-04", "claude-opus-5", output: 1_000_000),   // 30th day, included
            totals("2026-08-03", "claude-opus-5", output: 1_000_000),   // outside 30 days
        ], today: today, calendar: utc)
        #expect(report.today == Decimal(25))
        #expect(report.last7Days == Decimal(50))
        #expect(report.last30Days == Decimal(100))
        #expect(report.total(lastDays: 90) == Decimal(125))
    }

    @Test("byModel groups by family, sorted by descending cost, unpriced last")
    func parModele() {
        let report = UsageReport(totals: [
            totals("2026-09-02", "claude-opus-5", output: 1_000_000),          // $25
            totals("2026-09-01", "claude-opus-4-8", output: 1_000_000),        // $25, distinct family
            totals("2026-09-02", "claude-fable-5-1", output: 1_000_000),       // $50
            totals("2026-09-02", "claude-unicorn-9", output: 5),               // unpriced
        ], today: today, calendar: utc)
        let lines = report.byModel(lastDays: 30)
        #expect(lines.map(\.family) == ["fable-5-1", "opus-4-8", "opus-5", "unicorn-9"],
                "à coût égal, ordre alphabétique")
        #expect(lines[0].cost == Decimal(50))
        #expect(lines[3].cost == nil)
        #expect(lines[3].output == 5)
        #expect(report.unpricedModels == ["unicorn-9"])
    }

    @Test("points: one entry per (day, family) in the window, cost and tokens")
    func points() {
        let report = UsageReport(totals: [
            DailyModelTotals(day: "2026-09-02", model: "claude-opus-5", input: 10, cacheWrite5m: 20,
                             cacheWrite1h: 30, cacheRead: 40, output: 1_000_000),
            totals("2026-08-26", "claude-opus-5", output: 1),
        ], today: today, calendar: utc)
        let points = report.points(lastDays: 7)
        #expect(points.count == 1)
        #expect(points.first?.day == "2026-09-02")
        #expect(points.first?.family == "opus-5")
        #expect(points.first?.tokens == 1_000_100)
        // 10×5 + 20×6.25 + 30×10 + 40×0.5 + 1000000×25 = 25000495 / 1e6
        #expect(points.first?.cost == Decimal(string: "25.000495"))
    }
}
