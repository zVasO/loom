import Foundation

/// The input window of each model family, as the API documents it: what the
/// context percentage is measured against.
///
/// Source: https://platform.claude.com/docs/en/about-claude/models, read on `asOf`.
public enum ContextWindow {

    public static let asOf = "2026-09-24"

    public static let standard = 200_000
    public static let extended = 1_000_000

    /// Families served with a 1M window. Everything else — Haiku 4.5, the
    /// 4.5 generation and older, unknown IDs — gets the 200k standard. Only
    /// a fallback: a live session's window comes from claude itself, through
    /// its status line (`ClaudeStatusLine`), whatever the model.
    private static let extendedFamilies: Set<String> = [
        "opus-5-5", "opus-5", "opus-4-8", "opus-4-7", "opus-4-6",
        "sonnet-5", "sonnet-4-6",
    ]

    /// `claude-opus-4-6[1m]` → 1M (claude's opt-in suffix, honoured whatever
    /// the family); otherwise by family; unknown → 200k, never a guess above.
    public static func tokens(for modelID: String) -> Int {
        var id = modelID.trimmingCharacters(in: .whitespaces)
        if id.lowercased().hasSuffix("[1m]") {
            return extended
        }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let family = ModelPricing.family(for: id)
        if family.hasPrefix("fable") || family.hasPrefix("mythos") { return extended }
        return extendedFamilies.contains(family) ? extended : standard
    }

    /// How full the window is, in the four bands the UI colours.
    public enum Level: Equatable, Sendable {
        case normal      // < 50 %
        case elevated    // 50–75 %
        case high        // 75–90 %
        case critical    // ≥ 90 %
    }

    public static func level(fraction: Double) -> Level {
        switch fraction {
        case ..<0.5: .normal
        case ..<0.75: .elevated
        case ..<0.9: .high
        default: .critical
        }
    }
}
