import Testing
import LoomUI

// UIX-02 : le fuzzy matching de la palette — pur, déterministe, sans UI.

@Suite("CommandPalette — fuzzy matching")
struct CommandPaletteTests {

    let candidates = [
        "Corriger le bug de cache",
        "Déployer en préproduction",
        "Ranger les dépendances",
        "Ouvrir le navigateur",
    ]

    @Test("une sous-séquence matche, l'absence exclut")
    func sousSequence() {
        let results = CommandPalette.rank(query: "clbc", in: candidates)
        #expect(results == ["Corriger le bug de cache"], "c-l-b-c traverse « Corriger le bug de cache »")
        #expect(CommandPalette.rank(query: "xyz", in: candidates).isEmpty)
    }

    @Test("accents et casse ignorés")
    func accentsEtCasse() {
        let results = CommandPalette.rank(query: "deploy", in: candidates)
        #expect(results.first == "Déployer en préproduction")
    }

    @Test("le préfixe de mot l'emporte sur la sous-séquence éparse")
    func prefixeDeMotPrioritaire() {
        let results = CommandPalette.rank(query: "dep", in: candidates)
        #expect(results.count == 2)
        #expect(results.first == "Déployer en préproduction",
                "début de chaîne > « dépendances » en milieu de phrase")
    }

    @Test("requête vide : tout, dans l'ordre d'origine")
    func requeteVide() {
        #expect(CommandPalette.rank(query: "", in: candidates) == candidates)
    }
}
