import LoomCore
import Observation
import SwiftUI

/// A complete set of UI tokens. `DefaultTheme` proxies the ACTIVE palette —
/// hundreds of call sites stay untouched, and because views read it through
/// the observable store, switching re-renders everything live.
public struct ThemePalette: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let isLight: Bool

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

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

extension ThemePalette {

    /// The Xirp-inspired default — the identity Loom shipped with.
    public static let loomDark = ThemePalette(
        name: "Loom Dark", isLight: false,
        background: hex(0x0D0D0E), contentBackground: hex(0x111113),
        surface: hex(0x17171A), surfaceRaised: hex(0x1E1E22), cardBorder: hex(0x26262B),
        accent: hex(0xE8945C), accentText: hex(0x201204),
        primaryText: hex(0xECECEE), secondaryText: hex(0x86868E), mutedText: hex(0x6B6B73),
        branch: hex(0x5CC8C2), danger: hex(0xE5646C), groupHeader: hex(0x4CC38A),
        stateWorking: hex(0x4CC38A), stateNeedsInput: hex(0xE5B455), stateIdle: hex(0x6AA2E8))

    public static let dracula = ThemePalette(
        name: "Dracula", isLight: false,
        background: hex(0x21222C), contentBackground: hex(0x282A36),
        surface: hex(0x2B2D3A), surfaceRaised: hex(0x363948), cardBorder: hex(0x44475A),
        accent: hex(0xBD93F9), accentText: hex(0x1E1029),
        primaryText: hex(0xF8F8F2), secondaryText: hex(0x9BA3C9), mutedText: hex(0x6272A4),
        branch: hex(0x8BE9FD), danger: hex(0xFF5555), groupHeader: hex(0x50FA7B),
        stateWorking: hex(0x50FA7B), stateNeedsInput: hex(0xF1FA8C), stateIdle: hex(0x8BE9FD))

    public static let nord = ThemePalette(
        name: "Nord", isLight: false,
        background: hex(0x2E3440), contentBackground: hex(0x323846),
        surface: hex(0x3B4252), surfaceRaised: hex(0x434C5E), cardBorder: hex(0x4C566A),
        accent: hex(0x88C0D0), accentText: hex(0x10222A),
        primaryText: hex(0xECEFF4), secondaryText: hex(0xA3ABB8), mutedText: hex(0x7B8394),
        branch: hex(0x8FBCBB), danger: hex(0xBF616A), groupHeader: hex(0xA3BE8C),
        stateWorking: hex(0xA3BE8C), stateNeedsInput: hex(0xEBCB8B), stateIdle: hex(0x81A1C1))

    public static let solarizedDark = ThemePalette(
        name: "Solarized Dark", isLight: false,
        background: hex(0x002B36), contentBackground: hex(0x03303C),
        surface: hex(0x073642), surfaceRaised: hex(0x0D4350), cardBorder: hex(0x1A4A56),
        accent: hex(0x268BD2), accentText: hex(0xFDF6E3),
        primaryText: hex(0xEEE8D5), secondaryText: hex(0x93A1A1), mutedText: hex(0x657B83),
        branch: hex(0x2AA198), danger: hex(0xDC322F), groupHeader: hex(0x859900),
        stateWorking: hex(0x859900), stateNeedsInput: hex(0xB58900), stateIdle: hex(0x268BD2))

    public static let solarizedLight = ThemePalette(
        name: "Solarized Light", isLight: true,
        background: hex(0xFDF6E3), contentBackground: hex(0xFBF2DC),
        surface: hex(0xEEE8D5), surfaceRaised: hex(0xE4DCC5), cardBorder: hex(0xD3CBB7),
        accent: hex(0x268BD2), accentText: hex(0xFDF6E3),
        primaryText: hex(0x073642), secondaryText: hex(0x586E75), mutedText: hex(0x93A1A1),
        branch: hex(0x2AA198), danger: hex(0xDC322F), groupHeader: hex(0x859900),
        stateWorking: hex(0x859900), stateNeedsInput: hex(0xB58900), stateIdle: hex(0x268BD2))

    public static let oneDark = ThemePalette(
        name: "One Dark", isLight: false,
        background: hex(0x21252B), contentBackground: hex(0x282C34),
        surface: hex(0x2C313A), surfaceRaised: hex(0x333842), cardBorder: hex(0x3E4451),
        accent: hex(0x61AFEF), accentText: hex(0x0D1A26),
        primaryText: hex(0xABB2BF), secondaryText: hex(0x828997), mutedText: hex(0x5C6370),
        branch: hex(0x56B6C2), danger: hex(0xE06C75), groupHeader: hex(0x98C379),
        stateWorking: hex(0x98C379), stateNeedsInput: hex(0xE5C07B), stateIdle: hex(0x61AFEF))

