import Foundation

/// Public list prices, USD per million tokens. Stored explicitly (not derived
/// from multipliers): Fable 5.1 reads its cache at 0.025× where every other
/// model uses 0.1×.
public struct ModelRates: Equatable, Sendable {
    public let input: Decimal
    public let cacheWrite5m: Decimal
    public let cacheWrite1h: Decimal
    public let cacheRead: Decimal
    public let output: Decimal

    public init(input: Decimal, cacheWrite5m: Decimal, cacheWrite1h: Decimal,
                cacheRead: Decimal, output: Decimal) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// Source: https://platform.claude.com/docs/en/about-claude/pricing, read on `asOf`.
public enum ModelPricing {

    public static let asOf = "2026-09-02"

    private static func rates(_ input: String, _ w5: String, _ w1h: String,
                              _ read: String, _ output: String) -> ModelRates {
        ModelRates(input: Decimal(string: input)!, cacheWrite5m: Decimal(string: w5)!,
                   cacheWrite1h: Decimal(string: w1h)!, cacheRead: Decimal(string: read)!,
                   output: Decimal(string: output)!)
    }

    private static let table: [String: ModelRates] = {
        var t: [String: ModelRates] = [:]
        let fable51 = rates("10", "12.50", "20", "0.25", "50")
        let fable5 = rates("10", "12.50", "20", "1", "50")
        let opus = rates("5", "6.25", "10", "0.50", "25")
        let opusLegacy = rates("15", "18.75", "30", "1.50", "75")
        let sonnet5 = rates("2", "2.50", "4", "0.20", "10")
        let sonnet = rates("3", "3.75", "6", "0.30", "15")
        let haiku45 = rates("1", "1.25", "2", "0.10", "5")
        let haiku35 = rates("0.80", "1", "1.60", "0.08", "4")
        for f in ["fable-5-1", "mythos-5-1"] { t[f] = fable51 }
        for f in ["fable-5", "mythos-5"] { t[f] = fable5 }
        for f in ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5"] { t[f] = opus }
        for f in ["opus-4-1", "opus-4"] { t[f] = opusLegacy }
        t["sonnet-5"] = sonnet5
        for f in ["sonnet-4-6", "sonnet-4-5", "sonnet-4"] { t[f] = sonnet }
        t["haiku-4-5"] = haiku45
        t["haiku-3-5"] = haiku35
        return t
    }()

    /// `claude-opus-4-1-20250805` → `opus-4-1`; `claude-3-5-haiku-20241022` → `haiku-3-5`.
    /// Unknown IDs come back normalised the same way (the UI lists them as unpriced).
    public static func family(for modelID: String) -> String {
        var id = modelID.lowercased()
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        // Pre-4 ordering put the version first ("3-5-haiku"): rotate the name to the front.
        if let nameIndex = parts.firstIndex(where: { !$0.allSatisfy(\.isNumber) }), nameIndex > 0 {
            let name = parts.remove(at: nameIndex)
            parts.insert(name, at: 0)
        }
        return parts.joined(separator: "-")
    }

    public static func rates(for modelID: String) -> ModelRates? {
        table[family(for: modelID)]
    }

    /// `nil` when the model is not in the table — never a silent zero.
    public static func cost(input: Int, cacheWrite5m: Int, cacheWrite1h: Int,
                            cacheRead: Int, output: Int, modelID: String) -> Decimal? {
        guard let r = rates(for: modelID) else { return nil }
        let total = Decimal(input) * r.input
            + Decimal(cacheWrite5m) * r.cacheWrite5m
            + Decimal(cacheWrite1h) * r.cacheWrite1h
            + Decimal(cacheRead) * r.cacheRead
            + Decimal(output) * r.output
        return total / 1_000_000
    }
}
