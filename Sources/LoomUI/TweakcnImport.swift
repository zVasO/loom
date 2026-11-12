import Foundation

/// A tweakcn (shadcn/ui) theme read into a Loom family. tweakcn hands out
/// two things: the "Code" export — CSS with a `:root` block and a `.dark`
/// block of `--variables` — and a registry JSON (`cssVars.light` /
/// `cssVars.dark`). Both carry some thirty colours in oklch, hsl or hex,
/// projected onto Loom's 16 tokens, and the theme's design — `--radius`,
/// `--spacing`, `--letter-spacing`, `--font-*`, `--shadow-*`, the exact
/// `--border` and `--input` — kept as written on each variant (ADR-0022).
/// Pure: the network calls live in the store.
public enum TweakcnImport {

    public enum ImportError: Error, LocalizedError, Equatable {
        case noVariables
        case notARegistry
        case badURL(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .noVariables: "No `--variable` was found — paste tweakcn's Code export (:root { … } .dark { … })."
            case .notARegistry: "This is not a tweakcn registry file (no cssVars)."
            case .badURL(let text): "“\(text)” is neither a tweakcn theme name nor a tweakcn URL."
            case .notFound(let url): "tweakcn has no theme at \(url)."
            }
        }
    }

    public typealias Variables = [String: String]

    // MARK: CSS text — the "Code" export

    /// The `--name: value` pairs of the light block (`:root`) and the dark one
    /// (`.dark`, `[data-theme="dark"]`…). A file with a single block yields
    /// it for both; no block at all is an error.
    public static func parseCSS(_ text: String) throws -> (light: Variables, dark: Variables) {
        let stripped = stripComments(text)
        var light: Variables = [:]
        var dark: Variables = [:]
        var loose: Variables = [:]
        for block in blocks(of: stripped) {
            let selector = block.selector.lowercased()
            let vars = variables(in: block.body)
            guard !vars.isEmpty else { continue }
            if selector.contains("dark") {
                dark.merge(vars) { _, new in new }
            } else if selector.contains(":root") || selector.contains("light") || selector == "html"
                        || selector == "body" {
                light.merge(vars) { _, new in new }
            } else {
                loose.merge(vars) { _, new in new }
            }
        }
        // Variables outside any block (a bare paste of the lines).
        if light.isEmpty && dark.isEmpty && loose.isEmpty {
            loose = variables(in: stripped)
        }
        if light.isEmpty { light = loose.isEmpty ? dark : loose }
        if dark.isEmpty { dark = light }
        guard !light.isEmpty else { throw ImportError.noVariables }
        return (light, dark)
    }

    private struct Block {
        let selector: String
        let body: String
    }

    /// Top-level `selector { body }` pairs; nested braces are kept inside
    /// the body (a `@media` wrapper is walked into).
    private static func blocks(of text: String) -> [Block] {
        var result: [Block] = []
        var selector = ""
        var body = ""
        var depth = 0
        for character in text {
            switch character {
            case "{":
                depth += 1
                if depth == 1 { body = "" } else { body.append(character) }
            case "}":
                depth -= 1
                if depth == 0 {
                    let name = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.hasPrefix("@") {
                        // @media (prefers-color-scheme: dark) { .dark { … } }: descend.
                        result += blocks(of: body).map { inner in
                            Block(selector: name.lowercased().contains("dark") && !inner.selector.lowercased().contains("dark")
                                  ? inner.selector + " dark" : inner.selector, body: inner.body)
                        }
                    } else {
                        result.append(Block(selector: name, body: body))
                    }
                    selector = ""
                    body = ""
                } else if depth > 0 {
                    body.append(character)
                }
            case ";" where depth == 0:
                // `@import "tailwindcss";`, `@custom-variant dark (…);`: a
                // statement of its own, not the start of the next selector.
                selector = ""
            default:
                if depth == 0 { selector.append(character) } else { body.append(character) }
            }
        }
        return result
    }

    /// `--name: value;` pairs. The value runs to the `;` or the end of line.
    static func variables(in body: String) -> Variables {
        var result: Variables = [:]
        for statement in body.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            let trimmed = statement.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    private static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "/*") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { return result }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    // MARK: Registry JSON — https://tweakcn.com/r/themes/<name>.json

    /// The registry item: `name` (or `title`) and `cssVars.light` / `.dark`.
    public static func parseRegistry(_ data: Data) throws -> (name: String, light: Variables, dark: Variables) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cssVars = object["cssVars"] as? [String: Any]
        else { throw ImportError.notARegistry }
        func vars(_ key: String) -> Variables {
            (cssVars[key] as? [String: Any] ?? [:]).reduce(into: [:]) { result, pair in
                if let value = pair.value as? String { result[pair.key] = value }
                else if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
            }
        }
        var light = vars("light")
        var dark = vars("dark")
        if light.isEmpty { light = dark }
        if dark.isEmpty { dark = light }
        guard !light.isEmpty else { throw ImportError.noVariables }
        // `theme` holds what both variants share — fonts, radius — kept
        // under each, the variant's own value winning.
        let shared = vars("theme")
        light = shared.merging(light) { $1 }
        dark = shared.merging(dark) { $1 }
        let name = (object["title"] as? String) ?? (object["name"] as? String) ?? "Imported theme"
        return (name, light, dark)
    }

    /// Where a theme's registry file lives, from what the user pasted: the
    /// registry URL itself, the editor's URL (`tweakcn.com/themes/<name>`,
    /// `tweakcn.com/editor/theme?theme=<name>`), or a bare name. Anything
    /// else is refused rather than guessed. The first of `registryURLs`.
    public static func registryURL(for input: String) -> URL? {
        registryURLs(for: input).first
    }

    /// Every address the registry file may answer at, most likely first.
    /// Built-in themes live at `/r/themes/<name>.json`; community themes
    /// at `/r/themes/<id>` — no extension, still JSON. A pasted registry
    /// URL is tried exactly as given, then with the other spelling.
    public static func registryURLs(for input: String) -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.contains("://") || text.hasPrefix("tweakcn.com") || text.hasPrefix("www.tweakcn.com") {
            guard let url = URL(string: text.contains("://") ? text : "https://" + text),
                  url.host?.hasSuffix("tweakcn.com") == true else { return [] }
            let parts = url.path.split(separator: "/").map(String.init)
            // /r/themes/<slug>[.json] — the registry itself.
            if parts.count >= 3, parts[0] == "r", parts[1] == "themes" {
                return registry(parts[2], keepCase: true, asGiven: true)
            }
            // The editor: ?theme=<slug>.
            if let theme = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "theme" })?.value, !theme.isEmpty {
                return registry(theme, keepCase: true)
            }
            // /themes/<slug> — a theme's page, built-in or community.
            if let name = parts.last, !name.isEmpty, name != "themes", name != "editor", name != "theme" {
                return registry(name, keepCase: true)
            }
            return []
        }
        guard !text.contains(where: \.isWhitespace), !text.contains("/") else { return [] }
        return registry(text, keepCase: false)
    }

    /// `<slug>.json` and `<slug>` — the given spelling first for a pasted
    /// registry URL, the built-ins' `.json` first otherwise. A typed name is
    /// lowercased (`Modern-Minimal`); a slug read off a URL is kept as is —
    /// a community id is an identifier, not a name.
    private static func registry(_ name: String, keepCase: Bool, asGiven: Bool = false) -> [URL] {
        let hasExtension = name.lowercased().hasSuffix(".json")
        let bare = hasExtension ? String(name.dropLast(5)) : name
        let slug = keepCase ? bare : bare.lowercased()
        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return [] }
        let withExtension = URL(string: "https://tweakcn.com/r/themes/\(slug).json")
        let without = URL(string: "https://tweakcn.com/r/themes/\(slug)")
        // A pasted registry URL without the extension is tried as given first.
        let ordered = asGiven && !hasExtension ? [without, withExtension] : [withExtension, without]
        return ordered.compactMap { $0 }
    }

    /// The name a fetched theme takes: its registry title or name,
    /// prettified, else the URL's. A community theme's id (`cmqx9le2j…`)
    /// names nothing: "Community theme" instead.
    public static func displayName(_ registryName: String, url: URL) -> String {
        let candidate = registryName == "Imported theme" ? themeName(from: url) : prettify(registryName)
        return looksLikeID(candidate) ? "Community theme" : candidate
    }

    /// A generated identifier rather than a name: long, one word, letters
    /// and digits mixed.
    static func looksLikeID(_ text: String) -> Bool {
        text.count >= 16 && !text.contains(" ") && !text.contains("-")
            && text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }

    /// The name the registry URL implies — for a file downloaded by name.
    public static func themeName(from url: URL) -> String {
        prettify(url.deletingPathExtension().lastPathComponent)
    }

    /// `modern-minimal` → `Modern Minimal`; a name already spelled out stays.
    public static func prettify(_ name: String) -> String {
        guard !name.contains(" "), name == name.lowercased() else { return name }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word -> String in word.prefix(1).uppercased() + String(word.dropFirst()) }
            .joined(separator: " ")
    }

    // MARK: Projection onto Loom's tokens

    /// shadcn's variables → Loom's 16 tokens. A variable that is missing, or
    /// that does not parse as a colour, falls back to Loom's own variant:
    /// never a hole. The four state colours keep Loom's semantics (THM-08):
    /// shadcn has no "success" green, and a theme must not make failed green.
    public static func tokens(from vars: Variables, dark: Bool) -> ThemeTokens {
        let vars = resolvingReferences(vars)
        let base = dark ? ThemeFamily.loom.dark : ThemeFamily.loom.light
        // A translucent colour (shadcn's own dark `--border` is white at
        // 10 %) is what it looks like on the page: laid over the background.
        var backdrop = dark ? "#000000" : "#FFFFFF"
        func color(_ names: String..., fallback: String) -> String {
            for name in names {
                if let value = vars[name], let hex = CSSColor.opaque(value, over: backdrop) { return hex }
            }
            return fallback
        }
        let background = color("background", fallback: base.contentBackground)
        backdrop = background
        let mutedForeground = color("muted-foreground", fallback: base.secondaryText)
        let accent = color("primary", fallback: base.accent)
        return ThemeTokens(
            background: color("sidebar", "background", fallback: base.background),
            contentBackground: background,
            surface: color("card", "popover", fallback: base.surface),
            // `--muted` first: it sits on the background's side, where
            // `--secondary` can be a high-contrast chip (a light one in a
            // dark variant).
            surfaceRaised: color("muted", "accent", "secondary", fallback: base.surfaceRaised),
            cardBorder: color("border", "input", fallback: base.cardBorder),
            accent: accent,
            accentText: color("primary-foreground", fallback: base.accentText),
            primaryText: color("foreground", fallback: base.primaryText),
            secondaryText: mutedForeground,
            mutedText: ThemeTokens.mix(mutedForeground, with: background, amount: 0.4),
            branch: color("chart-2", "ring", fallback: accent),
            danger: color("destructive", fallback: base.danger),
            groupHeader: base.groupHeader,
            stateWorking: base.stateWorking,
            stateNeedsInput: base.stateNeedsInput,
            stateIdle: base.stateIdle)
    }

    /// `var(--name)` (and `var(--name, fallback)`) replaced by the value it
    /// points at, nested ones included: community themes alias their
    /// variables (`--sidebar: var(--background)`), and an unresolved alias
    /// silently fell back to Loom's colours.
    static func resolvingReferences(_ vars: Variables) -> Variables {
        var resolved = vars
        for _ in 0..<6 {
            var changed = false
            for (name, value) in resolved where value.contains("var(") {
                let substituted = substitute(value, in: resolved)
                if substituted != value {
                    resolved[name] = substituted
                    changed = true
                }
            }
            if !changed { break }
        }
        return resolved
    }

    private static func substitute(_ value: String, in vars: Variables) -> String {
        var result = ""
        var rest = value[...]
        while let open = rest.range(of: "var(") {
            result += rest[..<open.lowerBound]
            // The matching ")" — a fallback may hold parentheses of its own.
            var depth = 1
            var index = open.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                if depth > 0 { index = rest.index(after: index) }
            }
            guard index < rest.endIndex else { return value }
            let inside = rest[open.upperBound..<index]
            let pieces = inside.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let name = pieces.first.map { $0.hasPrefix("--") ? String($0.dropFirst(2)) : $0 } ?? ""
            if let target = vars[name], !target.contains("var(--\(name)") {
                result += target
            } else if pieces.count > 1 {
                result += pieces[1]
            } else {
                // Unknown and no fallback: left for the next pass, or unparsed.
                result += rest[open.lowerBound...index]
            }
            rest = rest[rest.index(after: index)...]
        }
        return result + rest
    }

    /// A family from the two variable sets: each variant's colours and its
    /// design. The values tweakcn shares between the two modes — fonts,
    /// radius, spacing, letter-spacing, the shadow's geometry and opacity —
    /// are the light variant's in both: its own rule (`COMMON_STYLES`), what
    /// its preview shows, and why `--spacing` and `--tracking-normal` are
    /// only written in `:root`. A dark block that disagrees does not win.
    public static func family(named name: String, light: Variables, dark: Variables) -> ThemeFamily {
        var lightTokens = tokens(from: light, dark: false)
        var darkTokens = tokens(from: dark, dark: true)
        lightTokens.design = design(from: light, background: lightTokens.contentBackground)
        darkTokens.design = design(from: dark, sharedWith: light, background: darkTokens.contentBackground)
        return ThemeFamily(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           light: lightTokens, dark: darkTokens,
                           document: document(from: light))
    }

    /// The design a variant's variables carry: nil when they carry none.
    /// `light` is the set the values shared between modes are read from
    /// first (for the dark variant); the edges and the shadow's colour are
    /// the variant's own.
    static func design(from vars: Variables, sharedWith light: Variables? = nil,
                       background: String) -> ThemeDesign? {
        let own = resolvingReferences(vars)
        let common = light.map(resolvingReferences) ?? own
        func value(_ names: [String], in sources: [Variables]) -> String? {
            for source in sources {
                for name in names {
                    guard let text = source[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { continue }
                    return text
                }
            }
            return nil
        }
        func shared(_ names: String...) -> String? { value(names, in: [common, own]) }
        func mine(_ names: String...) -> String? { value(names, in: [own, common]) }

        var design = ThemeDesign()
        design.radius = shared("radius").flatMap(CSSLength.points).flatMap { $0 >= 0 ? $0 : nil }
        // tweakcn's slider runs from 0.15 to 0.35rem; a value far outside
        // (a hand-written `1rem`) would take the layout apart.
        design.spacing = shared("spacing").flatMap(CSSLength.points)
            .flatMap { $0 > 0 ? min(max($0, 2), 8) : nil }
        // `--tracking-normal` in the CSS export, `letter-spacing` in the registry.
        design.letterSpacing = shared("tracking-normal", "letter-spacing").flatMap(CSSLength.em)
            .flatMap { $0 == 0 ? nil : $0 }
        design.fontSans = shared("font-sans")
        design.fontSerif = shared("font-serif")
        design.fontMono = shared("font-mono")
        design.border = own["border"].flatMap { CSSColor.opaque($0, over: background) }
        design.input = own["input"].flatMap { CSSColor.opaque($0, over: background) }

        // The shadow: its six parameters (`--shadow-x`/`-y` in the CSS
        // export, `shadow-offset-x`/`-y` in the registry), the ones left
        // out being tweakcn's defaults; or, from an export that only has the
        // composed shadows (before autumn 2025), the first layer of `--shadow-sm`.
        let color = mine("shadow-color").flatMap(CSSColor.parse)
        let opacity = shared("shadow-opacity").flatMap(CSSLength.number)
        let blur = shared("shadow-blur").flatMap(CSSLength.points)
        let spread = shared("shadow-spread").flatMap(CSSLength.points)
        let x = shared("shadow-x", "shadow-offset-x").flatMap(CSSLength.points)
        let y = shared("shadow-y", "shadow-offset-y").flatMap(CSSLength.points)
        if color == nil, opacity == nil, blur == nil, spread == nil, x == nil, y == nil {
            design.shadow = mine("shadow-sm", "shadow").flatMap(composedShadow)
        } else {
            design.shadow = ThemeShadow(color: color ?? "#000000", opacity: min(max(opacity ?? 0.1, 0), 1),
                                        blur: max(blur ?? 3, 0), spread: spread ?? 0, x: x ?? 0, y: y ?? 1)
        }
        return design.isEmpty ? nil : design
    }

    /// The first layer of a CSS `box-shadow` list — `x y blur spread colour`,
    /// blur and spread optional — as a theme's shadow.
    static func composedShadow(_ text: String) -> ThemeShadow? {
        guard let layer = splitTopLevel(text, at: ",").first else { return nil }
        var lengths: [Double] = []
        var colour: [String] = []
        for token in splitTopLevel(layer, at: " ") {
            if colour.isEmpty, lengths.count < 4, let length = CSSLength.points(token) {
                lengths.append(length)
            } else {
                colour.append(token)
            }
        }
        guard lengths.count >= 2 else { return nil }
        let paint = colour.joined(separator: " ")
        return ThemeShadow(color: CSSColor.parse(paint) ?? "#000000",
                           opacity: colour.isEmpty ? 1 : CSSColor.alpha(paint),
                           blur: lengths.count > 2 ? max(lengths[2], 0) : 0,
                           spread: lengths.count > 3 ? lengths[3] : 0,
                           x: lengths[0], y: lengths[1])
    }

    /// `text` cut at a separator, parentheses kept whole (`hsl(0 0% 0% / 0.1)`).
    static func splitTopLevel(_ text: String, at separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Fonts and radius a tweakcn theme carries, for documents (ADR-0017).
    static func document(from vars: Variables) -> ThemeDocumentStyle? {
        func value(_ name: String) -> String? {
            vars[name].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let style = ThemeDocumentStyle(fontSans: value("font-sans"), fontMono: value("font-mono"),
                                       radius: value("radius"))
        return style.isEmpty ? nil : style
    }

    /// Text pasted in the import field: CSS when it carries variables.
    public static func looksLikeCSS(_ text: String) -> Bool {
        text.contains("--") && (text.contains(":") || text.contains("{"))
    }
}

// MARK: - CSS colours

/// The colour notations tweakcn and shadcn write: hex, `rgb()`, `hsl()`,
/// the bare `H S% L%` triplet of shadcn v3, `oklch()` and `oklab()`.
/// Everything lands as sRGB `#RRGGBB`; `parse` drops the alpha, `alpha`
/// reads it and `opaque` lays the colour over a backdrop with it.
public enum CSSColor {

    /// The alpha a colour is written with, 0…1: `#RRGGBBAA`, `… / 50%`,
    /// `rgba(…, 0.5)`. 1 when it has none.
    public static func alpha(_ text: String) -> Double {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func fraction(_ number: Number) -> Double {
            min(max(number.isPercent ? number.value / 100 : number.value, 0), 1)
        }
        if value.hasPrefix("#") {
            let digits = value.dropFirst()
            guard digits.count == 4 || digits.count == 8 else { return 1 }
            let pair = digits.count == 4 ? String(repeating: String(digits.suffix(1)), count: 2)
                                         : String(digits.suffix(2))
            return UInt8(pair, radix: 16).map { Double($0) / 255 } ?? 1
        }
        if let slash = value.lastIndex(of: "/") {
            let after = value[value.index(after: slash)...].replacingOccurrences(of: ")", with: "")
            return numbers(in: after).first.map(fraction) ?? 1
        }
        // The legacy comma syntax: the fourth argument.
        if value.hasPrefix("rgb") || value.hasPrefix("hsl"), value.contains(","),
           let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let arguments = numbers(in: String(value[value.index(after: open)...].dropLast()))
            if arguments.count == 4 { return fraction(arguments[3]) }
        }
        return 1
    }

    /// The colour as it looks over `backdrop`: itself when opaque, blended
    /// by its alpha otherwise. nil when the text is no colour.
    public static func opaque(_ text: String, over backdrop: String) -> String? {
        guard let hex = parse(text) else { return nil }
        let amount = alpha(text)
        return amount >= 1 ? hex : ThemeTokens.mix(backdrop, with: hex, amount: amount)
    }

    public static func parse(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("#") {
            // #RGB, #RGBA, #RRGGBB, #RRGGBBAA — the alpha is dropped.
            let digits = value.dropFirst()
            let colour = digits.count == 4 ? String(digits.prefix(3))
                       : digits.count == 8 ? String(digits.prefix(6)) : String(digits)
            guard let c = ThemeTokens.rgb("#" + colour) else { return nil }
            return ThemeTokens.hex(red: c.red, green: c.green, blue: c.blue)
        }
        if let named = named[value] { return named }
        if let parsed = call(value) {
            let (function, arguments) = parsed
            switch function {
            case "rgb", "rgba":
                guard arguments.count >= 3 else { return nil }
                let scale = arguments[0].isPercent ? 100.0 : 255.0
                return ThemeTokens.hex(red: arguments[0].value / scale,
                                       green: arguments[1].value / scale,
                                       blue: arguments[2].value / scale)
            case "hsl", "hsla":
                guard arguments.count >= 3 else { return nil }
                return hsl(arguments[0].value, arguments[1].value / 100, arguments[2].value / 100)
            case "oklch":
                guard arguments.count >= 3 else { return nil }
                let l = arguments[0].isPercent ? arguments[0].value / 100 : arguments[0].value
                let c = arguments[1].isPercent ? arguments[1].value / 100 * 0.4 : arguments[1].value
                return oklch(l, c, arguments[2].value)
            case "oklab":
                guard arguments.count >= 3 else { return nil }
                let l = arguments[0].isPercent ? arguments[0].value / 100 : arguments[0].value
                return oklab(l, arguments[1].value, arguments[2].value)
            default:
                return nil
            }
        }
        // shadcn v3: "210 40% 98%" — hsl without the function.
        let parts = numbers(in: value)
        if parts.count >= 3, parts[1].isPercent, parts[2].isPercent {
            return hsl(parts[0].value, parts[1].value / 100, parts[2].value / 100)
        }
        return nil
    }

    /// The keywords themes actually write.
    private static let named: [String: String] = [
        "white": "#FFFFFF", "black": "#000000",
    ]

    struct Number {
        let value: Double
        let isPercent: Bool
    }

    /// `name(arguments)` → the name and its numbers; nil when not a call.
    private static func call(_ value: String) -> (String, [Number])? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
        // The alpha after "/" is dropped: only the colour matters.
        let colour = inside.split(separator: "/").first.map(String.init) ?? ""
        return (name, numbers(in: colour))
    }

    /// The numbers of a CSS value, separated by spaces or commas — with
    /// units (`%`, `deg`) noted or ignored.
    static func numbers(in text: String) -> [Number] {
        text.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { token -> Number? in
                var piece = String(token)
                let percent = piece.hasSuffix("%")
                if percent { piece.removeLast() }
                if piece.hasSuffix("deg") { piece.removeLast(3) }
                guard let value = Double(piece) else { return nil }
                return Number(value: value, isPercent: percent)
            }
    }

    /// HSL (hue in degrees, s and l in 0…1) → hex.
    static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        if s == 0 { return ThemeTokens.hex(red: l, green: l, blue: l) }
        return ThemeTokens.hex(red: channel(h + 1 / 3), green: channel(h), blue: channel(h - 1 / 3))
    }

    /// OKLCH → OKLab → linear sRGB → sRGB, clamped to the gamut.
    static func oklch(_ l: Double, _ c: Double, _ hDegrees: Double) -> String {
        let h = hDegrees * .pi / 180
        return oklab(l, c * cos(h), c * sin(h))
    }

    static func oklab(_ L: Double, _ a: Double, _ b: Double) -> String {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return ThemeTokens.hex(red: gamma(red), green: gamma(green), blue: gamma(blue))
    }

    private static func gamma(_ linear: Double) -> Double {
        let v = min(max(linear, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
