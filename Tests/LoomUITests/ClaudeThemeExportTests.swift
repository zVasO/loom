import Testing
import Foundation
import LoomCore
@testable import LoomUI

// Claude Code draws its own colours over the terminal. Loom's palette, as a
// Claude custom theme (ADR-0013): a file under ~/.claude/themes, selected by
// `custom:<slug>`, reloaded live by claude when Loom rewrites it.
@Suite("ClaudeThemeExport — Loom's palette as a Claude Code theme")
struct ClaudeThemeExportTests {

    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the base preset follows the palette's lightness; the accent and text carry over")
    func baseAndCoreTokens() throws {
        for dark in [true, false] {
            let palette = ThemeFamily.dracula.palette(dark: dark)
            let theme = try decode(ClaudeThemeExport.document(name: "X", tokens: palette.tokens,
                                                              isLight: palette.isLight))
            #expect(theme["name"] as? String == "X")
            #expect(theme["base"] as? String == (dark ? "dark" : "light"))
            let overrides = try #require(theme["overrides"] as? [String: String])
            #expect(overrides["claude"] == palette.tokens.accent)
            #expect(overrides["text"] == palette.tokens.primaryText)
            #expect(overrides["error"] == palette.tokens.danger)
            #expect(overrides["userMessageBackground"] == palette.tokens.surface)
        }
    }

    @Test("diffs are the state colours washed into the pane")
    func diffs() {
        let tokens = ThemeFamily.loom.dark
        let overrides = ClaudeThemeExport.overrides(for: tokens)
        #expect(overrides["diffAdded"]
                == ThemeTokens.mix(tokens.contentBackground, with: tokens.stateWorking, amount: 0.22))
        #expect(overrides["diffRemovedWord"]
                == ThemeTokens.mix(tokens.contentBackground, with: tokens.danger, amount: 0.45))
    }

    @Test("every override of every built-in variant is a #RRGGBB colour")
    func overridesAreHex() {
        for family in ThemeFamily.builtins {
            for tokens in [family.light, family.dark] {
                for (token, value) in ClaudeThemeExport.overrides(for: tokens) {
                    #expect(value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
                            Comment(rawValue: "\(family.name) \(token) \(value)"))
                }
            }
        }
    }

    @Test("the document is deterministic: an unchanged theme is not rewritten")
    func deterministic() {
        let tokens = ThemeFamily.nord.light
        #expect(ClaudeThemeExport.document(name: "N", tokens: tokens, isLight: true)
                == ClaudeThemeExport.document(name: "N", tokens: tokens, isLight: true))
    }

    @Test("slugs: one stable live theme per project, a catalog entry per variant")
    func slugs() throws {
        let project = ProjectID(try #require(UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")))
        #expect(ClaudeThemeExport.liveSlug(for: project) == "loom-project-abcdef12")
        #expect(ClaudeThemeExport.liveSlug(for: nil) == "loom")
        #expect(ClaudeThemeExport.catalogSlug(family: .tokyoNight, dark: true) == "loom-tokyo-night-dark")
        #expect(ClaudeThemeExport.catalogSlug(family: .catppuccin, dark: false) == "loom-catppuccin-light")
        #expect(ClaudeThemeExport.settingValue(slug: "loom") == "custom:loom")
    }

    @Test("only Loom's own files are ever touched")
    func ownership() {
        #expect(ClaudeThemeExport.isOwned(filename: "loom.json"))
        #expect(ClaudeThemeExport.isOwned(filename: "loom-project-abcdef12.json"))
        #expect(ClaudeThemeExport.isOwned(filename: "loom-tokyo-night-dark.json"))
        #expect(ClaudeThemeExport.isOwned(filename: "loom-nord-light.json"))
        #expect(!ClaudeThemeExport.isOwned(filename: "my-theme.json"))
        #expect(!ClaudeThemeExport.isOwned(filename: "loom-notes.json"))
        #expect(!ClaudeThemeExport.isOwned(filename: "dracula-dark.json"))
        #expect(!ClaudeThemeExport.isOwned(filename: "loom-nord-dark.json.bak"))
        for family in ThemeFamily.builtins {
            for dark in [true, false] {
                let name = ClaudeThemeExport.catalogSlug(family: family, dark: dark) + ".json"
                #expect(ClaudeThemeExport.isOwned(filename: name), Comment(rawValue: name))
            }
        }
    }

    @Test("writing the folder: new files in, stale ones out, unchanged ones untouched, the user's kept")
    func write() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-claude-themes-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mine = directory.appendingPathComponent("my-theme.json")
        try Data("{}".utf8).write(to: mine)

        let live = [(slug: "loom", name: "Loom", palette: ThemeFamily.loom.palette(dark: true))]
        let files = ClaudeThemeExport.files(families: [.loom, .nord], live: live)
        #expect(files.count == 5, "two families × two variants, and the live theme")
        try ClaudeThemeExport.write(files, to: directory)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(names == ["my-theme.json", "loom.json", "loom-loom-dark.json", "loom-loom-light.json",
                          "loom-nord-dark.json", "loom-nord-light.json"])

        // An unchanged file is not rewritten: every write reloads every session.
        let live1 = directory.appendingPathComponent("loom.json")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: live1.path)
        try ClaudeThemeExport.write(ClaudeThemeExport.files(families: [.loom], live: live), to: directory)
        let date = try FileManager.default.attributesOfItem(atPath: live1.path)[.modificationDate] as? Date
        #expect(date == old)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(!after.contains("loom-nord-dark.json"), "a family gone is a theme gone")
        #expect(after.contains("my-theme.json"), "the user's theme stays")

        // Off: everything Loom wrote goes, nothing else.
        try ClaudeThemeExport.write([:], to: directory)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["my-theme.json"])
    }
}
