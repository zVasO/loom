import AppKit
import LoomCore
import Observation
import SwiftUI

// MARK: - Tokens

/// The 16 colours a palette is made of, as `#RRGGBB` — what a theme file
/// carries, what an import produces, what a palette is built from.
public struct ThemeTokens: Codable, Equatable, Sendable, Hashable {
    public var background: String
    public var contentBackground: String
    public var surface: String
    public var surfaceRaised: String
    public var cardBorder: String
    public var accent: String
    public var accentText: String
    public var primaryText: String
    public var secondaryText: String
    public var mutedText: String
    public var branch: String
    public var danger: String
    public var groupHeader: String
    public var stateWorking: String
    public var stateNeedsInput: String
    public var stateIdle: String

    public init(background: String, contentBackground: String, surface: String,
                surfaceRaised: String, cardBorder: String, accent: String, accentText: String,
                primaryText: String, secondaryText: String, mutedText: String, branch: String,
                danger: String, groupHeader: String, stateWorking: String,
                stateNeedsInput: String, stateIdle: String) {
        self.background = background
        self.contentBackground = contentBackground
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.cardBorder = cardBorder
        self.accent = accent
        self.accentText = accentText
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.mutedText = mutedText
        self.branch = branch
        self.danger = danger
        self.groupHeader = groupHeader
        self.stateWorking = stateWorking
        self.stateNeedsInput = stateNeedsInput
        self.stateIdle = stateIdle
    }

    /// Every token, in a stable order — for validation and previews.
    public var all: [String] {
        [background, contentBackground, surface, surfaceRaised, cardBorder, accent, accentText,
         primaryText, secondaryText, mutedText, branch, danger, groupHeader,
         stateWorking, stateNeedsInput, stateIdle]
    }

    /// `#RRGGBB` (or `#RGB`) → sRGB components in 0…1. nil when malformed.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255,
                Double((number >> 8) & 0xFF) / 255,
                Double(number & 0xFF) / 255)
    }

    /// Components in 0…1 → `#RRGGBB`, clamped.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Linear blend of two hex colours (`amount` of `other`).
    public static func mix(_ hex: String, with other: String, amount: Double) -> String {
        guard let a = rgb(hex), let b = rgb(other) else { return hex }
        let t = min(max(amount, 0), 1)
        return Self.hex(red: a.red + (b.red - a.red) * t,
                        green: a.green + (b.green - a.green) * t,
                        blue: a.blue + (b.blue - a.blue) * t)
    }

    /// Relative luminance — what decides whether a background reads as light.
    public static func luminance(_ hex: String) -> Double {
        guard let c = rgb(hex) else { return 0 }
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    public var isLight: Bool { Self.luminance(background) > 0.4 }
}

// MARK: - Palette

/// A complete set of UI tokens as SwiftUI colours. `DefaultTheme` proxies the
/// ACTIVE palette — hundreds of call sites stay untouched, and because views
/// read it through the observable store, switching re-renders everything live.
public struct ThemePalette: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let isLight: Bool
    public let tokens: ThemeTokens

    public let background: Color
    public let contentBackground: Color
    public let surface: Color
    public let surfaceRaised: Color
    public let cardBorder: Color
    public let accent: Color
    public let accentText: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let mutedText: Color
    public let branch: Color
    public let danger: Color
    public let groupHeader: Color
    public let stateWorking: Color
    public let stateNeedsInput: Color
    public let stateIdle: Color

    public init(name: String, isLight: Bool, tokens: ThemeTokens) {
        self.name = name
        self.isLight = isLight
        self.tokens = tokens
        background = Self.color(tokens.background)
        contentBackground = Self.color(tokens.contentBackground)
        surface = Self.color(tokens.surface)
        surfaceRaised = Self.color(tokens.surfaceRaised)
        cardBorder = Self.color(tokens.cardBorder)
        accent = Self.color(tokens.accent)
        accentText = Self.color(tokens.accentText)
        primaryText = Self.color(tokens.primaryText)
        secondaryText = Self.color(tokens.secondaryText)
        mutedText = Self.color(tokens.mutedText)
        branch = Self.color(tokens.branch)
        danger = Self.color(tokens.danger)
        groupHeader = Self.color(tokens.groupHeader)
        stateWorking = Self.color(tokens.stateWorking)
        stateNeedsInput = Self.color(tokens.stateNeedsInput)
        stateIdle = Self.color(tokens.stateIdle)
    }

    public static func color(_ hex: String) -> Color {
        guard let c = ThemeTokens.rgb(hex) else { return .clear }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    /// Every variant of every built-in family — the flat list the pickers
    /// used to read, kept for the call sites that still do.
    public static var all: [ThemePalette] {
        ThemeFamily.builtins.flatMap { [$0.palette(dark: true), $0.palette(dark: false)] }
    }
}

