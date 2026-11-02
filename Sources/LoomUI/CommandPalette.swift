import Foundation

/// The heart of the ⌘K palette (UIX-02): pure fuzzy matching.
/// Subsequence required; the score favors word starts and
/// consecutive characters. Diacritics and case ignored.
public enum CommandPalette {

    public static func rank(query: String, in candidates: [String]) -> [String] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return candidates }
        return candidates
            .compactMap { candidate in score(normalizedQuery, in: candidate).map { (candidate, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The indices of the items `query` finds, best first — for a picker
    /// whose items have a name and a detail (a project and its path). The
    /// name matches fuzzily, as in `rank`; the detail only as a plain
    /// substring, since nearly any query threads through a long path, and
    /// below every name match. Ties keep the items' order; an empty query
    /// keeps them all.
    public static func rankIndices(query: String, names: [String], details: [String] = []) -> [Int] {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespaces))
        guard !normalizedQuery.isEmpty else { return Array(names.indices) }
        let needle = String(normalizedQuery)
        return names.indices
            .compactMap { index -> (index: Int, score: Int)? in
                if let score = score(normalizedQuery, in: names[index]) {
                    return (index, score + 1_000)
                }
                if index < details.count, String(normalize(details[index])).contains(needle) {
                    return (index, 0)
                }
                return nil
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.index)
    }

    /// `nil` if `query` is not a subsequence of `candidate`.
    static func score(_ query: [Character], in candidate: String) -> Int? {
        let normalized = normalize(candidate)
        var score = 0
        var queryIndex = 0
        var previousMatched = -2
        for (index, character) in normalized.enumerated() {
            guard queryIndex < query.count, character == query[queryIndex] else { continue }
            score += 1
            if index == 0 || normalized[index - 1] == " " { score += 3 }   // word start
            if index == previousMatched + 1 { score += 2 }                  // consecutive
            previousMatched = index
            queryIndex += 1
        }
        return queryIndex == query.count ? score : nil
    }

    private static func normalize(_ text: String) -> [Character] {
        Array(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased())
    }
}
