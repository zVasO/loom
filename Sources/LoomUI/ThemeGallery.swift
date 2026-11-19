import Foundation

// Fifteen themes that ship with Loom beside the classics, each with a
// design of its own (ADR-0022): fonts, radius, spacing, edges, shadow — not
// only colours. Ten are bold; five are made for long sessions: low glare,
// no pure black or white, typefaces drawn for reading. Their fonts come
// from Google Fonts the first time a theme is used, as an imported theme's
// do. Each can be followed for its colours only, like an imported one.

extension ThemeFamily {

    /// The themes with a design of their own. Legible by construction: the
    /// tokens go through the pass an imported theme goes through.
    public static let gallery: [ThemeFamily] = bold + comfort

    /// What a variant is made from; the rest is mixed from these.
    struct Seed {
        var ground: String
        var content: String
        var surface: String
        var text: String
        var accent: String
        var accentText: String
        var branch: String
        var danger: String
        var ok: String
        var warn: String
        var info: String
    }

    static func tokens(_ seed: Seed, design: ThemeDesign) -> ThemeTokens {
        ThemeTokens(
            background: seed.ground, contentBackground: seed.content, surface: seed.surface,
            surfaceRaised: ThemeTokens.mix(seed.surface, with: seed.text, amount: 0.08),
            cardBorder: ThemeTokens.mix(seed.surface, with: seed.text, amount: 0.16),
            accent: seed.accent, accentText: seed.accentText,
            primaryText: seed.text,
            secondaryText: ThemeTokens.mix(seed.text, with: seed.ground, amount: 0.34),
            mutedText: ThemeTokens.mix(seed.text, with: seed.ground, amount: 0.52),
            branch: seed.branch, danger: seed.danger, groupHeader: seed.ok,
            stateWorking: seed.ok, stateNeedsInput: seed.warn, stateIdle: seed.info,
            design: design).sanitized
    }

    static func family(_ name: String, light: Seed, dark: Seed, design: ThemeDesign,
                       darkDesign: ThemeDesign? = nil) -> ThemeFamily {
        ThemeFamily(name: name, light: tokens(light, design: design),
                    dark: tokens(dark, design: darkDesign ?? design), isBuiltIn: true)
    }

    static func hard(_ color: String, _ offset: Double) -> ThemeShadow {
        ThemeShadow(color: color, opacity: 1, blur: 0, spread: 0, x: offset, y: offset)
    }

    static func soft(_ color: String, _ opacity: Double, blur: Double, y: Double) -> ThemeShadow {
        ThemeShadow(color: color, opacity: opacity, blur: blur, spread: 0, x: 0, y: y)
    }

    // MARK: Bold

