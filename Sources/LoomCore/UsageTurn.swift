import Foundation

/// One billed assistant turn as claude records it in its native .jsonl.
public struct UsageTurn: Equatable, Sendable {
    public let messageID: String
    public let requestID: String
    public let timestamp: Date
    public let model: String
    public let sessionID: String
    public let cwd: String?
    public let input: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    public let cacheRead: Int
    public let output: Int

    public init(messageID: String, requestID: String, timestamp: Date, model: String,
                sessionID: String, cwd: String?, input: Int, cacheWrite5m: Int,
                cacheWrite1h: Int, cacheRead: Int, output: Int) {
        self.messageID = messageID
        self.requestID = requestID
        self.timestamp = timestamp
        self.model = model
        self.sessionID = sessionID
        self.cwd = cwd
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    /// What "context" means for the next exchange: the whole input window.
    public var contextTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// Five counters summed over one local day for one model ID.
public struct DailyModelTotals: Equatable, Sendable {
    public let day: String
    public let model: String
    public let input: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    public let cacheRead: Int
    public let output: Int

    public init(day: String, model: String, input: Int, cacheWrite5m: Int,
                cacheWrite1h: Int, cacheRead: Int, output: Int) {
        self.day = day
        self.model = model
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

/// Day keys are `yyyy-MM-dd` in the given calendar — sortable as strings.
public enum UsageDay {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The `n` keys ending today, oldest first.
    public static func keys(lastDays n: Int, endingAt today: Date,
                            calendar: Calendar = .current) -> [String] {
        (0..<n).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { key(for: $0, calendar: calendar) }
        }
    }
}
