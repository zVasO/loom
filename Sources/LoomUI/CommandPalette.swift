import Foundation

/// Le cœur de la palette ⌘K (UIX-02) : fuzzy matching pur.
/// Sous-séquence obligatoire ; le score favorise les débuts de mots et les
/// caractères consécutifs. Accents et casse ignorés.
public enum CommandPalette {

    public static func rank(query: String, in candidates: [String]) -> [String] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return candidates }
        return candidates
            .compactMap { candidate in score(normalizedQuery, in: candidate).map { (candidate, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// `nil` si `query` n'est pas une sous-séquence de `candidate`.
    static func score(_ query: [Character], in candidate: String) -> Int? {
        let normalized = normalize(candidate)
        var score = 0
        var queryIndex = 0
        var previousMatched = -2
        for (index, character) in normalized.enumerated() {
            guard queryIndex < query.count, character == query[queryIndex] else { continue }
            score += 1
            if index == 0 || normalized[index - 1] == " " { score += 3 }   // début de mot
            if index == previousMatched + 1 { score += 2 }                  // consécutif
            previousMatched = index
            queryIndex += 1
        }
        return queryIndex == query.count ? score : nil
    }

    private static func normalize(_ text: String) -> [Character] {
        Array(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased())
    }
}
