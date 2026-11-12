import Testing
import Foundation
import SwiftUI
@testable import LoomUI

// A theme's design (ADR-0022): what a tweakcn theme says beyond its colours
// — radius, spacing, letter-spacing, fonts, edges, shadow — and how the
// charter's numbers become the theme's. A family without one is untouched.
@Suite("ThemeDesign — a theme's geometry, type and edges")
struct ThemeDesignTests {

    private func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    // MARK: The charter stays the charter

    @Test("a family without a design draws exactly what the charter says")
    func charterUntouched() {
        for family in ThemeFamily.builtins {
            for palette in [family.palette(dark: false), family.palette(dark: true)] {
                #expect(palette.design == nil, Comment(rawValue: palette.name))
                for value: CGFloat in [1.5, 3, 4, 6, 10, 10.5, 38] {
                    #expect(palette.radius(value) == value)
                    #expect(palette.space(value) == value)
                }
                #expect(palette.tracking == 0)
                #expect(palette.line == palette.primaryText.opacity(0.08))
                #expect(palette.line2 == palette.primaryText.opacity(0.13))
                #expect(palette.line3 == palette.primaryText.opacity(0.21))
                #expect(palette.wash == palette.primaryText.opacity(0.025))
                #expect(palette.wash2 == palette.primaryText.opacity(0.045))
            }
        }
    }

    // MARK: Geometry

    @Test("a radius follows tweakcn's scale: xl a card, lg, md a control, sm a tab, a pill a tag")
    func radiusScale() {
        let design = ThemeDesign(radius: 10)
        #expect(design.radius(10) == 14, "rounded-xl: --radius + 4")
        #expect(design.radius(8) == 10, "rounded-lg: --radius")
        #expect(design.radius(6) == 8, "rounded-md: --radius - 2")
        #expect(design.radius(4) == 6, "rounded-sm: --radius - 4")
        #expect(design.radius(3) == ThemeDesign.pill, "a tag is a Badge: rounded-full")
        #expect(design.radius(9) == 13 && design.radius(7) == 9 && design.radius(5) == 7,
                "in between, the distance to the nearest step is kept")