    static let bold: [ThemeFamily] = [
        // Night city: magenta and cyan signs on a violet night, squared type.
        family("Neon City",
               light: Seed(ground: "#F1ECFA", content: "#F7F3FD", surface: "#FFFFFF", text: "#1B0F33",
                           accent: "#D4127F", accentText: "#FFFFFF", branch: "#097889", danger: "#D11A4A",
                           ok: "#0C7E5E", warn: "#9E5F09", info: "#5B3FD6"),
               dark: Seed(ground: "#0B0718", content: "#0F0A20", surface: "#16102B", text: "#EEE8FF",
                          accent: "#FF2E97", accentText: "#1A0412", branch: "#22E4F4", danger: "#FF4D6D",
                          ok: "#39F5B0", warn: "#FFD23F", info: "#9B7BFF"),
               design: ThemeDesign(radius: 3, letterSpacing: 0.01, fontSans: "Chakra Petch, sans-serif",
                                   fontMono: "Share Tech Mono, monospace", border: "#D9CDEF", input: "#C9B9E8"),
               darkDesign: ThemeDesign(radius: 3, letterSpacing: 0.01, fontSans: "Chakra Petch, sans-serif",
                                       fontMono: "Share Tech Mono, monospace", border: "#3A2468", input: "#4B2F85",
                                       shadow: soft("#FF2E97", 0.35, blur: 14, y: 0))),
        // Poster brutalism: black ink, one loud yellow, square corners, hard shadows.
        family("Brutal",
               light: Seed(ground: "#F4F1E8", content: "#FBF9F2", surface: "#FFFFFF", text: "#0A0A0A",
                           accent: "#FFD400", accentText: "#0A0A0A", branch: "#1438E0", danger: "#E01414",
                           ok: "#0B7A33", warn: "#B05800", info: "#1438E0"),
               dark: Seed(ground: "#0A0A0A", content: "#111111", surface: "#181818", text: "#F7F4EA",
                          accent: "#FFD400", accentText: "#0A0A0A", branch: "#7C9BFF", danger: "#FF5A4D",
                          ok: "#5BE584", warn: "#FFB23E", info: "#7C9BFF"),
               design: ThemeDesign(radius: 0, fontSans: "Space Grotesk, sans-serif",
                                   fontMono: "Space Mono, monospace", border: "#0A0A0A", input: "#0A0A0A",
                                   shadow: hard("#0A0A0A", 4)),
               darkDesign: ThemeDesign(radius: 0, fontSans: "Space Grotesk, sans-serif",
                                       fontMono: "Space Mono, monospace", border: "#F7F4EA", input: "#F7F4EA",
                                       shadow: hard("#FFD400", 4))),
        // 1990s mall at dusk: pink, teal, lilac, round and airy.
        family("Vaporwave",
               light: Seed(ground: "#FDEFFA", content: "#FFF6FD", surface: "#FFFFFF", text: "#3A1E5C",
                           accent: "#C53E8B", accentText: "#FFFFFF", branch: "#0A7D7D", danger: "#D22E59",
                           ok: "#0F7E5F", warn: "#A5600E", info: "#7B4FD9"),
               dark: Seed(ground: "#1A1033", content: "#1F143D", surface: "#2A1B50", text: "#FCE9FF",
                          accent: "#FF71CE", accentText: "#2B0A2E", branch: "#01CDFE", danger: "#FF6B8B",
                          ok: "#05FFA1", warn: "#FFFB96", info: "#B967FF"),
               design: ThemeDesign(radius: 16, spacing: 4.3, fontSans: "Quicksand, sans-serif",
                                   fontMono: "Fira Code, monospace")),
        // A phosphor screen: green on black, one typeface for everything.
        family("Phosphor",
               light: Seed(ground: "#E9F2E6", content: "#F1F7EE", surface: "#FAFDF8", text: "#0C2A12",
                           accent: "#0F7A2A", accentText: "#F1FFF2", branch: "#0B6E63", danger: "#B3261E",
                           ok: "#0F7A2A", warn: "#8A6100", info: "#205C99"),
               dark: Seed(ground: "#020A04", content: "#030D05", surface: "#07140A", text: "#B6FFC1",
                          accent: "#33FF66", accentText: "#02150A", branch: "#2CF5C8", danger: "#FF5F56",
                          ok: "#33FF66", warn: "#F5E663", info: "#6FD3FF"),
               design: ThemeDesign(radius: 0, fontSans: "IBM Plex Mono, monospace",
                                   fontMono: "IBM Plex Mono, monospace", border: "#9CC6A2", input: "#7FB487"),
               darkDesign: ThemeDesign(radius: 0, fontSans: "IBM Plex Mono, monospace",
                                       fontMono: "IBM Plex Mono, monospace", border: "#145A26", input: "#1B7A33",
                                       shadow: soft("#33FF66", 0.25, blur: 12, y: 0))),
        // A hot evening: orange into red over deep plum.
        family("Blaze",
               light: Seed(ground: "#FFF1E6", content: "#FFF7F0", surface: "#FFFFFF", text: "#3B1206",
                           accent: "#D33C0A", accentText: "#FFFFFF", branch: "#B5179E", danger: "#C81D25",
                           ok: "#287F39", warn: "#AD5A00", info: "#7048E8"),
               dark: Seed(ground: "#1A0B12", content: "#1F0D16", surface: "#2A121D", text: "#FFE8D6",
                          accent: "#FF6B2C", accentText: "#2A0A00", branch: "#FF4FA3", danger: "#FF4D4D",
                          ok: "#7CE38B", warn: "#FFC145", info: "#B197FC"),
               design: ThemeDesign(radius: 14, fontSans: "Outfit, sans-serif",
                                   fontMono: "JetBrains Mono, monospace",
                                   shadow: soft("#F0440B", 0.22, blur: 18, y: 6))),
        // Dessau, 1925: red, blue, yellow on cream; geometry and nothing else.
        family("Bauhaus",
               light: Seed(ground: "#F2EBDD", content: "#F8F3E8", surface: "#FFFDF7", text: "#161616",
                           accent: "#D62A1E", accentText: "#FFFFFF", branch: "#1F4FBF", danger: "#B3180E",
                           ok: "#2C7A3F", warn: "#906600", info: "#1F4FBF"),
               dark: Seed(ground: "#161616", content: "#1B1B1B", surface: "#232323", text: "#F2EBDD",
                          accent: "#F04A3A", accentText: "#1A0503", branch: "#6C93F5", danger: "#FF6B5E",
                          ok: "#7BD18C", warn: "#F5C518", info: "#6C93F5"),
               design: ThemeDesign(radius: 0, letterSpacing: 0.02, fontSans: "Jost, sans-serif",
                                   fontMono: "DM Mono, monospace", border: "#161616", input: "#161616"),
               darkDesign: ThemeDesign(radius: 0, letterSpacing: 0.02, fontSans: "Jost, sans-serif",
                                       fontMono: "DM Mono, monospace", border: "#F2EBDD", input: "#F2EBDD")),
        // 1984 on a grid: hot pink and sun yellow over midnight blue.
        family("Outrun",
               light: Seed(ground: "#F3EEFB", content: "#F9F5FE", surface: "#FFFFFF", text: "#241B4B",
                           accent: "#C21E8C", accentText: "#FFFFFF", branch: "#0D779E", danger: "#D02B4E",
                           ok: "#147C62", warn: "#9A6200", info: "#5746D9"),
               dark: Seed(ground: "#1A1630", content: "#201B3B", surface: "#2A2350", text: "#F4F0FF",
                          accent: "#FF7EDB", accentText: "#2B0730", branch: "#36F9F6", danger: "#FE4450",
                          ok: "#72F1B8", warn: "#FEDE5D", info: "#B893FF"),
               design: ThemeDesign(radius: 6, fontSans: "Exo 2, sans-serif", fontMono: "Fira Code, monospace",
                                   shadow: soft("#C21E8C", 0.25, blur: 16, y: 4))),
        // A sweet shop: pink, round, soft.
        family("Candy",
               light: Seed(ground: "#FFEAF2", content: "#FFF3F8", surface: "#FFFFFF", text: "#4A1230",
                           accent: "#D33170", accentText: "#FFFFFF", branch: "#8A3FE0", danger: "#D3253C",
                           ok: "#187E5A", warn: "#A75B00", info: "#286DC8"),
               dark: Seed(ground: "#2A0E1F", content: "#311125", surface: "#3D1730", text: "#FFE4F0",
                          accent: "#FF6FAE", accentText: "#33061C", branch: "#C99BFF", danger: "#FF6B7A",
                          ok: "#6FE8B9", warn: "#FFCB6B", info: "#7DB8FF"),
               design: ThemeDesign(radius: 22, spacing: 4.4, fontSans: "Fredoka, sans-serif",
                                   fontMono: "Fira Code, monospace",
                                   shadow: soft("#F0387F", 0.2, blur: 14, y: 5))),
        // A drawing office: white lines on blueprint blue, condensed lettering.
        family("Blueprint",
               light: Seed(ground: "#E8F0FB", content: "#F0F5FD", surface: "#FFFFFF", text: "#0B2A5B",
                           accent: "#0B5FD9", accentText: "#FFFFFF", branch: "#0A7A89", danger: "#C2281F",
                           ok: "#1C7C4A", warn: "#976200", info: "#0B5FD9"),
               dark: Seed(ground: "#0A2A5E", content: "#0C316C", surface: "#113A7C", text: "#EAF2FF",
                          accent: "#FFFFFF", accentText: "#0A2A5E", branch: "#7FE3F0", danger: "#FF8A80",
                          ok: "#8CF0B4", warn: "#FFE082", info: "#9CC4FF"),
               design: ThemeDesign(radius: 0, letterSpacing: 0.02, fontSans: "Barlow, sans-serif",
                                   fontMono: "JetBrains Mono, monospace", border: "#9DB8E3", input: "#7FA2D8"),
               darkDesign: ThemeDesign(radius: 0, letterSpacing: 0.02, fontSans: "Barlow, sans-serif",
                                       fontMono: "JetBrains Mono, monospace", border: "#5F8FD6",
                                       input: "#7AA5E3")),
        // A theatre box: deep purple and gold, a display serif.
        family("Velvet",
               light: Seed(ground: "#F5EFE3", content: "#FAF6EC", surface: "#FFFDF8", text: "#2B1338",
                           accent: "#7A2E9E", accentText: "#FFFFFF", branch: "#946700", danger: "#B3261E",
                           ok: "#2E7D4F", warn: "#946700", info: "#4B4FC4"),
               dark: Seed(ground: "#170B20", content: "#1C0E27", surface: "#261433", text: "#F3E7D0",
                          accent: "#E3B341", accentText: "#221500", branch: "#C792EA", danger: "#FF6B6B",
                          ok: "#8FD9A8", warn: "#E3B341", info: "#9FA8FF"),
               design: ThemeDesign(radius: 6, letterSpacing: 0.01, fontSans: "Playfair Display, serif",
                                   fontMono: "Courier Prime, monospace",
                                   shadow: soft("#170B20", 0.3, blur: 20, y: 8))),
    ]

