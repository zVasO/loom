import Testing
import Foundation
@testable import LoomUI

// A tweakcn (shadcn) theme, as its Code export or its registry file, read
// into a Loom family: colours in every notation shadcn writes, the two
// blocks, and the projection onto Loom's tokens.
@Suite("TweakcnImport — a shadcn theme becomes a family")
struct TweakcnImportTests {

    private func close(_ hex: String?, to expected: String, tolerance: Int = 2) -> Bool {
        guard let hex, let a = ThemeTokens.rgb(hex), let b = ThemeTokens.rgb(expected) else { return false }
        return abs(a.red - b.red) * 255 <= Double(tolerance)
            && abs(a.green - b.green) * 255 <= Double(tolerance)
            && abs(a.blue - b.blue) * 255 <= Double(tolerance)
    }

    // MARK: Colours

    @Test("hex, rgb and hsl notations land as #RRGGBB")
    func classicNotations() {
        #expect(CSSColor.parse("#3b82f6") == "#3B82F6")
        #expect(CSSColor.parse("#fff") == "#FFFFFF")
        #expect(CSSColor.parse("rgb(59, 130, 246)") == "#3B82F6")
        #expect(CSSColor.parse("rgb(59 130 246 / 0.5)") == "#3B82F6", "alpha is dropped")
        #expect(CSSColor.parse("hsl(210 40% 98%)") == "#F8FAFC")
        #expect(CSSColor.parse("hsl(222.2, 47.4%, 11.2%)") == "#0F172A")
        #expect(CSSColor.parse("hsl(0 0% 100%)") == "#FFFFFF")
    }

    @Test("shadcn v3 writes hsl as a bare triplet")
    func bareTriplet() {
        #expect(CSSColor.parse("210 40% 98%") == "#F8FAFC")
        #expect(CSSColor.parse("222.2 47.4% 11.2%") == "#0F172A")
        #expect(CSSColor.parse("0 0% 3.9%") == "#0A0A0A")
    }

    @Test("oklch and oklab convert through OKLab to sRGB, within the gamut")
    func oklch() {
        // Tailwind v4's own values, and the hex it documents for them.
        #expect(close(CSSColor.parse("oklch(0.623 0.214 259.815)"), to: "#2B7FFF"), "blue-500")
        #expect(close(CSSColor.parse("oklch(62.3% 0.214 259.815)"), to: "#2B7FFF"), "percent lightness")
        #expect(close(CSSColor.parse("oklch(0.637 0.237 25.331)"), to: "#FB2C36"), "red-500")
        #expect(CSSColor.parse("oklch(1 0 0)") == "#FFFFFF")
        #expect(CSSColor.parse("oklch(0.145 0 0)") == "#0A0A0A", "neutral-950")
        #expect(CSSColor.parse("oklch(0.985 0 0)") == "#FAFAFA", "neutral-50")
        #expect(CSSColor.parse("oklch(0.623 0.214 259.815 / 50%)") != nil, "alpha ignored")
        #expect(close(CSSColor.parse("oklab(0.623 -0.0378 -0.2107)"), to: "#2B7FFF", tolerance: 4))
        #expect(CSSColor.parse("oklch(0.9 0.4 120)") != nil, "out of gamut is clamped, not refused")
    }

    @Test("what is not a colour is refused")
    func notColours() {
        for text in ["", "auto", "0.5rem", "var(--primary)", "hsl()", "#12"] {
            #expect(CSSColor.parse(text) == nil, Comment(rawValue: text))
        }
    }

    // MARK: CSS export

    @Test("the Code export: a :root block and a .dark block, comments ignored")
    func cssTwoBlocks() throws {
        let css = """
        /* tweakcn export */
        :root {
          --background: oklch(1 0 0);
          --foreground: oklch(0.145 0 0);
          --primary: #3b82f6; /* brand */
          --radius: 0.5rem;
        }

        .dark {
          --background: oklch(0.145 0 0);
          --foreground: oklch(0.985 0 0);
          --primary: hsl(210 40% 98%);
        }
        """
        let (light, dark) = try TweakcnImport.parseCSS(css)
        #expect(light["background"] == "oklch(1 0 0)")
        #expect(light["primary"] == "#3b82f6")
        #expect(light["radius"] == "0.5rem")
        #expect(dark["foreground"] == "oklch(0.985 0 0)")
        #expect(dark["primary"] == "hsl(210 40% 98%)")
    }