    public static let gruvbox = ThemePalette(
        name: "Gruvbox Dark", isLight: false,
        background: hex(0x1D2021), contentBackground: hex(0x232627),
        surface: hex(0x282828), surfaceRaised: hex(0x3C3836), cardBorder: hex(0x504945),
        accent: hex(0xFE8019), accentText: hex(0x291302),
        primaryText: hex(0xEBDBB2), secondaryText: hex(0xA89984), mutedText: hex(0x7C6F64),
        branch: hex(0x8EC07C), danger: hex(0xFB4934), groupHeader: hex(0xB8BB26),
        stateWorking: hex(0xB8BB26), stateNeedsInput: hex(0xFABD2F), stateIdle: hex(0x83A598))

    public static let tokyoNight = ThemePalette(
        name: "Tokyo Night", isLight: false,
        background: hex(0x16161E), contentBackground: hex(0x1A1B26),
        surface: hex(0x1F2335), surfaceRaised: hex(0x292E42), cardBorder: hex(0x3B4261),
        accent: hex(0x7AA2F7), accentText: hex(0x0B1220),
        primaryText: hex(0xC0CAF5), secondaryText: hex(0x7982A9), mutedText: hex(0x565F89),
        branch: hex(0x7DCFFF), danger: hex(0xF7768E), groupHeader: hex(0x9ECE6A),
        stateWorking: hex(0x9ECE6A), stateNeedsInput: hex(0xE0AF68), stateIdle: hex(0x7AA2F7))

    public static let catppuccin = ThemePalette(
        name: "Catppuccin Mocha", isLight: false,
        background: hex(0x181825), contentBackground: hex(0x1E1E2E),
        surface: hex(0x24243A), surfaceRaised: hex(0x313244), cardBorder: hex(0x45475A),
        accent: hex(0xCBA6F7), accentText: hex(0x21102F),
        primaryText: hex(0xCDD6F4), secondaryText: hex(0x9399B2), mutedText: hex(0x6C7086),
        branch: hex(0x94E2D5), danger: hex(0xF38BA8), groupHeader: hex(0xA6E3A1),
        stateWorking: hex(0xA6E3A1), stateNeedsInput: hex(0xF9E2AF), stateIdle: hex(0x89B4FA))

    public static let monokai = ThemePalette(
        name: "Monokai", isLight: false,
        background: hex(0x1E1F1C), contentBackground: hex(0x232420),
        surface: hex(0x272822), surfaceRaised: hex(0x3E3D32), cardBorder: hex(0x49483E),
        accent: hex(0xA6E22E), accentText: hex(0x141704),
        primaryText: hex(0xF8F8F2), secondaryText: hex(0xA59F85), mutedText: hex(0x75715E),
        branch: hex(0x66D9EF), danger: hex(0xF92672), groupHeader: hex(0xA6E22E),
        stateWorking: hex(0xA6E22E), stateNeedsInput: hex(0xE6DB74), stateIdle: hex(0x66D9EF))

    public static let all: [ThemePalette] = [
        .loomDark, .dracula, .nord, .tokyoNight, .catppuccin,
        .oneDark, .gruvbox, .monokai, .solarizedDark, .solarizedLight,
    ]
}

/// The single source of the ACTIVE palette. Views read it through
/// `DefaultTheme`'s computed tokens — observation makes switching live.
@Observable
@MainActor
public final class ThemeStore {
    public static let shared = ThemeStore()

    public private(set) var palette: ThemePalette

    private static let globalKey = "loom.theme.global"
    private static let projectsKey = "loom.theme.projects"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.globalKey)
        palette = ThemePalette.all.first { $0.name == saved } ?? .loomDark
    }

    public var globalThemeName: String {
        UserDefaults.standard.string(forKey: Self.globalKey) ?? ThemePalette.loomDark.name
    }

    public func setGlobalTheme(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.globalKey)
    }

    // MARK: Per-project overrides (presentation preference → UserDefaults)

    public func projectThemeName(_ projectID: ProjectID) -> String? {
        overrides()[projectID.rawValue.uuidString]
    }

    public func setProjectTheme(_ name: String?, for projectID: ProjectID) {
        var map = overrides()
        map[projectID.rawValue.uuidString] = name
        UserDefaults.standard.set(map, forKey: Self.projectsKey)
    }

    private func overrides() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.projectsKey) as? [String: String] ?? [:]
    }

    /// The effective theme for a context: project override, else global.
    public func apply(projectID: ProjectID?) {
        let name = projectID.flatMap(projectThemeName) ?? globalThemeName
        let next = ThemePalette.all.first { $0.name == name } ?? .loomDark
        if next != palette { palette = next }
    }
}
