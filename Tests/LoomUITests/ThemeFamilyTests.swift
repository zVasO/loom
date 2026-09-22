import Testing
import Foundation
import LoomCore
@testable import LoomUI

// A theme is a family: one name, a light and a dark variant. The app shows
// the one its appearance calls for; the settings a previous Loom stored
// still name a theme.
@Suite("ThemeFamily — every theme in light and dark")
struct ThemeFamilyTests {

    @Test("every built-in family has a light variant that is light and a dark one that is dark")
    func variantsMatchTheirAppearance() {
        for family in ThemeFamily.builtins {
            #expect(family.light.isLight, Comment(rawValue: family.name + " light"))
            #expect(!family.dark.isLight, Comment(rawValue: family.name + " dark"))
            #expect(family.palette(dark: false).isLight)
            #expect(!family.palette(dark: true).isLight)
            #expect(family.isBuiltIn)
        }
    }

    @Test("every token of every variant is a #RRGGBB colour")
    func tokensAreHex() {
        for family in ThemeFamily.builtins {
            for token in family.light.all + family.dark.all {
                #expect(ThemeTokens.rgb(token) != nil, Comment(rawValue: family.name + " " + token))
            }
        }
    }

    @Test("family and variant names are unique — they key the settings")
    func uniqueNames() {
        let names = ThemeFamily.builtins.map(\.name)
        #expect(Set(names).count == names.count)
        let variants = ThemeFamily.builtins.flatMap { [$0.variantLightName, $0.variantDarkName] }
        #expect(Set(variants).count == variants.count)
        #expect(ThemePalette.all.count == ThemeFamily.builtins.count * 2)
    }

    @Test("a name stored by a previous Loom — a variant's — resolves to its family")
    func migration() {
        let families = ThemeFamily.builtins
        #expect(ThemeFamily.resolve("Loom Dark", in: families)?.name == "Loom")
        #expect(ThemeFamily.resolve("Solarized Light", in: families)?.name == "Solarized")
        #expect(ThemeFamily.resolve("Catppuccin Mocha", in: families)?.name == "Catppuccin")
        #expect(ThemeFamily.resolve("Tokyo Night", in: families)?.name == "Tokyo Night")
        #expect(ThemeFamily.resolve("Dracula", in: families)?.name == "Dracula")
        #expect(ThemeFamily.resolve("Alucard", in: families)?.name == "Dracula")
        #expect(ThemeFamily.resolve("Nope", in: families) == nil)
    }

    @Test("the appearance rule: follow macOS, or force")
    func appearanceRule() {
        #expect(ThemeStore.resolveIsDark(mode: .system, systemIsDark: true))
        #expect(!ThemeStore.resolveIsDark(mode: .system, systemIsDark: false))
        #expect(!ThemeStore.resolveIsDark(mode: .light, systemIsDark: true))
        #expect(ThemeStore.resolveIsDark(mode: .dark, systemIsDark: false))
    }

    @Test("badges keep their meaning in every variant (THM-08)")
    func semanticsInvariant() {
        for family in ThemeFamily.builtins {
            for tokens in [family.light, family.dark] {
                #expect(tokens.stateWorking != tokens.danger, Comment(rawValue: family.name))
                #expect(tokens.stateNeedsInput != tokens.stateIdle, Comment(rawValue: family.name))
                #expect(tokens.primaryText != tokens.background, Comment(rawValue: family.name))
            }
        }
    }

    @Test("hex helpers: parse, format, mix, luminance")
    func hexHelpers() throws {
        let c = try #require(ThemeTokens.rgb("#3B82F6"))
        #expect(abs(c.red - 0x3B / 255.0) < 0.001 && abs(c.blue - 0xF6 / 255.0) < 0.001)
        #expect(ThemeTokens.rgb("#FFF")?.green == 1)
        #expect(ThemeTokens.rgb("nope") == nil)
        #expect(ThemeTokens.hex(red: 1, green: 0, blue: 0.5) == "#FF0080")
        #expect(ThemeTokens.hex(red: 2, green: -1, blue: 0) == "#FF0000", "clamped")
        #expect(ThemeTokens.mix("#000000", with: "#FFFFFF", amount: 0.5) == "#808080")
        #expect(ThemeTokens.luminance("#FFFFFF") > 0.99)
        #expect(ThemeTokens.luminance("#000000") == 0)
    }

    @Test("a family round-trips through JSON and the store; a corrupt file is skipped")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-themes-\(UUID().uuidString)")
        let store = ThemeFamilyStore(directory: directory)
        #expect(store.load().isEmpty, "a missing folder is no family")

        var family = ThemeFamily.tokyoNight
        family.name = "My Night"
        family.lightName = nil
        try store.save(family)
        try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let loaded = store.load()
        #expect(loaded.count == 1)
        let back = try #require(loaded.first)
        #expect(back.name == "My Night")
        #expect(back.light == family.light && back.dark == family.dark)
        #expect(back.variantLightName == "My Night Light")
        #expect(back.variantDarkName == "Tokyo Night", "the explicit dark name survives")
        #expect(!back.isBuiltIn, "anything on disk is the user's")
        #expect(store.url(for: back).lastPathComponent == "my-night.json")

        store.delete(back)
        #expect(store.load().isEmpty)
    }
}