    @Test("a single block serves both variants; bare lines too; nothing is an error")
    func cssOneBlock() throws {
        let one = try TweakcnImport.parseCSS(":root { --background: #ffffff; --primary: #000000; }")
        #expect(one.light["primary"] == "#000000" && one.dark["primary"] == "#000000")
        let bare = try TweakcnImport.parseCSS("--background: #ffffff;\n--primary: #000000")
        #expect(bare.light["background"] == "#ffffff" && bare.dark["background"] == "#ffffff")
        let darkOnly = try TweakcnImport.parseCSS("[data-theme=\"dark\"] { --background: #000; }")
        #expect(darkOnly.light["background"] == "#000", "the only block serves both")
        #expect(throws: TweakcnImport.ImportError.noVariables) {
            try TweakcnImport.parseCSS("body { color: red; }")
        }
    }

    @Test("a @media (prefers-color-scheme: dark) wrapper is walked into")
    func cssMedia() throws {
        let css = """
        :root { --background: #fff; }
        @media (prefers-color-scheme: dark) { :root { --background: #000; } }
        """
        let (light, dark) = try TweakcnImport.parseCSS(css)
        #expect(light["background"] == "#fff")
        #expect(dark["background"] == "#000")
    }

    // MARK: Registry

    @Test("the registry file names the theme and carries both variable sets")
    func registry() throws {
        let json = """
        {"name": "twitter", "type": "registry:style", "title": "Twitter",
         "cssVars": {"theme": {"font-sans": "Open Sans", "radius": "1.3rem"},
                     "light": {"background": "oklch(1 0 0)", "primary": "oklch(0.6723 0.1606 244.9955)",
                               "card": "oklch(0.9784 0.0011 197.1387)", "border": "oklch(0.9317 0.0001 200)"},
                     "dark": {"background": "oklch(0 0 0)", "primary": "oklch(0.6692 0.1607 245.011)"}}}
        """
        let parsed = try TweakcnImport.parseRegistry(Data(json.utf8))
        #expect(parsed.name == "Twitter")
        #expect(parsed.light["card"] == "oklch(0.9784 0.0011 197.1387)")
        #expect(parsed.dark["background"] == "oklch(0 0 0)")
        #expect(throws: TweakcnImport.ImportError.notARegistry) {
            try TweakcnImport.parseRegistry(Data("{\"name\": \"x\"}".utf8))
        }
    }

    @Test("a registry URL from the URL itself, the editor's URL, or a bare name")
    func registryURL() {
        let expected = URL(string: "https://tweakcn.com/r/themes/modern-minimal.json")
        #expect(TweakcnImport.registryURL(for: "https://tweakcn.com/r/themes/modern-minimal.json") == expected)
        #expect(TweakcnImport.registryURL(for: "https://tweakcn.com/themes/modern-minimal") == expected)
        #expect(TweakcnImport.registryURL(for: "tweakcn.com/themes/modern-minimal") == expected)
        #expect(TweakcnImport.registryURL(for: " Modern-Minimal ") == expected)
        #expect(TweakcnImport.registryURL(for: "https://example.com/r/themes/x.json") == nil)
        #expect(TweakcnImport.registryURL(for: "two words") == nil)
        #expect(TweakcnImport.registryURL(for: "") == nil)
        #expect(TweakcnImport.themeName(from: expected!) == "Modern Minimal")
        #expect(TweakcnImport.prettify("Twitter") == "Twitter")
        #expect(TweakcnImport.prettify("modern_minimal") == "Modern Minimal")
    }

    @Test("pasted text is CSS when it carries variables")
    func looksLikeCSS() {
        #expect(TweakcnImport.looksLikeCSS(":root { --background: #fff; }"))
        #expect(TweakcnImport.looksLikeCSS("--background: #fff"))
        #expect(!TweakcnImport.looksLikeCSS("modern-minimal"))
        #expect(!TweakcnImport.looksLikeCSS("https://tweakcn.com/r/themes/x.json"))
    }

    // MARK: Projection

    @Test("shadcn's variables land on Loom's tokens; the missing ones fall back to Loom's")
    func projection() {
        let vars: TweakcnImport.Variables = [
            "background": "#ffffff", "foreground": "#111111", "card": "#fafafa",
            "primary": "#3b82f6", "primary-foreground": "#ffffff", "muted-foreground": "#666666",
            "border": "#e5e5e5", "destructive": "#ef4444", "chart-2": "#10b981", "sidebar": "#f4f4f5",
        ]
        let tokens = TweakcnImport.tokens(from: vars, dark: false)
        #expect(tokens.background == "#F4F4F5", "the sidebar colour is the chrome")
        #expect(tokens.contentBackground == "#FFFFFF")
        #expect(tokens.surface == "#FAFAFA")
        #expect(tokens.cardBorder == "#E5E5E5")
        #expect(tokens.accent == "#3B82F6" && tokens.accentText == "#FFFFFF")
        #expect(tokens.primaryText == "#111111" && tokens.secondaryText == "#666666")
        #expect(tokens.mutedText == ThemeTokens.mix("#666666", with: "#ffffff", amount: 0.4))
        #expect(tokens.branch == "#10B981")
        #expect(tokens.danger == "#EF4444")
        #expect(tokens.surfaceRaised == ThemeFamily.loom.light.surfaceRaised, "no --secondary: Loom's")
        #expect(tokens.stateWorking == ThemeFamily.loom.light.stateWorking, "semantics stay Loom's")
        #expect(tokens.isLight)

        let dark = TweakcnImport.tokens(from: ["background": "#000000", "primary": "auto"], dark: true)
        #expect(dark.background == "#000000", "no --sidebar: the background")
        #expect(dark.accent == ThemeFamily.loom.dark.accent, "an unparsable value falls back")
        #expect(!dark.isLight)
    }

    @Test("a family from two variable sets, named and trimmed")
    func family() {
        let family = TweakcnImport.family(named: "  Twitter ",
                                          light: ["background": "#ffffff"],
                                          dark: ["background": "#000000"])
        #expect(family.name == "Twitter")
        #expect(family.light.isLight && !family.dark.isLight)
        #expect(!family.isBuiltIn)
        #expect(family.variantLightName == "Twitter Light")
    }
}