// MARK: - Family: one theme, a light and a dark variant

/// A theme as the user picks it: one name, two variants. The app shows the
/// one matching its appearance; the other is a system switch away.
public struct ThemeFamily: Identifiable, Codable, Equatable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var light: ThemeTokens
    public var dark: ThemeTokens
    /// The variants' own names when they have one ("Catppuccin Latte",
    /// "Alucard"); nil reads "<name> Light" / "<name> Dark".
    public var lightName: String?
    public var darkName: String?
    public var isBuiltIn: Bool

    public init(name: String, light: ThemeTokens, dark: ThemeTokens,
                lightName: String? = nil, darkName: String? = nil, isBuiltIn: Bool = false) {
        self.name = name
        self.light = light
        self.dark = dark
        self.lightName = lightName
        self.darkName = darkName
        self.isBuiltIn = isBuiltIn
    }

    /// Files written by hand or by an older Loom may omit the optional keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        light = try container.decode(ThemeTokens.self, forKey: .light)
        dark = try container.decode(ThemeTokens.self, forKey: .dark)
        lightName = try container.decodeIfPresent(String.self, forKey: .lightName)
        darkName = try container.decodeIfPresent(String.self, forKey: .darkName)
        // A file on disk is the user's by definition.
        isBuiltIn = false
    }

    public var variantLightName: String { lightName ?? name + " Light" }
    public var variantDarkName: String { darkName ?? name + " Dark" }

    public func palette(dark: Bool) -> ThemePalette {
        dark ? ThemePalette(name: variantDarkName, isLight: false, tokens: self.dark)
             : ThemePalette(name: variantLightName, isLight: true, tokens: light)
    }

    /// A family name, or a variant's name (what the settings stored before
    /// families existed: "Tokyo Night", "Solarized Light"…) → the family.
    public static func resolve(_ name: String, in families: [ThemeFamily]) -> ThemeFamily? {
        families.first { $0.name == name }
            ?? families.first { $0.variantDarkName == name || $0.variantLightName == name }
    }

    /// A file name for the family: lowercase, dashes, ASCII.
    public var slug: String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "theme" : collapsed
    }
}

/// The user's families on disk (THM-06): one JSON per family under
/// `themes/`. Disposable: an unreadable file is skipped, never an error.
public struct ThemeFamilyStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() -> [ThemeFamily] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ThemeFamily.self, from: data)
            }
    }

    public func save(_ family: ThemeFamily) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(family).write(to: url(for: family), options: .atomic)
    }

    public func delete(_ family: ThemeFamily) {
        try? FileManager.default.removeItem(at: url(for: family))
    }

    public func url(for family: ThemeFamily) -> URL {
        directory.appendingPathComponent(family.slug + ".json")
    }
}

// MARK: - Appearance

/// Whether the app follows macOS, or is forced light or dark.
public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

// MARK: - Store

/// The single source of the ACTIVE palette. Views read it through
/// `DefaultTheme`'s computed tokens — observation makes switching live. The
/// palette is the chosen family's variant for the current appearance:
/// macOS's when following the system, else the forced one.
@Observable
@MainActor
public final class ThemeStore {
    public static let shared = ThemeStore()

    public private(set) var palette: ThemePalette
    /// The user's own families, from `themes/` — after the built-ins.
    public private(set) var customFamilies: [ThemeFamily] = []
    public private(set) var systemIsDark: Bool
    public private(set) var appearanceMode: AppearanceMode

    private static let globalKey = "loom.theme.global"
    private static let projectsKey = "loom.theme.projects"
    private static let appearanceKey = "loom.theme.appearance"

