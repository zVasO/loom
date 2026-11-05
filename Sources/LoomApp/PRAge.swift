import Foundation

/// "3 d", "5 h", "12 min" — how long ago GitHub's ISO-8601 timestamp was:
/// the Updated and Pushed columns of the PRs tab's tables.
enum PRAge {
    /// One formatter for every cell: ISO8601DateFormatter is among the most
    /// expensive objects Foundation builds, and one was made per row per pass.
    private static let iso = ISO8601DateFormatter()

    static func text(_ iso: String, now: Date = Date()) -> String {
        guard let date = Self.iso.date(from: iso) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}
