import Foundation

/// Windowed, priced view over daily totals. Pure: built once from the index's
/// rows, then queried by the sheet for each window the user picks.
public struct UsageReport: Equatable, Sendable {

    public struct DayPoint: Equatable, Hashable, Sendable, Identifiable {
        public let day: String
        public let family: String
        public let cost: Decimal
        public let tokens: Int
        public var id: String { day + "|" + family }
    }

    public struct ModelLine: Equatable, Sendable {
        public let family: String
        public let cost: Decimal?      // nil = not in the price table
        public let input: Int
        public let cacheWrite5m: Int
        public let cacheWrite1h: Int
        public let cacheRead: Int
        public let output: Int
    }

    private struct Row: Equatable, Sendable {
        let day: String
        let family: String
        let cost: Decimal?
        let totals: DailyModelTotals
    }

    private let rows: [Row]
    private let reference: Date
    private let calendar: Calendar

    public init(totals: [DailyModelTotals], today: Date = Date(), calendar: Calendar = .current) {
        self.reference = today
        self.calendar = calendar
        rows = totals.map { t in
            Row(day: t.day, family: ModelPricing.family(for: t.model),
                cost: ModelPricing.cost(input: t.input, cacheWrite5m: t.cacheWrite5m,
                                        cacheWrite1h: t.cacheWrite1h, cacheRead: t.cacheRead,
                                        output: t.output, modelID: t.model),
                totals: t)
        }
    }

    public var today: Decimal { total(lastDays: 1) }
    public var last7Days: Decimal { total(lastDays: 7) }
    public var last30Days: Decimal { total(lastDays: 30) }

    public var unpricedModels: [String] {
        Array(Set(rows.filter { $0.cost == nil }.map(\.family))).sorted()
    }

    private func window(_ days: Int) -> Set<String> {
        Set(UsageDay.keys(lastDays: days, endingAt: reference, calendar: calendar))
    }

    public func total(lastDays days: Int) -> Decimal {
        let keys = window(days)
        return rows.filter { keys.contains($0.day) }.reduce(Decimal(0)) { $0 + ($1.cost ?? 0) }
    }

    /// One point per (day, family), oldest day first. Unpriced models count 0 in cost.
    public func points(lastDays days: Int) -> [DayPoint] {
        let keys = window(days)
        var merged: [String: (cost: Decimal, tokens: Int)] = [:]
        for row in rows where keys.contains(row.day) {
            let key = row.day + "|" + row.family
            var entry = merged[key] ?? (0, 0)
            entry.cost += row.cost ?? 0
            entry.tokens += row.totals.totalTokens
            merged[key] = entry
        }
        return merged.keys.sorted().map { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let entry = merged[key]!
            return DayPoint(day: parts[0], family: parts[1], cost: entry.cost, tokens: entry.tokens)
        }
    }

    /// Priced families by cost descending (ties alphabetical), then unpriced ones alphabetically.
    /// The price table is per family, so a family is either priced or not as a whole.
    public func byModel(lastDays days: Int) -> [ModelLine] {
        let keys = window(days)
        var byFamily: [String: ModelLine] = [:]
        for row in rows where keys.contains(row.day) {
            let t = row.totals
            let previous = byFamily[row.family]
            let cost: Decimal? = row.cost.map { ($0 + (previous?.cost ?? 0)) } ?? previous?.cost
            byFamily[row.family] = ModelLine(
                family: row.family, cost: cost,
                input: (previous?.input ?? 0) + t.input,
                cacheWrite5m: (previous?.cacheWrite5m ?? 0) + t.cacheWrite5m,
                cacheWrite1h: (previous?.cacheWrite1h ?? 0) + t.cacheWrite1h,
                cacheRead: (previous?.cacheRead ?? 0) + t.cacheRead,
                output: (previous?.output ?? 0) + t.output)
        }
        let priced = byFamily.values.filter { $0.cost != nil }.sorted {
            let (a, b) = ($0.cost ?? 0, $1.cost ?? 0)
            return a == b ? $0.family < $1.family : a > b
        }
        let unpriced = byFamily.values.filter { $0.cost == nil }.sorted { $0.family < $1.family }
        return priced + unpriced
    }
}
