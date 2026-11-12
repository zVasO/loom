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

    @Test("a value wrapped onto the next lines is read whole")
    func cssWrappedValues() throws {
        let css = """
        :root {
          --background: #ffffff;
          --font-sans:
            Plus Jakarta Sans, ui-sans-serif,
            sans-serif;
          --shadow-sm: 0 1px 3px 0px hsl(0 0% 0% / 0.10),
            0 1px 2px -1px hsl(0 0% 0% / 0.10);
          --radius: 0.5rem;
          color: red;
        }
        """
        let (light, _) = try TweakcnImport.parseCSS(css)
        #expect(light["font-sans"] == "Plus Jakarta Sans, ui-sans-serif, sans-serif")
        #expect(light["shadow-sm"] == "0 1px 3px 0px hsl(0 0% 0% / 0.10), 0 1px 2px -1px hsl(0 0% 0% / 0.10)")
        #expect(light["radius"] == "0.5rem" && light["background"] == "#ffffff")
        #expect(light.count == 4, "a declaration that is no variable is not one")
        let bare = TweakcnImport.variables(in: "--a: 1\ncolor: red\n--b: one,\n  two\n--c: 3")
        #expect(bare == ["a": "1", "b": "one, two", "c": "3"], "only a wrapped value runs on")
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

    @Test("a community theme's registry URL is fetched as given — no .json — then with it")
    func communityRegistryURL() {
        let id = "cmqx9le2j000504l49jgxe1d0"
        let bare = URL(string: "https://tweakcn.com/r/themes/\(id)")!
        let json = URL(string: "https://tweakcn.com/r/themes/\(id).json")!
        #expect(TweakcnImport.registryURLs(for: "https://tweakcn.com/r/themes/\(id)") == [bare, json])
        #expect(TweakcnImport.registryURLs(for: "https://tweakcn.com/themes/\(id)") == [json, bare])
        #expect(TweakcnImport.registryURLs(for: "https://tweakcn.com/editor/theme?theme=\(id)") == [json, bare])
        #expect(TweakcnImport.registryURLs(for: "https://tweakcn.com/r/themes/modern-minimal.json").first
                == URL(string: "https://tweakcn.com/r/themes/modern-minimal.json"))
        #expect(TweakcnImport.displayName(id, url: bare) == "Community theme")
        #expect(TweakcnImport.displayName("Sunset Horizon", url: bare) == "Sunset Horizon")
        #expect(TweakcnImport.displayName("Imported theme", url: json) == "Community theme")
    }

    @Test("var() aliases resolve to the colour they point at")
    func references() {
        let vars: TweakcnImport.Variables = [
            "background": "oklch(1 0 0)", "sidebar": "var(--background)",
            "card": "var(--sidebar)", "border": "var(--missing, #e5e5e5)",
            "primary": "hsl(var(--brand))", "brand": "210 40% 98%",
        ]
        let resolved = TweakcnImport.resolvingReferences(vars)
        #expect(resolved["sidebar"] == "oklch(1 0 0)")
        #expect(resolved["card"] == "oklch(1 0 0)", "an alias of an alias")
        #expect(resolved["border"] == "#e5e5e5", "the fallback when the target is missing")
        #expect(CSSColor.parse(resolved["primary"] ?? "") == "#F8FAFC")
        let tokens = TweakcnImport.tokens(from: vars, dark: false)
        #expect(tokens.surface == "#FFFFFF" && tokens.cardBorder == "#E5E5E5")
    }

    @Test("hex with alpha and colour keywords")
    func hexAlphaAndKeywords() {
        #expect(CSSColor.parse("#3b82f680") == "#3B82F6")
        #expect(CSSColor.parse("#fff8") == "#FFFFFF")
        #expect(CSSColor.parse("white") == "#FFFFFF")
        #expect(CSSColor.parse("black") == "#000000")
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

    @Test("a dark variant's raised surface comes from --muted, never a light --secondary chip")
    func raisedSurfaceStaysDark() {
        // tweakcn's Claude theme: --secondary is a near-white chip in .dark.
        let vars: TweakcnImport.Variables = [
            "background": "#262624", "foreground": "#c3c0b6", "card": "#262624",
            "secondary": "#faf9f5", "muted": "#1b1b19",
        ]
        let tokens = TweakcnImport.tokens(from: vars, dark: true)
        #expect(tokens.surfaceRaised == "#1B1B19")
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
        #expect(family.document == nil, "no font, no radius: nothing for documents")
        #expect(family.light.design == nil && family.dark.design == nil, "colours alone: the charter's design")
    }

    @Test("fonts and radius become the theme's document style, from CSS or from the registry's shared block")
    func documentStyle() throws {
        let css = TweakcnImport.family(named: "T", light: ["background": "#fff", "font-sans": "Nunito, sans-serif",
                                                            "radius": "1rem"], dark: ["background": "#000"])
        #expect(css.document == ThemeDocumentStyle(fontSans: "Nunito, sans-serif", radius: "1rem"))
        let json = ##"{"name": "t", "cssVars": {"theme": {"font-mono": "JetBrains Mono", "radius": "0.5rem"}, "light": {"background": "#fff", "radius": "1rem"}, "dark": {"background": "#000"}}}"##
        let parsed = try TweakcnImport.parseRegistry(Data(json.utf8))
        let family = TweakcnImport.family(named: parsed.name, light: parsed.light, dark: parsed.dark)
        #expect(family.document?.fontMono == "JetBrains Mono")
        #expect(family.document?.radius == "1rem", "the variant's own value wins")
        #expect(ThemeDocumentStyle.isAllowedFontsURL("https://fonts.googleapis.com/css2?family=Nunito"))
        #expect(!ThemeDocumentStyle.isAllowedFontsURL("https://evil.example/fonts.css"))
    }

    // MARK: Design — what the theme says beyond its colours (ADR-0022)

    /// tweakcn's Code export of its "Neo Brutalism" preset (Tailwind v4,
    /// oklch), as its generator writes it today — header, both blocks,
    /// `@theme inline`, `@layer base` — with the colours not read here cut.
    private static let neoBrutalism = """
    @import "tailwindcss";

    @custom-variant dark (&:is(.dark *));

    :root {
      --background: oklch(1.0000 0 0);
      --foreground: oklch(0 0 0);
      --card: oklch(1.0000 0 0);
      --primary: oklch(0.6489 0.2370 26.9728);
      --primary-foreground: oklch(1.0000 0 0);
      --muted: oklch(0.9551 0 0);
      --muted-foreground: oklch(0.3211 0 0);
      --border: oklch(0 0 0);
      --input: oklch(0 0 0);
      --font-sans: DM Sans, sans-serif;
      --font-serif: ui-serif, Georgia, Cambria, "Times New Roman", Times, serif;
      --font-mono: Space Mono, monospace;
      --radius: 0px;
      --shadow-x: 4px;
      --shadow-y: 4px;
      --shadow-blur: 0px;
      --shadow-spread: 0px;
      --shadow-opacity: 1;
      --shadow-color: hsl(0 0% 0%);
      --shadow-sm: 4px 4px 0px 0px hsl(0 0% 0% / 1.00), 4px 1px 2px -1px hsl(0 0% 0% / 1.00);
      --tracking-normal: 0em;
      --spacing: 0.25rem;
    }

    .dark {
      --background: oklch(0 0 0);
      --foreground: oklch(1.0000 0 0);
      --card: oklch(0.3211 0 0);
      --primary: oklch(0.7044 0.1872 23.1858);
      --primary-foreground: oklch(0 0 0);
      --muted: oklch(0.2178 0 0);
      --muted-foreground: oklch(0.8452 0 0);
      --border: oklch(1.0000 0 0);
      --input: oklch(1.0000 0 0);
      --font-sans: DM Sans, sans-serif;
      --font-serif: ui-serif, Georgia, Cambria, "Times New Roman", Times, serif;
      --font-mono: Space Mono, monospace;
      --radius: 0px;
      --shadow-x: 4px;
      --shadow-y: 4px;
      --shadow-blur: 0px;
      --shadow-spread: 0px;
      --shadow-opacity: 1;
      --shadow-color: hsl(0 0% 0%);
      --shadow-sm: 4px 4px 0px 0px hsl(0 0% 0% / 1.00), 4px 1px 2px -1px hsl(0 0% 0% / 1.00);
    }

    @theme inline {
      --color-background: var(--background);
      --color-border: var(--border);

      --font-sans: var(--font-sans);
      --font-mono: var(--font-mono);
      --font-serif: var(--font-serif);

      --radius-sm: calc(var(--radius) - 4px);
      --radius-md: calc(var(--radius) - 2px);
      --radius-lg: var(--radius);
      --radius-xl: calc(var(--radius) + 4px);

      --shadow-sm: var(--shadow-sm);
    }

    @layer base {
      * {
        @apply border-border outline-ring/50;
      }
      body {
        @apply bg-background text-foreground;
      }
    }
    """

    @Test("the whole Code export — header, @theme inline, @layer base — reads as its two blocks")
    func cssWholeExport() throws {
        let (light, dark) = try TweakcnImport.parseCSS(Self.neoBrutalism)
        #expect(light["background"] == "oklch(1.0000 0 0)", "`@import …;` is a statement, not :root's selector")
        #expect(dark["background"] == "oklch(0 0 0)")
        #expect(light["font-sans"] == "DM Sans, sans-serif", "@theme inline's aliases overwrite nothing")
        #expect(light["radius"] == "0px" && light["spacing"] == "0.25rem")
        #expect(dark["spacing"] == nil, "tweakcn writes --spacing in :root only")
        let family = TweakcnImport.family(named: "Neo Brutalism", light: light, dark: dark)
        #expect(family.light.isLight && !family.dark.isLight)
        #expect(family.light.contentBackground == "#FFFFFF" && family.dark.contentBackground == "#000000")
    }

    @Test("a theme's design is read to the letter: radius, spacing, fonts, edges, shadow")
    func designFromCSS() throws {
        let (light, dark) = try TweakcnImport.parseCSS(Self.neoBrutalism)
        let family = TweakcnImport.family(named: "Neo Brutalism", light: light, dark: dark)
        let day = try #require(family.light.design)
        #expect(day.radius == 0)
        #expect(day.spacing == 4)
        #expect(day.letterSpacing == nil, "0em is no letter-spacing")
        #expect(day.fontSans == "DM Sans, sans-serif")
        #expect(day.fontMono == "Space Mono, monospace")
        #expect(day.fontSerif == "ui-serif, Georgia, Cambria, \"Times New Roman\", Times, serif")
        #expect(day.border == "#000000" && day.input == "#000000")
        #expect(day.shadow == ThemeShadow(color: "#000000", opacity: 1, blur: 0, spread: 0, x: 4, y: 4))

        let night = try #require(family.dark.design)
        #expect(night.border == "#FFFFFF" && night.input == "#FFFFFF", "each variant has its own edges")
        #expect(night.radius == 0 && night.spacing == 4, ":root's --spacing serves .dark too")
        #expect(night.fontSans == day.fontSans && night.shadow == day.shadow)

        // What the app draws with it: square controls, tweakcn's 4 pt cards, black edges.
        let palette = family.palette(dark: false)
        #expect(palette.radius(6) == 0 && palette.radius(10) == 4)
        #expect(palette.line == ThemePalette.color("#000000"))
        #expect(palette.space(8) == 8)
    }

    @Test("the registry file carries the same design; the values tweakcn shares are the light variant's in both")
    func designFromRegistry() throws {
        // Violet Bloom: a wide radius, a negative letter-spacing, a spacing
        // of 0.27rem. Graphite's dark block names another font (Inter).
        let json = ##"""
        {"name": "Violet Bloom", "type": "registry:style",
         "css": {"@layer base": {"body": {"letter-spacing": "var(--tracking-normal)"}}},
         "cssVars": {
           "theme": {"font-sans": "Plus Jakarta Sans, sans-serif", "font-mono": "IBM Plex Mono, monospace",
                     "radius": "1.4rem", "tracking-tight": "calc(var(--tracking-normal) - 0.025em)"},
           "light": {"background": "oklch(0.9940 0 0)", "foreground": "oklch(0 0 0)",
                     "border": "oklch(0.9300 0.0094 286.2156)", "input": "oklch(0.9401 0 0)",
                     "radius": "1.4rem", "font-sans": "Montserrat, sans-serif", "font-mono": "IBM Plex Mono, monospace",
                     "shadow-color": "hsl(0 0% 20% / 0.1)", "shadow-opacity": "0.16", "shadow-blur": "3px",
                     "shadow-spread": "0px", "shadow-offset-x": "0px", "shadow-offset-y": "2px",
                     "letter-spacing": "-0.025em", "spacing": "0.27rem", "tracking-normal": "-0.025em"},
           "dark": {"background": "oklch(0.2223 0.0060 271.1393)", "foreground": "oklch(0.9551 0 0)",
                    "border": "oklch(0.3289 0.0092 268.3843)", "input": "oklch(0.3289 0.0092 268.3843)",
                    "radius": "0.35rem", "font-sans": "Inter, sans-serif", "font-mono": "IBM Plex Mono, monospace",
                    "shadow-color": "#000000", "shadow-opacity": "0.4", "shadow-blur": "3px",
                    "shadow-spread": "0px", "shadow-offset-x": "0px", "shadow-offset-y": "2px",
                    "letter-spacing": "0em", "spacing": "0.25rem"}}}
        """##
        let parsed = try TweakcnImport.parseRegistry(Data(json.utf8))
        let family = TweakcnImport.family(named: parsed.name, light: parsed.light, dark: parsed.dark)
        let day = try #require(family.light.design)
        #expect(abs((day.radius ?? 0) - 22.4) < 1e-9)
        #expect(abs((day.spacing ?? 0) - 4.32) < 1e-9)
        #expect(day.letterSpacing == -0.025)
        #expect(day.fontSans == "Montserrat, sans-serif", "the variant's own value wins over the shared block")
        #expect(day.shadow == ThemeShadow(color: "#333333", opacity: 0.16, blur: 3, spread: 0, x: 0, y: 2),
                "the shadow colour's own alpha is not the shadow's opacity")
        #expect(day.border == CSSColor.parse("oklch(0.9300 0.0094 286.2156)"))

        let night = try #require(family.dark.design)
        #expect(night.fontSans == "Montserrat, sans-serif", "fonts are shared: the light variant's")
        #expect(night.radius == day.radius && night.spacing == day.spacing && night.letterSpacing == -0.025)
        #expect(night.shadow?.opacity == 0.16 && night.shadow?.color == "#000000",
                "the geometry and opacity are shared, the colour is the variant's")
        #expect(night.border == CSSColor.parse("oklch(0.3289 0.0092 268.3843)"))
        #expect(family.document?.radius == "1.4rem", "documents still get their style")
    }

    @Test("an older export has no shadow parameters: the first layer of --shadow-sm stands for them")
    func composedShadows() throws {
        let clay = TweakcnImport.composedShadow(
            "2px 2px 10px 4px hsl(240 4% 60% / 0.18), 2px 1px 2px 3px hsl(240 4% 60% / 0.18)")
        let lilac = try #require(CSSColor.parse("hsl(240 4% 60%)"))
        #expect(clay == ThemeShadow(color: lilac, opacity: 0.18, blur: 10, spread: 4, x: 2, y: 2))
        #expect(TweakcnImport.composedShadow("0 1px rgb(0 0 0 / 0.05)")
                == ThemeShadow(color: "#000000", opacity: 0.05, blur: 0, spread: 0, x: 0, y: 1))
        #expect(TweakcnImport.composedShadow("none") == nil)
        let design = TweakcnImport.design(from: ["shadow-sm": "0px 4px 8px -1px hsl(0 0% 0% / 0.10), 0px 1px 2px -2px hsl(0 0% 0% / 0.10)"],
                                          background: "#FFFFFF")
        #expect(design?.shadow == ThemeShadow(color: "#000000", opacity: 0.1, blur: 8, spread: -1, x: 0, y: 4))
        #expect(TweakcnImport.design(from: ["background": "#fff", "primary": "#000"], background: "#FFFFFF") == nil,
                "colours alone are no design")
        #expect(TweakcnImport.design(from: ["spacing": "1rem"], background: "#FFFFFF")?.spacing == 8,
                "a spacing far outside tweakcn's range is held back")
        #expect(TweakcnImport.design(from: ["letter-spacing": "0.5px"], background: "#FFFFFF")?.letterSpacing == 0.03125)
        #expect(TweakcnImport.design(from: ["shadow-opacity": "100%"], background: "#FFFFFF")?.shadow
                == ThemeShadow(color: "#000000", opacity: 1, blur: 3, spread: 0, x: 0, y: 1),
                "the parameters left out are tweakcn's defaults")
    }

    @Test("a translucent colour is what it looks like on the page: shadcn's dark border at 10 %")
    func translucentColours() {
        #expect(CSSColor.alpha("oklch(1 0 0 / 10%)") == 0.1)
        #expect(CSSColor.alpha("hsl(0 0% 0% / 0.50)") == 0.5)
        #expect(CSSColor.alpha("rgba(29, 161, 242, 0.15)") == 0.15)
        #expect(CSSColor.alpha("#ffffff80") == 128.0 / 255)
        #expect(CSSColor.alpha("#fff") == 1 && CSSColor.alpha("oklch(1 0 0)") == 1 && CSSColor.alpha("rgb(1, 2, 3)") == 1)
        #expect(CSSColor.opaque("oklch(1 0 0 / 10%)", over: "#0A0A0A") == ThemeTokens.mix("#0A0A0A", with: "#FFFFFF", amount: 0.1))
        #expect(CSSColor.opaque("#3b82f6", over: "#000000") == "#3B82F6")
        #expect(CSSColor.opaque("nope", over: "#000000") == nil)

        let vars: TweakcnImport.Variables = [
            "background": "oklch(0.145 0 0)", "foreground": "oklch(0.985 0 0)",
            "border": "oklch(1 0 0 / 10%)", "input": "oklch(1 0 0 / 15%)",
        ]
        let tokens = TweakcnImport.tokens(from: vars, dark: true)
        let border = ThemeTokens.mix("#0A0A0A", with: "#FFFFFF", amount: 0.1)
        #expect(tokens.contentBackground == "#0A0A0A")
        #expect(tokens.cardBorder == border, "not a white edge")
        let design = TweakcnImport.design(from: vars, background: tokens.contentBackground)
        #expect(design?.border == border)
        #expect(design?.input == ThemeTokens.mix("#0A0A0A", with: "#FFFFFF", amount: 0.15))
    }
}
