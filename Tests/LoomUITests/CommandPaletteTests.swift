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
}
