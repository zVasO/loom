import Testing
import BunshinUI
import Foundation

// THM-01/04/08 : le format de thème (JSON versionné, deux espaces optionnels) et la
// résolution en cascade app → override projet, avec fusion vers le parent. Pur.

@Suite("ThemeResolver — cascade et fusion")
struct ThemeResolverTests {

    @Test("un thème JSON partiel se décode : schemaVersion, espaces optionnels, hex")
    func decodageJSON() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "océan",
          "appearance": "dark",
          "ui": { "accent": "#3366FF" }
        }
        """
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        #expect(theme.name == "océan")
        #expect(theme.appearance == .dark)
        #expect(theme.ui?.accent == ThemeColor("#3366FF"))
        #expect(theme.terminal == nil, "un thème peut ne définir qu'un seul espace (THM-04)")
    }

    @Test("fusion : l'espace manquant vient du parent, jamais d'écran troué (THM-04)")
    func fusionVersLeParent() {
        var partial = Theme.builtinDark
        partial.name = "sans-terminal"
        partial.terminal = nil
        let resolved = ThemeResolver.resolve(app: partial, projectOverride: nil)
        #expect(resolved.terminal == Theme.builtinDark.terminal!,
                "le terminal du thème sombre par défaut comble le trou")
    }

    @Test("override projet « accent seul » : le chemin rapide (THM-03)")
    func overrideAccentSeul() {
        let resolved = ThemeResolver.resolve(app: .builtinDark,
                                             projectOverride: .accent(ThemeColor("#FF2D55")))
        #expect(resolved.ui.accent == ThemeColor("#FF2D55"))
        #expect(resolved.ui.background == Theme.builtinDark.ui!.background,
                "tout le reste vient du thème global")
    }

    @Test("override projet complet : le thème du projet prime (THM-02)")
    func overrideComplet() {
        let resolved = ThemeResolver.resolve(app: .builtinDark,
                                             projectOverride: .theme(.builtinLight))
        #expect(resolved.ui.background == Theme.builtinLight.ui!.background)
    }

    @Test("les badges gardent leur sémantique : failed ne peut pas devenir la couleur du succès (THM-08)")
    func semantiqueInvariante() {
        for theme in Theme.builtins {
            let resolved = ThemeResolver.resolve(app: theme, projectOverride: nil)
            #expect(resolved.ui.stateColors[.failed] != resolved.ui.stateColors[.working],
                    "\(theme.name) : failed et working doivent rester discernables")
            #expect(resolved.ui.stateColors[.needsInput] != resolved.ui.stateColors[.completed])
        }
    }

    @Test("quatre thèmes intégrés au lancement, apparence déclarée (THM-01)")
    func quatreThemesIntegres() {
        #expect(Theme.builtins.count >= 4)
        #expect(Set(Theme.builtins.map(\.name)).count == Theme.builtins.count, "noms uniques")
        #expect(Theme.builtins.contains { $0.appearance == .light }, "au moins un thème clair")
    }
}
