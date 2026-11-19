import Testing
import LoomUI

// UIX-02: the palette's fuzzy matching — pure, deterministic, no UI.
// Candidates stay in French on purpose: they exercise accent folding.

@Suite("CommandPalette — fuzzy matching")
struct CommandPaletteTests {

    let candidates = [
        "Corriger le bug de cache",
        "Déployer en préproduction",
        "Ranger les dépendances",
        "Ouvrir le navigateur",
    ]

    @Test("a subsequence matches, its absence excludes")
    func sousSequence() {
        let results = CommandPalette.rank(query: "clbc", in: candidates)
        #expect(results == ["Corriger le bug de cache"], "c-l-b-c threads through \"Corriger le bug de cache\"")
        #expect(CommandPalette.rank(query: "xyz", in: candidates).isEmpty)
    }

    @Test("accents and case ignored")
    func accentsEtCasse() {
        let results = CommandPalette.rank(query: "deploy", in: candidates)
        #expect(results.first == "Déployer en préproduction")
    }

    @Test("word prefix wins over a sparse subsequence")
    func prefixeDeMotPrioritaire() {
        let results = CommandPalette.rank(query: "dep", in: candidates)
        #expect(results.count == 2)
        #expect(results.first == "Déployer en préproduction",
                "start of string > \"dépendances\" mid-sentence")
    }

    @Test("empty query: everything, in original order")
    func requeteVide() {
        #expect(CommandPalette.rank(query: "", in: candidates) == candidates)
    }

    // ⌘⇧N's project picker: a name and its path.

    let names = ["loom", "api-gateway", "Site vitrine", "lab"]
    let paths = ["/Users/me/dev/loom", "/Users/me/work/api-gateway",
                 "/Users/me/clients/acme/site", "/Users/me/dev/loom-lab"]

    @Test("picker: the name matches fuzzily, best first")
    func pickerName() {
        #expect(CommandPalette.rankIndices(query: "sv", names: names, details: paths) == [2])
        #expect(CommandPalette.rankIndices(query: "la", names: names, details: paths).first == 3,
                "\"lab\" starts with it")
    }

    @Test("picker: the path matches as a substring only, after the names")
    func pickerPath() {
        #expect(CommandPalette.rankIndices(query: "acme", names: names, details: paths) == [2])
        #expect(CommandPalette.rankIndices(query: "loom", names: names, details: paths) == [0, 3],
                "the name first, then the path that holds it")
        #expect(CommandPalette.rankIndices(query: "umd", names: names, details: paths).isEmpty,
                "no fuzzy threading through a path")
    }

    @Test("picker: an empty query keeps every item, in order")
    func pickerEmpty() {
        #expect(CommandPalette.rankIndices(query: "  ", names: names, details: paths) == [0, 1, 2, 3])
    }

    // ⌘K's own list: the titles folded once, ranked by index on every keystroke.

    @Test("keys: a title folded once reads as the match reads it")
    func keysFolded() {
        #expect(CommandPalette.key(for: "Déployer en PRÉPRODUCTION") == Array("deployer en preproduction"))
        #expect(CommandPalette.key(for: "").isEmpty)
    }

    @Test("keys: the ranking of the titles, as indices")
    func keysRankLikeTitles() {
        let keys = candidates.map { CommandPalette.key(for: $0) }
        #expect(CommandPalette.rankIndices(query: "clbc", keys: keys) == [0])
        #expect(CommandPalette.rankIndices(query: "deploy", keys: keys).first == 1, "accents and case ignored")
        #expect(CommandPalette.rankIndices(query: "xyz", keys: keys).isEmpty)
        #expect(CommandPalette.rankIndices(query: "ou", keys: keys) == [3, 0, 1],
                "\"Ouvrir\" starts with it; the sparse matches follow, in the list's order")
        #expect(CommandPalette.rankIndices(query: "r", keys: keys) == [2, 0, 1, 3])
    }

    @Test("keys: a word start wins, ties keep the list's order")
    func keysOrder() {
        let keys = ["Close session", "Go to Sessions", "Sessions: compact list", "Go to Sessions"]
            .map { CommandPalette.key(for: $0) }
        #expect(CommandPalette.rankIndices(query: "sess", keys: keys) == [1, 2, 3, 0],
                "a word start first; the two \"Go to Sessions\" and the title that opens on it tie")
    }

    @Test("keys: an empty query keeps every index, in order")
    func keysEmpty() {
        let keys = candidates.map { CommandPalette.key(for: $0) }
        #expect(CommandPalette.rankIndices(query: " ", keys: keys) == [0, 1, 2, 3])
        #expect(CommandPalette.rankIndices(query: "a", keys: []).isEmpty)
    }
}