    @ObservationIgnored private var familyStore: ThemeFamilyStore?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    /// The project the palette was last applied for — replayed when the
    /// appearance flips under it.
    @ObservationIgnored private var contextProjectID: ProjectID?

    private init() {
        systemIsDark = Self.currentSystemIsDark()
        appearanceMode = AppearanceMode(rawValue: UserDefaults.standard
            .string(forKey: Self.appearanceKey) ?? "") ?? .system
        let saved = UserDefaults.standard.string(forKey: Self.globalKey) ?? ThemeFamily.loom.name
        let family = ThemeFamily.resolve(saved, in: ThemeFamily.builtins) ?? .loom
        palette = family.palette(dark: Self.resolveIsDark(mode: appearanceMode,
                                                          systemIsDark: systemIsDark))
        // KVO on the app's effective appearance: what changes when the user
        // flips macOS (or its schedule does) while Loom runs.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance,
                                                             options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.systemAppearanceChanged() }
        }
    }

    /// Where the user's families live. Called once, at launch, by the app —
    /// the store itself has no idea where the support directory is.
    public func configure(themesDirectory: URL) {
        let store = ThemeFamilyStore(directory: themesDirectory)
        familyStore = store
        customFamilies = store.load()
        apply(projectID: contextProjectID)
    }

    // MARK: Families

    public var families: [ThemeFamily] { ThemeFamily.builtins + customFamilies }

    public func family(named name: String) -> ThemeFamily? {
        ThemeFamily.resolve(name, in: families)
    }

    /// Adds (or replaces, same name) a family and writes it to disk.
    public func addFamily(_ family: ThemeFamily) throws {
        var stored = family
        stored.isBuiltIn = false
        try familyStore?.save(stored)
        customFamilies.removeAll { $0.name == stored.name }
        customFamilies.append(stored)
        apply(projectID: contextProjectID)
    }

    /// Removes a user family; the global theme and any project pointing at it
    /// fall back to the default.
    public func removeFamily(_ family: ThemeFamily) {
        guard !family.isBuiltIn else { return }
        familyStore?.delete(family)
        customFamilies.removeAll { $0.name == family.name }
        if globalFamilyName == family.name { setGlobalTheme(ThemeFamily.loom.name) }
        var map = overrides()
        for (key, value) in map where value == family.name { map[key] = nil }
        UserDefaults.standard.set(map, forKey: Self.projectsKey)
        apply(projectID: contextProjectID)
    }

    // MARK: Global theme and appearance

    /// The chosen family's name — an old palette name stored by a previous
    /// Loom resolves to its family.
    public var globalFamilyName: String {
        let saved = UserDefaults.standard.string(forKey: Self.globalKey) ?? ThemeFamily.loom.name
        return family(named: saved)?.name ?? ThemeFamily.loom.name
    }

    /// Kept under its old name: every call site passes a family (or variant) name.
    public func setGlobalTheme(_ name: String) {
        UserDefaults.standard.set(family(named: name)?.name ?? name, forKey: Self.globalKey)
    }

    public func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appearanceKey)
        apply(projectID: contextProjectID)
    }

    /// Dark or light right now: what the mode says, or what macOS says.
    public var isDark: Bool { Self.resolveIsDark(mode: appearanceMode, systemIsDark: systemIsDark) }

    /// Pure: the one rule the appearance follows.
    public static func resolveIsDark(mode: AppearanceMode, systemIsDark: Bool) -> Bool {
        switch mode {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }

    static func currentSystemIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func systemAppearanceChanged() {
        let dark = Self.currentSystemIsDark()
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        apply(projectID: contextProjectID)
    }

    // MARK: Per-project overrides (presentation preference → UserDefaults)

    public func projectThemeName(_ projectID: ProjectID) -> String? {
        overrides()[projectID.rawValue.uuidString].flatMap { family(named: $0)?.name }
    }

    public func setProjectTheme(_ name: String?, for projectID: ProjectID) {
        var map = overrides()
        map[projectID.rawValue.uuidString] = name.flatMap { family(named: $0)?.name }
        UserDefaults.standard.set(map, forKey: Self.projectsKey)
    }

    private func overrides() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.projectsKey) as? [String: String] ?? [:]
    }

    /// The effective palette for a context: the project's family, else the
    /// global one, in the variant the appearance calls for.
    public func apply(projectID: ProjectID?) {
        contextProjectID = projectID
        let name = projectID.flatMap(projectThemeName) ?? globalFamilyName
        let family = family(named: name) ?? .loom
        let next = family.palette(dark: isDark)
        if next != palette { palette = next }
    }
}

