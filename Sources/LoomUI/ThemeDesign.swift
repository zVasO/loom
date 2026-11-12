import Foundation

/// What a theme says beyond its colours: the geometry, the type and the
/// edges a shadcn theme (tweakcn) carries — its `--radius`, `--spacing`,
/// `--letter-spacing`, `--font-*`, `--border`, `--input` and `--shadow-*` —
/// kept as the theme wrote them and followed to the letter by the app
/// (ADR-0022). Every field is optional: nil is the charter's own value
/// (docs/design/charte.md), so a family without a design — every built-in —
/// draws exactly as it always did. A variant has its own design: tweakcn
/// writes these variables in both blocks.
public struct ThemeDesign: Codable, Equatable, Sendable, Hashable {
    /// `--radius`, in points (1rem = 16).
    public var radius: Double?
    /// `--spacing`, in points — Tailwind's unit, 4 (0.25rem) unless the theme says otherwise.
    public var spacing: Double?
    /// `--letter-spacing` (`--tracking-normal`), in em.
    public var letterSpacing: Double?
    /// CSS font stacks, as written (`Inter, sans-serif`).
    public var fontSans: String?
    public var fontSerif: String?
    public var fontMono: String?
    /// `--border`, `#RRGGBB`: the colour every edge is drawn with, as is.
    /// nil keeps the charter's hairline (the text colour at 8 %).
    public var border: String?
    /// `--input`, `#RRGGBB`: the edge of fields and outlined controls.
    public var input: String?
    /// `--shadow-*`: the six parameters every shadow level is made from.
    public var shadow: ThemeShadow?

    public init(radius: Double? = nil, spacing: Double? = nil, letterSpacing: Double? = nil,
                fontSans: String? = nil, fontSerif: String? = nil, fontMono: String? = nil,
                border: String? = nil, input: String? = nil, shadow: ThemeShadow? = nil) {
        self.radius = radius
        self.spacing = spacing
        self.letterSpacing = letterSpacing
        self.fontSans = fontSans
        self.fontSerif = fontSerif
        self.fontMono = fontMono
        self.border = border
        self.input = input
        self.shadow = shadow
    }

    public var isEmpty: Bool { self == ThemeDesign() }

    /// The part of a design that is colour: its edges. What a family set
    /// to "colours only" still follows; nil when the design has no edge.
    public var colors: ThemeDesign? {
        let kept = ThemeDesign(border: border, input: input)
        return kept.isEmpty ? nil : kept
    }

    // MARK: Geometry — pure, the charter's value in, the theme's out

    /// Tailwind's spacing unit in points: what the charter's lengths are
    /// measured against.
    public static let charterSpacing = 4.0

    /// A corner radius of the charter (10 a card, 8 a panel, 6 a control,
    /// 4 a tab or a key, 3 a tag) on the scale tweakcn exports and
    /// previews with: a card is shadcn's Card, `rounded-xl` (`--radius` + 4
    /// — 4 even for a square theme, as on tweakcn); 8 is `rounded-lg`
    /// (`--radius`); a control is `rounded-md` (`--radius` − 2); a tab or a
    /// key `rounded-sm` (`--radius` − 4); a tag is a Badge, `rounded-full`
    /// whatever the radius. Anything else keeps its distance to the nearest
    /// of those. Never negative: CSS clamps `calc(0rem - 4px)` to 0.
    public func radius(_ charter: Double) -> Double {
        guard let radius, radius >= 0, charter > 0 else { return charter }
        if charter <= 3 { return Self.pill }
        let themed = charter >= 9 ? radius + 4 + (charter - 10) : radius - 2 + (charter - 6)
        return max(0, themed)
    }

    /// `rounded-full`: a radius no shape is tall enough for — the shape
    /// rounds to half its height.
    public static let pill = 999.0

    /// A length of the charter — a padding, a gap, a control's height — in
    /// the theme's `--spacing`: every Tailwind spacing utility is
    /// `calc(var(--spacing) * n)`, so the whole layout scales with it. On
    /// the half-point grid, like the charter's own values.
    public func space(_ charter: Double) -> Double {
        guard let spacing, spacing > 0, spacing != Self.charterSpacing else { return charter }
        return (charter * spacing / Self.charterSpacing * 2).rounded() / 2
    }

    /// The letter-spacing of every text, in points. tweakcn writes
    /// `letter-spacing: var(--tracking-normal)` on `body`: CSS resolves the
    /// em against the body's own 16 px and hands that length down, the same
    /// for every text whatever its size.
    public var tracking: Double { (letterSpacing ?? 0) * 16 }
}

/// A theme's shadow, as tweakcn's six controls set it. The levels shadcn's
/// components ask for (`shadow-xs` a button, `shadow-sm` a card…) are all
/// made from these, exactly as tweakcn composes `--shadow-2xs … --shadow-2xl`.
public struct ThemeShadow: Codable, Equatable, Sendable, Hashable {
    /// `--shadow-color`, `#RRGGBB`.
    public var color: String
    /// `--shadow-opacity`, 0…1.
    public var opacity: Double
    /// `--shadow-blur`, `--shadow-spread`, `--shadow-offset-x`, `--shadow-offset-y`, in points.
    public var blur: Double
    public var spread: Double
    public var x: Double
    public var y: Double

    public init(color: String, opacity: Double, blur: Double, spread: Double, x: Double, y: Double) {
        self.color = color
        self.opacity = opacity
        self.blur = blur
        self.spread = spread
        self.x = x
        self.y = y
    }

    /// The levels of Tailwind's shadow scale.
    public enum Level: String, Sendable, CaseIterable {
        case xxs = "2xs", xs, sm, md, lg, xl, xxl = "2xl"
    }

