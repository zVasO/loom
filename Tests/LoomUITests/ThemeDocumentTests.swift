import Testing
import Foundation
@testable import LoomUI

// A theme's document style (ADR-0017) travels with the family on disk, and
// the HomeServe theme shipped in docs/ stays a theme Loom can import.
@Suite("Theme document style")
struct ThemeDocumentTests {

    @Test("a family's document style survives its file; an old file has none")
    func roundTrip() throws {
        let style = ThemeDocumentStyle(fontSans: "Nunito", radius: "16px", logoSVG: "<svg></svg>")
        let family = ThemeFamily(name: "T", light: ThemeFamily.loom.light, dark: ThemeFamily.loom.dark, document: style)
        let decoded = try JSONDecoder().decode(ThemeFamily.self, from: JSONEncoder().encode(family))
        #expect(decoded.document == style)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(family)) as? [String: Any])
        object.removeValue(forKey: "document")
        let old = try JSONDecoder().decode(ThemeFamily.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.document == nil)
        #expect(ThemeDocumentStyle().isEmpty)
        #expect(!style.isEmpty)
    }

    @Test("docs/themes/homeserve.json is a Loom theme with the brand's roles")
    func homeServe() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/themes/homeserve.json")
        let family = try JSONDecoder().decode(ThemeFamily.self, from: Data(contentsOf: url))
        #expect(family.name == "HomeServe")
        #expect(family.light.groupHeader == "#E22C22", "the coral accent")
        #expect(family.light.accent == "#0D6E74", "teal: links, buttons, focus")
        #expect(family.light.contentBackground == "#FFF3E5", "the cream band")
        #expect(family.light.danger == "#A61A16")
        #expect(family.light.stateNeedsInput == "#C64C00")
        #expect(family.light.stateIdle == "#007153")
        #expect(family.light.isLight && !family.dark.isLight)
        #expect(family.document?.fontSans?.contains("Nunito") == true)
        #expect(ThemeDocumentStyle.isAllowedFontsURL(family.document?.fontsURL ?? ""))
    }
}