// MARK: - Built-in families

extension ThemeFamily {

    public static let builtins: [ThemeFamily] = [
        .loom, .dracula, .nord, .tokyoNight, .catppuccin,
        .one, .gruvbox, .monokai, .solarized,
    ]

    /// The Xirp-inspired default — the identity Loom shipped with — and its
    /// daylight counterpart.
    public static let loom = ThemeFamily(
        name: "Loom",
        light: ThemeTokens(
            background: "#F2F2F4", contentBackground: "#F7F7F9",
            surface: "#FFFFFF", surfaceRaised: "#ECECEF", cardBorder: "#DCDCE1",
            accent: "#D9782F", accentText: "#FFF7EF",
            primaryText: "#1C1C21", secondaryText: "#6B6B76", mutedText: "#9494A0",
            branch: "#1C9C95", danger: "#C9333C", groupHeader: "#2A9D63",
            stateWorking: "#2A9D63", stateNeedsInput: "#B8860B", stateIdle: "#3B6BB5"),
        dark: ThemeTokens(
            background: "#0D0D0E", contentBackground: "#111113",
            surface: "#17171A", surfaceRaised: "#1E1E22", cardBorder: "#26262B",
            accent: "#E8945C", accentText: "#201204",
            primaryText: "#ECECEE", secondaryText: "#86868E", mutedText: "#6B6B73",
            branch: "#5CC8C2", danger: "#E5646C", groupHeader: "#4CC38A",
            stateWorking: "#4CC38A", stateNeedsInput: "#E5B455", stateIdle: "#6AA2E8"),
        lightName: "Loom Light", darkName: "Loom Dark", isBuiltIn: true)

    /// Dracula, and Alucard — its official light theme.
    public static let dracula = ThemeFamily(
        name: "Dracula",
        light: ThemeTokens(
            background: "#F7F3E3", contentBackground: "#FFFBEB",
            surface: "#FFFFFF", surfaceRaised: "#EFEBDB", cardBorder: "#DDD8C4",
            accent: "#644AC9", accentText: "#FFFFFF",
            primaryText: "#1F1F1F", secondaryText: "#6C664B", mutedText: "#9A9478",
            branch: "#036A96", danger: "#CB3A2A", groupHeader: "#14710A",
            stateWorking: "#14710A", stateNeedsInput: "#846E15", stateIdle: "#036A96"),
        dark: ThemeTokens(
            background: "#21222C", contentBackground: "#282A36",
            surface: "#2B2D3A", surfaceRaised: "#363948", cardBorder: "#44475A",
            accent: "#BD93F9", accentText: "#1E1029",
            primaryText: "#F8F8F2", secondaryText: "#9BA3C9", mutedText: "#6272A4",
            branch: "#8BE9FD", danger: "#FF5555", groupHeader: "#50FA7B",
            stateWorking: "#50FA7B", stateNeedsInput: "#F1FA8C", stateIdle: "#8BE9FD"),
        lightName: "Alucard", darkName: "Dracula", isBuiltIn: true)

    /// Nord: Polar Night, and Snow Storm as the light variant.
    public static let nord = ThemeFamily(
        name: "Nord",
        light: ThemeTokens(
            background: "#E5E9F0", contentBackground: "#ECEFF4",
            surface: "#F4F6FA", surfaceRaised: "#D8DEE9", cardBorder: "#C9D1DE",
            accent: "#5E81AC", accentText: "#ECEFF4",
            primaryText: "#2E3440", secondaryText: "#4C566A", mutedText: "#7B8394",
            branch: "#3B8A87", danger: "#BF616A", groupHeader: "#6A8F4E",
            stateWorking: "#6A8F4E", stateNeedsInput: "#B48A2E", stateIdle: "#5E81AC"),
        dark: ThemeTokens(
            background: "#2E3440", contentBackground: "#323846",
            surface: "#3B4252", surfaceRaised: "#434C5E", cardBorder: "#4C566A",
            accent: "#88C0D0", accentText: "#10222A",
            primaryText: "#ECEFF4", secondaryText: "#A3ABB8", mutedText: "#7B8394",
            branch: "#8FBCBB", danger: "#BF616A", groupHeader: "#A3BE8C",
            stateWorking: "#A3BE8C", stateNeedsInput: "#EBCB8B", stateIdle: "#81A1C1"),
        lightName: "Nord Light", darkName: "Nord", isBuiltIn: true)