    /// One box-shadow of a level: CSS's `x y blur spread colour`.
    public struct Layer: Equatable, Sendable {
        public let color: String
        public let opacity: Double
        public let blur: Double
        public let spread: Double
        public let x: Double
        public let y: Double
    }

    /// The box-shadows of a level, first on top — tweakcn's own composition:
    /// the theme's shadow at half its opacity for the two smallest levels,
    /// at full opacity with a second, tighter layer for the middle ones,
    /// and alone at 2.5 times its opacity for the largest.
    public func layers(_ level: Level) -> [Layer] {
        func first(_ multiplier: Double) -> Layer {
            Layer(color: color, opacity: min(1, max(0, opacity * multiplier)),
                  blur: blur, spread: spread, x: x, y: y)
        }
        func second(y fixedY: Double, blur fixedBlur: Double) -> Layer {
            Layer(color: color, opacity: min(1, max(0, opacity)),
                  blur: fixedBlur, spread: spread - 1, x: x, y: fixedY)
        }
        switch level {
        case .xxs, .xs: return [first(0.5)]
        case .sm: return [first(1), second(y: 1, blur: 2)]
        case .md: return [first(1), second(y: 2, blur: 4)]
        case .lg: return [first(1), second(y: 4, blur: 6)]
        case .xl: return [first(1), second(y: 8, blur: 10)]
        case .xxl: return [first(2.5)]
        }
    }

    /// Nothing to draw: a shadow without opacity.
    public var isInvisible: Bool { opacity <= 0 }
}

// MARK: - CSS lengths

/// The lengths a shadcn theme writes: `0.625rem`, `10px`, `0`, `-0.025em`.
public enum CSSLength {

    /// A length in points: `rem` and `em` count 16, `px` (or no unit) 1.
    /// nil for what is not a plain length (`calc(…)`, `auto`).
    public static func points(_ text: String) -> Double? {
        guard let (value, unit) = split(text) else { return nil }
        switch unit {
        case "", "px", "pt": return value
        case "rem", "em": return value * 16
        default: return nil
        }
    }

    /// A letter-spacing in em: `em` as is, `rem` the same (the root size is
    /// the text's), `px` over 16; `normal` is none.
    public static func em(_ text: String) -> Double? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "normal" { return 0 }
        guard let (value, unit) = split(text) else { return nil }
        switch unit {
        case "em", "rem": return value
        case "": return value == 0 ? 0 : nil
        case "px", "pt": return value / 16
        default: return nil
        }
    }

    /// A unitless number (`--shadow-opacity: 0.1`), or a percentage as a fraction.
    public static func number(_ text: String) -> Double? {
        guard let (value, unit) = split(text) else { return nil }
        switch unit {
        case "": return value
        case "%": return value / 100
        default: return nil
        }
    }

    /// `"-0.5rem"` → (-0.5, "rem"). nil when the text is not a number and a unit.
    private static func split(_ text: String) -> (Double, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let unitStart = trimmed.firstIndex { !($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }
            ?? trimmed.endIndex
        var digits = String(trimmed[..<unitStart])
        let unit = String(trimmed[unitStart...])
        guard unit.allSatisfy({ $0.isLetter || $0 == "%" }) else { return nil }
        // CSS allows ".5"; Double does not read "-.5" everywhere the same way.
        if digits.hasPrefix(".") { digits = "0" + digits }
        if digits.hasPrefix("-.") { digits = "-0" + digits.dropFirst() }
        if digits.hasPrefix("+") { digits.removeFirst() }
        guard let value = Double(digits), value.isFinite else { return nil }
        return (value, unit)
    }
}

// MARK: - CSS font stacks

/// A CSS `font-family` value read the way a browser does: named families
/// in order, down to the first generic keyword.
public enum FontStack {

    /// The system faces a generic keyword stands for.
    public enum Generic: String, Sendable, Equatable {
        case sans, serif, mono, rounded
    }

    public enum Entry: Sendable, Equatable {
        case family(String)
        case generic(Generic)
    }

    /// `"Geist Mono", ui-monospace, monospace` → Geist Mono, mono, mono.
    /// Quotes and spaces are dropped; keywords that name no face of ours
    /// (`cursive`, `emoji`…) are skipped.
    public static func parse(_ css: String) -> [Entry] {
        var entries: [Entry] = []
        var current = ""
        var quote: Character?
        func flush() {
            let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !name.isEmpty else { return }
            let key = name.lowercased()
            if let generic = generics[key] {
                entries.append(.generic(generic))
            } else if !ignored.contains(key) {
                entries.append(.family(name))
            }
        }
        for character in css {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return entries
    }

    /// The named families a browser would try before settling on a system
    /// face: everything ahead of the first generic keyword.
    public static func namedFamilies(_ css: String) -> [String] {
        var names: [String] = []
        for entry in parse(css) {
            guard case .family(let name) = entry else { break }
            names.append(name)
        }
        return names
    }

    /// CSS's generic families, and the names browsers treat as the system's
    /// own faces on a Mac.
    private static let generics: [String: Generic] = [
        "sans-serif": .sans, "ui-sans-serif": .sans, "system-ui": .sans,
        "-apple-system": .sans, "blinkmacsystemfont": .sans,
        "sf pro": .sans, "sf pro text": .sans, "sf pro display": .sans, "san francisco": .sans,
        "serif": .serif, "ui-serif": .serif, "new york": .serif,
        "monospace": .mono, "ui-monospace": .mono, "sf mono": .mono, "sfmono-regular": .mono,
        "ui-rounded": .rounded, "sf pro rounded": .rounded,
    ]

    private static let ignored: Set<String> = [
        "cursive", "fantasy", "emoji", "math", "fangsong", "inherit", "initial", "unset",
    ]
}
