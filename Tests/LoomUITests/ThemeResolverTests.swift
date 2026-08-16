import Testing
import LoomUI
import Foundation

// THM-01/04/08: the theme format (versioned JSON, both spaces optional) and the
// cascade resolution app → project override, with merge toward the parent. Pure.

@Suite("ThemeResolver — cascade and merge")
struct ThemeResolverTests {

    @Test("a partial JSON theme decodes: schemaVersion, optional spaces, hex")
    func decodageJSON() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "ocean",
          "appearance": "dark",
          "ui": { "accent": "#3366FF" }
        }
        """
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        #expect(theme.name == "ocean")
        #expect(theme.appearance == .dark)
        #expect(theme.ui?.accent == ThemeColor("#3366FF"))
        #expect(theme.terminal == nil, "a theme may define only one space (THM-04)")
    }

    @Test("merge: the missing space comes from the parent, never a screen with holes (THM-04)")
    func fusionVersLeParent() {
        var partial = Theme.builtinDark
        partial.name = "no-terminal"
        partial.terminal = nil
        let resolved = ThemeResolver.resolve(app: partial, projectOverride: nil)
        #expect(resolved.terminal == Theme.builtinDark.terminal!,
                "the default dark theme's terminal fills the hole")
    }

    @Test("\"accent only\" project override: the fast path (THM-03)")
    func overrideAccentSeul() {
        let resolved = ThemeResolver.resolve(app: .builtinDark,
                                             projectOverride: .accent(ThemeColor("#FF2D55")))
        #expect(resolved.ui.accent == ThemeColor("#FF2D55"))
        #expect(resolved.ui.background == Theme.builtinDark.ui!.background,
                "everything else comes from the global theme")
    }

    @Test("full project override: the project's theme wins (THM-02)")
    func overrideComplet() {
        let resolved = ThemeResolver.resolve(app: .builtinDark,
                                             projectOverride: .theme(.builtinLight))
        #expect(resolved.ui.background == Theme.builtinLight.ui!.background)
    }

    @Test("badges keep their semantics: failed cannot become the success color (THM-08)")
    func semantiqueInvariante() {
        for theme in Theme.builtins {
            let resolved = ThemeResolver.resolve(app: theme, projectOverride: nil)
            #expect(resolved.ui.stateColors[.failed] != resolved.ui.stateColors[.working],
                    "\(theme.name): failed and working must remain distinguishable")
            #expect(resolved.ui.stateColors[.needsInput] != resolved.ui.stateColors[.completed])
        }
    }

    @Test("four built-in themes at launch, appearance declared (THM-01)")
    func quatreThemesIntegres() {
        #expect(Theme.builtins.count >= 4)
        #expect(Set(Theme.builtins.map(\.name)).count == Theme.builtins.count, "unique names")
        #expect(Theme.builtins.contains { $0.appearance == .light }, "at least one light theme")
    }
}