    /// Tokyo Night, and Tokyo Night Day.
    public static let tokyoNight = ThemeFamily(
        name: "Tokyo Night",
        light: ThemeTokens(
            background: "#D6D8DF", contentBackground: "#E1E2E7",
            surface: "#E9E9EC", surfaceRaised: "#D0D5E3", cardBorder: "#B4B8C8",
            accent: "#2E7DE9", accentText: "#FFFFFF",
            primaryText: "#343B58", secondaryText: "#6172B0", mutedText: "#848CB5",
            branch: "#007197", danger: "#F52A65", groupHeader: "#587539",
            stateWorking: "#587539", stateNeedsInput: "#8C6C3E", stateIdle: "#2E7DE9"),
        dark: ThemeTokens(
            background: "#16161E", contentBackground: "#1A1B26",
            surface: "#1F2335", surfaceRaised: "#292E42", cardBorder: "#3B4261",
            accent: "#7AA2F7", accentText: "#0B1220",
            primaryText: "#C0CAF5", secondaryText: "#7982A9", mutedText: "#565F89",
            branch: "#7DCFFF", danger: "#F7768E", groupHeader: "#9ECE6A",
            stateWorking: "#9ECE6A", stateNeedsInput: "#E0AF68", stateIdle: "#7AA2F7"),
        lightName: "Tokyo Night Day", darkName: "Tokyo Night", isBuiltIn: true)

    /// Catppuccin Mocha, and Latte.
    public static let catppuccin = ThemeFamily(
        name: "Catppuccin",
        light: ThemeTokens(
            background: "#E6E9EF", contentBackground: "#EFF1F5",
            surface: "#F7F8FB", surfaceRaised: "#DCE0E8", cardBorder: "#CCD0DA",
            accent: "#8839EF", accentText: "#FFFFFF",
            primaryText: "#4C4F69", secondaryText: "#6C6F85", mutedText: "#9CA0B0",
            branch: "#179299", danger: "#D20F39", groupHeader: "#40A02B",
            stateWorking: "#40A02B", stateNeedsInput: "#DF8E1D", stateIdle: "#1E66F5"),
        dark: ThemeTokens(
            background: "#181825", contentBackground: "#1E1E2E",
            surface: "#24243A", surfaceRaised: "#313244", cardBorder: "#45475A",
            accent: "#CBA6F7", accentText: "#21102F",
            primaryText: "#CDD6F4", secondaryText: "#9399B2", mutedText: "#6C7086",
            branch: "#94E2D5", danger: "#F38BA8", groupHeader: "#A6E3A1",
            stateWorking: "#A6E3A1", stateNeedsInput: "#F9E2AF", stateIdle: "#89B4FA"),
        lightName: "Catppuccin Latte", darkName: "Catppuccin Mocha", isBuiltIn: true)

    /// One Dark, and One Light.
    public static let one = ThemeFamily(
        name: "One",
        light: ThemeTokens(
            background: "#EFEFF1", contentBackground: "#FAFAFA",
            surface: "#FFFFFF", surfaceRaised: "#E5E5E6", cardBorder: "#D4D4D8",
            accent: "#4078F2", accentText: "#FFFFFF",
            primaryText: "#383A42", secondaryText: "#696C77", mutedText: "#A0A1A7",
            branch: "#0184BC", danger: "#E45649", groupHeader: "#50A14F",
            stateWorking: "#50A14F", stateNeedsInput: "#C18401", stateIdle: "#4078F2"),
        dark: ThemeTokens(
            background: "#21252B", contentBackground: "#282C34",
            surface: "#2C313A", surfaceRaised: "#333842", cardBorder: "#3E4451",
            accent: "#61AFEF", accentText: "#0D1A26",
            primaryText: "#ABB2BF", secondaryText: "#828997", mutedText: "#5C6370",
            branch: "#56B6C2", danger: "#E06C75", groupHeader: "#98C379",
            stateWorking: "#98C379", stateNeedsInput: "#E5C07B", stateIdle: "#61AFEF"),
        lightName: "One Light", darkName: "One Dark", isBuiltIn: true)