        let square = ThemeDesign(radius: 0)
        #expect(square.radius(10) == 4, "rounded-xl of a square theme is 4, as on tweakcn")
        #expect(square.radius(8) == 0 && square.radius(6) == 0 && square.radius(4) == 0,
                "calc(0px - 2px) clamps to 0")
        #expect(square.radius(3) == ThemeDesign.pill)

        let round = ThemeDesign(radius: 22.4)
        #expect(near(round.radius(10), 26.4) && near(round.radius(6), 20.4) && near(round.radius(4), 18.4))

        #expect(ThemeDesign().radius(6) == 6, "no --radius: the charter's")
        #expect(ThemeDesign(spacing: 5).radius(10) == 10)
        #expect(design.radius(0) == 0)
    }

    @Test("lengths scale with --spacing, on the half-point grid")
    func spacingScale() {
        let wide = ThemeDesign(spacing: 4.32)      // 0.27rem
        #expect(wide.space(8) == 8.5)
        #expect(wide.space(10) == 11)
        #expect(wide.space(38) == 41)
        #expect(wide.space(0) == 0)
        let tight = ThemeDesign(spacing: 3.68)     // 0.23rem
        #expect(tight.space(10) == 9)
        #expect(tight.space(6) == 5.5)
        #expect(ThemeDesign(spacing: 4).space(7) == 7, "Tailwind's own unit changes nothing")
        #expect(ThemeDesign(spacing: 4).space(13.25) == 13.25, "and rounds nothing")
        #expect(ThemeDesign().space(13.5) == 13.5)
    }

    @Test("the letter-spacing is one length for every text: the em of the body's 16 px")
    func tracking() {
        #expect(near(ThemeDesign(letterSpacing: 0.025).tracking, 0.4))
        #expect(near(ThemeDesign(letterSpacing: -0.025).tracking, -0.4))
        #expect(ThemeDesign().tracking == 0)
        var tokens = ThemeFamily.loom.dark
        tokens.design = ThemeDesign(radius: 8, spacing: 5, letterSpacing: 0.05)
        let palette = ThemePalette(name: "T", isLight: false, tokens: tokens)
        #expect(abs(palette.tracking - 0.8) < 1e-9)
        #expect(palette.radius(6) == 6 && palette.radius(10) == 12)
        #expect(palette.space(8) == 10)
    }

    // MARK: Shadow

    @Test("a level's layers are tweakcn's own composition of the six parameters")
    func shadowLayers() {
        // neo-brutalism: 4px 4px 0px 0px, opacity 1.
        let hard = ThemeShadow(color: "#000000", opacity: 1, blur: 0, spread: 0, x: 4, y: 4)
        #expect(hard.layers(.xs) == [ThemeShadow.Layer(color: "#000000", opacity: 0.5, blur: 0, spread: 0, x: 4, y: 4)])
        #expect(hard.layers(.xxs) == hard.layers(.xs))
        #expect(hard.layers(.sm) == [
            ThemeShadow.Layer(color: "#000000", opacity: 1, blur: 0, spread: 0, x: 4, y: 4),
            ThemeShadow.Layer(color: "#000000", opacity: 1, blur: 2, spread: -1, x: 4, y: 1),
        ], "4px 4px 0px 0px …, 4px 1px 2px -1px …")
        #expect(hard.layers(.xxl).first?.opacity == 1, "2.5 times the opacity, never past 1")

        // tweakcn's default: 0 1px 3px 0px at 10 %.
        let soft = ThemeShadow(color: "#000000", opacity: 0.1, blur: 3, spread: 0, x: 0, y: 1)
        #expect(soft.layers(.md).last == ThemeShadow.Layer(color: "#000000", opacity: 0.1, blur: 4, spread: -1, x: 0, y: 2))
        #expect(soft.layers(.lg).last == ThemeShadow.Layer(color: "#000000", opacity: 0.1, blur: 6, spread: -1, x: 0, y: 4))
        #expect(soft.layers(.xl).last == ThemeShadow.Layer(color: "#000000", opacity: 0.1, blur: 10, spread: -1, x: 0, y: 8))
        #expect(near(soft.layers(.xxl).first?.opacity, 0.25))
        #expect(!soft.isInvisible)
        #expect(ThemeShadow(color: "#000000", opacity: 0, blur: 3, spread: 0, x: 0, y: 1).isInvisible)
    }

    // MARK: Edges

    @Test("a theme with a border of its own is drawn with it; the control's edge is --input")
    func edges() {
        var tokens = ThemeFamily.loom.light
        tokens.design = ThemeDesign(border: "#E5E5E5", input: "#D4D4D4")
        let palette = ThemePalette(name: "T", isLight: true, tokens: tokens)
        #expect(palette.line == ThemePalette.color("#E5E5E5"))
        #expect(palette.line2 == ThemePalette.color("#D4D4D4"))
        #expect(palette.line3 == ThemePalette.color(ThemeTokens.mix("#D4D4D4", with: tokens.primaryText, amount: 0.3)))
        #expect(palette.wash == palette.surfaceRaised.opacity(0.5), "shadcn's hover:bg-muted/50")
        #expect(palette.wash2 == palette.surfaceRaised, "and its selected bg-muted")

        tokens.design = ThemeDesign(border: "#E5E5E5")
        #expect(ThemePalette(name: "T", isLight: true, tokens: tokens).line2 == ThemePalette.color("#E5E5E5"),
                "no --input: the border")

        tokens.design = ThemeDesign(radius: 8, border: "not a colour")
        let fallback = ThemePalette(name: "T", isLight: true, tokens: tokens)
        #expect(fallback.line == fallback.primaryText.opacity(0.08), "an unreadable border keeps the hairline")
    }

    // MARK: On disk

    @Test("a design travels with its variant on disk; a file without one is the charter")
    func roundTrip() throws {
        var family = ThemeFamily(name: "T", light: ThemeFamily.loom.light, dark: ThemeFamily.loom.dark)
        family.light.design = ThemeDesign(radius: 22.4, spacing: 4.32, letterSpacing: -0.025,
                                          fontSans: "Plus Jakarta Sans, sans-serif", fontMono: "IBM Plex Mono, monospace",
                                          border: "#EAE9F0", input: "#EDEDED",
                                          shadow: ThemeShadow(color: "#000000", opacity: 0.16, blur: 3, spread: 0, x: 0, y: 2))
        family.dark.design = ThemeDesign(radius: 22.4, border: "#33353A")
        let data = try JSONEncoder().encode(family)
        let decoded = try JSONDecoder().decode(ThemeFamily.self, from: data)
        #expect(decoded.light == family.light && decoded.dark == family.dark)
        #expect(decoded.palette(dark: false).design == family.light.design)

        let old = try JSONDecoder().decode(ThemeFamily.self, from: JSONEncoder().encode(ThemeFamily.tokyoNight))
        #expect(old.light.design == nil && old.dark.design == nil)
        #expect(ThemeDesign().isEmpty && !ThemeDesign(radius: 0).isEmpty)
        #expect(ThemeFamily.loom.light.sanitized.design == nil)
        #expect(family.light.sanitized.design == family.light.design, "sanitizing keeps the design")
    }

    // MARK: CSS lengths

    @Test("the lengths a theme writes: rem, px, em, a bare zero")
    func lengths() {
        #expect(CSSLength.points("0.625rem") == 10)
        #expect(CSSLength.points("10px") == 10)
        #expect(CSSLength.points("0") == 0)
        #expect(CSSLength.points(".5rem") == 8)
        #expect(CSSLength.points(" -1px ") == -1)
        #expect(CSSLength.points("2.5px") == 2.5)
        #expect(CSSLength.points("calc(0.625rem - 2px)") == nil)
        #expect(CSSLength.points("auto") == nil)
        #expect(CSSLength.points("") == nil)
        #expect(CSSLength.em("0.025em") == 0.025)
        #expect(CSSLength.em("-0.025em") == -0.025)
        #expect(CSSLength.em("normal") == 0)
        #expect(CSSLength.em("0rem") == 0)
        #expect(CSSLength.em("0.5px") == 0.03125, "px over the body's 16")
        #expect(CSSLength.em("wide") == nil)
        #expect(CSSLength.number("0.18") == 0.18)
        #expect(CSSLength.number("1.0") == 1)
        #expect(CSSLength.number("100%") == 1)
        #expect(CSSLength.number("3px") == nil)
    }

    // MARK: Font stacks

    @Test("a font stack is read like a browser reads it")
    func fontStacks() {
        #expect(FontStack.parse("Inter, sans-serif") == [.family("Inter"), .generic(.sans)])
        #expect(FontStack.parse("\"Fira Code\", 'Courier New', monospace")
                == [.family("Fira Code"), .family("Courier New"), .generic(.mono)])
        #expect(FontStack.parse("Plus Jakarta Sans, ui-sans-serif, sans-serif, system-ui").first
                == .family("Plus Jakarta Sans"), "an unquoted name with spaces")
        #expect(FontStack.parse("Caveat, cursive") == [.family("Caveat")])
        #expect(FontStack.parse("serif") == [.generic(.serif)])
        #expect(FontStack.parse("") == [])
        // tweakcn's default stacks start with a keyword: the system's face, nothing to fetch.
        let sans = "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
        #expect(FontStack.parse(sans).first == .generic(.sans))
        #expect(FontStack.namedFamilies(sans) == [])
        #expect(FontStack.namedFamilies("ui-monospace, SFMono-Regular, Menlo, monospace") == [])
        #expect(FontStack.namedFamilies("Signifier, Georgia, serif") == ["Signifier", "Georgia"])
        #expect(FontStack.namedFamilies("JetBrains Mono, ui-monospace, monospace") == ["JetBrains Mono"])
    }

    // MARK: Google Fonts

    @Test("a family's stylesheet address, and nothing for what cannot be a family")
    func stylesheetURL() {
        #expect(GoogleFonts.stylesheetURL(family: "Plus Jakarta Sans")?.absoluteString
                == "https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap")
        #expect(GoogleFonts.stylesheetURL(families: ["Inter", "JetBrains Mono"])?.absoluteString
                == "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap")
        #expect(GoogleFonts.stylesheetURL(family: "Source Serif 4") != nil)
        #expect(GoogleFonts.stylesheetURL(family: "Inter&family=Evil") == nil)
        #expect(GoogleFonts.stylesheetURL(family: "a/../b") == nil)
        #expect(GoogleFonts.stylesheetURL(family: "") == nil)
        #expect(GoogleFonts.stylesheetURL(families: []) == nil)
    }

    @Test("the font files of a stylesheet: upright, one per weight, Google's host only")
    func stylesheetFaces() {
        // What fonts.googleapis.com answers a client that is not a browser.
        let css = """
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 500;
          font-display: swap;
          src: url(https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuI6fMZg.ttf) format('truetype');
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 400;
          font-display: swap;
          src: url(https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuLyfMZg.ttf) format('truetype');
        }
        @font-face {
          font-family: 'Inter';
          font-style: italic;
          font-weight: 700;
          src: url(https://fonts.gstatic.com/s/inter/v20/italic.ttf) format('truetype');
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 600;
          src: url(https://fonts.gstatic.com/s/inter/v20/subset.woff2) format('woff2');
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 800;
          src: url("https://evil.example/inter.ttf") format('truetype');
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 100 900;
          src: url(https://fonts.gstatic.com/s/inter/v20/variable.ttf) format('truetype');
        }
        """
        let faces = GoogleFonts.faces(inStylesheet: css)
        #expect(faces.map(\.weight) == [400, 500], "lightest first; italic, woff2, another host and a range left out")
        #expect(faces.first?.url.absoluteString
                == "https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuLyfMZg.ttf")
        #expect(GoogleFonts.faces(inStylesheet: "/* nothing */").isEmpty)
        #expect(GoogleFonts.faces(inStylesheet: "@font-face { font-weight: 400; src: url(").isEmpty)
    }

    // MARK: Fonts on this Mac

    @Test("a fetched family keeps its weights: the nearest face, CSS's way")
    func fetchedFaces() {
        let mono = ThemeFonts.FetchedFamily(name: "Space Mono", faces: [400: "SpaceMono-Regular", 700: "SpaceMono-Bold"])
        #expect(mono.face(nearest: 400) == "SpaceMono-Regular")
        #expect(mono.face(nearest: 500) == "SpaceMono-Regular")
        #expect(mono.face(nearest: 600) == "SpaceMono-Bold")
        #expect(mono.face(nearest: 900) == "SpaceMono-Bold")
        let two = ThemeFonts.FetchedFamily(name: "X", faces: [400: "X-Regular", 600: "X-SemiBold"])
        #expect(two.face(nearest: 500) == "X-Regular", "as near on both sides, up to medium: the lighter")
        #expect(ThemeFonts.FetchedFamily(name: "Y", faces: [:]).face(nearest: 400) == nil)
        #expect(ThemeFonts.slug("Plus Jakarta Sans") == "plus-jakarta-sans")
    }

    @Test("a stack comes down to a family this Mac has, or to the system's face")
    @MainActor
    func stacksResolve() {
        let fonts = ThemeFonts.shared
        #expect(fonts.resolve("ui-sans-serif, system-ui, sans-serif") == .generic(.sans))
        #expect(fonts.resolve("ui-monospace, SFMono-Regular, Menlo, monospace") == .generic(.mono))
        #expect(fonts.familyName(for: "No Such Family 4242, Helvetica Neue, sans-serif") == "Helvetica Neue",
                "the first family that is there")
        #expect(fonts.familyName(for: "No Such Family 4242, serif") == nil)
        #expect(fonts.resolve("No Such Family 4242") == .none)
        #expect(fonts.isAvailable("menlo"), "names are matched whatever their case")
        #expect(!fonts.isAvailable("No Such Family 4242"))
        #expect(ThemeFonts.cssWeight(.semibold) == 600 && ThemeFonts.cssWeight(nil) == 400)
        #expect(ThemeFonts.appKitWeight(.bold) == 9 && ThemeFonts.appKitWeight(.regular) == 5)
    }
}
