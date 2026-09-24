import Foundation

/// What one session's billed turns say about its context window: the LAST
/// turn's input window is the context (what the next exchange starts from),
/// the other counters accumulate over every turn given.
///
/// Pure — built from turns `UsageLedger` already deduplicated. Over a tail
/// read the cumulative figures cover the tail only; the context, the model
/// and the last timestamp are exact whatever the read.
public struct SessionUsageSummary: Equatable, Sendable {

    // Last turn
    public let model: String
    public let contextTokens: Int
    public let lastTurnInput: Int
    public let lastTurnCacheRead: Int
    public let lastTurnCacheWrite: Int
    public let lastTurnOutput: Int
    public let lastTurnAt: Date

    // Window
    /// The table's figure for the model, raised to 1M when the context
    /// already exceeds 200k (the window is at least what was used), and
    /// replaced by claude's own figure when it reported one.
    public private(set) var windowTokens: Int

    // Cumulative over the turns given
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let turnCount: Int
    public let firstTurnAt: Date
    /// Distinct model IDs in order of first appearance — a session can switch.
    public let models: [String]
    /// Sum of the priced turns; nil as soon as one turn is unpriced — never a
    /// silent partial figure.
    public let cost: Decimal?

    public init?(turns: [UsageTurn]) {
        guard let last = turns.last, let first = turns.first else { return nil }
        model = last.model
        contextTokens = last.contextTokens
        lastTurnInput = last.input
        lastTurnCacheRead = last.cacheRead
        lastTurnCacheWrite = last.cacheWrite5m + last.cacheWrite1h
        lastTurnOutput = last.output
        lastTurnAt = last.timestamp
        let tabled = ContextWindow.tokens(for: last.model)
        // A model the table does not know yet, on its 1M window: the tokens
        // in use are the proof, 200k would read as a full context.
        windowTokens = last.contextTokens > tabled ? max(tabled, ContextWindow.extended) : tabled

        inputTokens = turns.reduce(0) { $0 + $1.input }
        cacheReadTokens = turns.reduce(0) { $0 + $1.cacheRead }
        cacheWriteTokens = turns.reduce(0) { $0 + $1.cacheWrite5m + $1.cacheWrite1h }
        outputTokens = turns.reduce(0) { $0 + $1.output }
        turnCount = turns.count
        firstTurnAt = first.timestamp

        var seen = Set<String>()
        models = turns.map(\.model).filter { seen.insert($0).inserted }

        var total = Decimal(0)
        var priced = true
        for turn in turns {
            guard let turnCost = ModelPricing.cost(input: turn.input, cacheWrite5m: turn.cacheWrite5m,
                                                   cacheWrite1h: turn.cacheWrite1h, cacheRead: turn.cacheRead,
                                                   output: turn.output, modelID: turn.model) else {
                priced = false
                break
            }
            total += turnCost
        }
        cost = priced ? total : nil
    }

    /// The same summary measured against the window claude reported for the
    /// session (status line), when there is one — the exact figure.
    public func reportingWindow(_ tokens: Int?) -> SessionUsageSummary {
        guard let tokens, tokens > 0 else { return self }
        var copy = self
        copy.windowTokens = tokens
        return copy
    }

    /// 0…1, capped: claude compacts before the window overflows, but a record
    /// written right at the edge must not draw past the ring.
    public var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(windowTokens))
    }

    public var remainingTokens: Int { max(0, windowTokens - contextTokens) }

    public var level: ContextWindow.Level { ContextWindow.level(fraction: fraction) }

    /// Share of the last window served from cache — nil before any input.
    public var cacheHitRate: Double? {
        guard contextTokens > 0 else { return nil }
        return Double(lastTurnCacheRead) / Double(contextTokens)
    }

    public var duration: TimeInterval { lastTurnAt.timeIntervalSince(firstTurnAt) }
}