    /// Gruvbox Dark, and Gruvbox Light.
    public static let gruvbox = ThemeFamily(
        name: "Gruvbox",
        light: ThemeTokens(
            background: "#F2E5BC", contentBackground: "#FBF1C7",
            surface: "#F9F5D7", surfaceRaised: "#EBDBB2", cardBorder: "#D5C4A1",
            accent: "#AF3A03", accentText: "#FBF1C7",
            primaryText: "#3C3836", secondaryText: "#665C54", mutedText: "#928374",
            branch: "#427B58", danger: "#9D0006", groupHeader: "#79740E",
            stateWorking: "#79740E", stateNeedsInput: "#B57614", stateIdle: "#076678"),
        dark: ThemeTokens(
            background: "#1D2021", contentBackground: "#232627",
            surface: "#282828", surfaceRaised: "#3C3836", cardBorder: "#504945",
            accent: "#FE8019", accentText: "#291302",
            primaryText: "#EBDBB2", secondaryText: "#A89984", mutedText: "#7C6F64",
            branch: "#8EC07C", danger: "#FB4934", groupHeader: "#B8BB26",
            stateWorking: "#B8BB26", stateNeedsInput: "#FABD2F", stateIdle: "#83A598"),
        lightName: "Gruvbox Light", darkName: "Gruvbox Dark", isBuiltIn: true)

    /// Monokai, and a sunlit variant in the spirit of Monokai Pro Light.
    public static let monokai = ThemeFamily(
        name: "Monokai",
        light: ThemeTokens(
            background: "#EFE6DD", contentBackground: "#F8EFE7",
            surface: "#FFF9F3", surfaceRaised: "#E6DDD4", cardBorder: "#D5CCC3",
            accent: "#218871", accentText: "#FFFFFF",
            primaryText: "#2C232E", secondaryText: "#6E6A70", mutedText: "#A59F9A",
            branch: "#2473B6", danger: "#CE4770", groupHeader: "#218871",
            stateWorking: "#218871", stateNeedsInput: "#B16803", stateIdle: "#2473B6"),
        dark: ThemeTokens(
            background: "#1E1F1C", contentBackground: "#232420",
            surface: "#272822", surfaceRaised: "#3E3D32", cardBorder: "#49483E",
            accent: "#A6E22E", accentText: "#141704",
            primaryText: "#F8F8F2", secondaryText: "#A59F85", mutedText: "#75715E",
            branch: "#66D9EF", danger: "#F92672", groupHeader: "#A6E22E",
            stateWorking: "#A6E22E", stateNeedsInput: "#E6DB74", stateIdle: "#66D9EF"),
        lightName: "Monokai Light", darkName: "Monokai", isBuiltIn: true)

    /// Solarized Dark and Solarized Light — the pair that started the idea.
    public static let solarized = ThemeFamily(
        name: "Solarized",
        light: ThemeTokens(
            background: "#FDF6E3", contentBackground: "#FBF2DC",
            surface: "#EEE8D5", surfaceRaised: "#E4DCC5", cardBorder: "#D3CBB7",
            accent: "#268BD2", accentText: "#FDF6E3",
            primaryText: "#073642", secondaryText: "#586E75", mutedText: "#93A1A1",
            branch: "#2AA198", danger: "#DC322F", groupHeader: "#859900",
            stateWorking: "#859900", stateNeedsInput: "#B58900", stateIdle: "#268BD2"),
        dark: ThemeTokens(
            background: "#002B36", contentBackground: "#03303C",
            surface: "#073642", surfaceRaised: "#0D4350", cardBorder: "#1A4A56",
            accent: "#268BD2", accentText: "#FDF6E3",
            primaryText: "#EEE8D5", secondaryText: "#93A1A1", mutedText: "#657B83",
            branch: "#2AA198", danger: "#DC322F", groupHeader: "#859900",
            stateWorking: "#859900", stateNeedsInput: "#B58900", stateIdle: "#268BD2"),
        lightName: "Solarized Light", darkName: "Solarized Dark", isBuiltIn: true)
}