    // MARK: Comfort

    static let comfort: [ThemeFamily] = [
        // Warm paper and sepia ink; a typeface drawn for legibility.
        family("Paper",
               light: Seed(ground: "#EFE8D8", content: "#F5EFE1", surface: "#FAF6EB", text: "#3A3226",
                           accent: "#9A5B2E", accentText: "#FFF8EC", branch: "#3F7068", danger: "#A8443A",
                           ok: "#4C7542", warn: "#86641D", info: "#4A6A91"),
               dark: Seed(ground: "#211D18", content: "#26211B", surface: "#2D2720", text: "#D9CFBC",
                          accent: "#C9976B", accentText: "#2A1A0C", branch: "#8DB5AC", danger: "#D08A80",
                          ok: "#9DBE8E", warn: "#D2B36E", info: "#93AFCF"),
               design: ThemeDesign(radius: 8, spacing: 4.4, letterSpacing: 0.01,
                                   fontSans: "Atkinson Hyperlegible, sans-serif",
                                   fontMono: "JetBrains Mono, monospace")),
        // Evening light: warm, dim, no blue to keep you up.
        family("Dusk",
               light: Seed(ground: "#EDE4DA", content: "#F3EBE2", surface: "#F9F3EC", text: "#3B2F2A",
                           accent: "#A55C3A", accentText: "#FFF6EF", branch: "#786839", danger: "#A9473F",
                           ok: "#557046", warn: "#846325", info: "#706284"),
               dark: Seed(ground: "#1E1917", content: "#231D1A", surface: "#2B2420", text: "#D8C9BC",
                          accent: "#D99A6C", accentText: "#2B1608", branch: "#C2B280", danger: "#D48C7F",
                          ok: "#A3BF8F", warn: "#D9B777", info: "#BBA7C7"),
               design: ThemeDesign(radius: 10, spacing: 4.4, fontSans: "Lexend, sans-serif",
                                   fontMono: "Fira Code, monospace")),
        // Grey-green, like a study with the blinds half down.
        family("Sage",
               light: Seed(ground: "#E6EBE3", content: "#EDF1EA", surface: "#F5F8F2", text: "#2C362E",
                           accent: "#4E7A5C", accentText: "#F4FBF5", branch: "#3D7377", danger: "#A64B45",
                           ok: "#4B7558", warn: "#806828", info: "#4F6C94"),
               dark: Seed(ground: "#1A1F1B", content: "#1E241F", surface: "#252C26", text: "#CBD6CC",
                          accent: "#8FBF9F", accentText: "#102015", branch: "#86BFC2", danger: "#D49088",
                          ok: "#8FBF9F", warn: "#CDB878", info: "#98B4D8"),
               design: ThemeDesign(radius: 9, spacing: 4.3, fontSans: "Source Sans 3, sans-serif",
                                   fontMono: "Source Code Pro, monospace")),
        // Greys only, as on an e-reader: nothing glows, nothing shouts.
        family("E-Ink",
               light: Seed(ground: "#E4E4E0", content: "#ECECE8", surface: "#F4F4F0", text: "#2A2A28",
                           accent: "#3F3F3C", accentText: "#F4F4F0", branch: "#4C5A5A", danger: "#8C3B33",
                           ok: "#44603F", warn: "#7A6427", info: "#44567A"),
               dark: Seed(ground: "#1C1C1B", content: "#212120", surface: "#282827", text: "#CFCFCA",
                          accent: "#BDBDB6", accentText: "#1C1C1B", branch: "#A8B8B8", danger: "#CF938B",
                          ok: "#A9C3A2", warn: "#CDBB84", info: "#A4B4D2"),
               design: ThemeDesign(radius: 4, spacing: 4.3, letterSpacing: 0.005,
                                   fontSans: "IBM Plex Sans, sans-serif",
                                   fontMono: "IBM Plex Mono, monospace")),
        // A dimmed navy night with pastel ink, for the late hours.
        family("Night Shift",
               light: Seed(ground: "#E7EAF1", content: "#EEF1F6", surface: "#F6F8FB", text: "#2A3142",
                           accent: "#5468A8", accentText: "#F5F7FF", branch: "#3C757B", danger: "#A74B55",
                           ok: "#48765E", warn: "#846729", info: "#5468A8"),
               dark: Seed(ground: "#171B26", content: "#1B1F2B", surface: "#222838", text: "#C8CFE0",
                          accent: "#9DB0E8", accentText: "#131A2E", branch: "#8CC5C9", danger: "#D7929B",
                          ok: "#98C7AE", warn: "#D3BB82", info: "#9DB0E8"),
               design: ThemeDesign(radius: 10, spacing: 4.4, fontSans: "Nunito Sans, sans-serif",
                                   fontMono: "JetBrains Mono, monospace")),
    ]
}
