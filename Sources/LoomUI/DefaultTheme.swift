import LoomCore
import LoomTerminal
import SwiftUI

/// Default theme tokens — modeled on the validated visual reference (Xirp):
/// near-black background, flat outlined cards, warm orange accent, mono for
/// paths and branches. The full theme system (Theme/ThemeResolver) translates
/// to these tokens; no hardcoded color in the views.
@MainActor
public enum DefaultTheme {

    /// Every token proxies the ACTIVE palette (ThemeStore) — views observe the
    /// store through these reads, so a theme switch re-renders live without a
    /// single call-site change.
    static var palette: ThemePalette { ThemeStore.shared.palette }

    // Backgrounds
    public static var background: Color { palette.background }
    public static var contentBackground: Color { palette.contentBackground }
    public static var surface: Color { palette.surface }
    public static var surfaceRaised: Color { palette.surfaceRaised }
    public static var cardBorder: Color { palette.cardBorder }

    // Accent (filled buttons: contrasting text on top, like the reference)
    public static var accent: Color { palette.accent }
    public static var accentText: Color { palette.accentText }

    // Text
    public static var primaryText: Color { palette.primaryText }
    public static var secondaryText: Color { palette.secondaryText }
    public static var mutedText: Color { palette.mutedText }

    // Semantics
    public static var branch: Color { palette.branch }
    public static var danger: Color { palette.danger }
    /// Sidebar group headers.
    public static var groupHeader: Color { palette.groupHeader }

    /// Invariant semantics (THM-08): a theme adjusts the hue, never the meaning.
    public static func badgeColor(for state: SessionState) -> Color {
        switch state {
        case .working: palette.stateWorking
        case .needsInput: palette.stateNeedsInput
        // "inactive" (closed but not destroyed) shares the resting blue.
        case .idle, .starting, .completed, .interrupted: palette.stateIdle
        case .archived, .draft: palette.secondaryText
        case .failed: palette.danger
        }
    }

    public static func label(for state: SessionState) -> String {
        switch state {
        case .draft: "draft"
        case .starting: "starting"
        case .working: "working"
        case .needsInput: "needs input"
        // Alive but silent ≠ closed: "idle" vs "inactive"
        // (inactive = closed but not destroyed, resumable).
        case .idle: "idle"
        case .completed, .interrupted: "inactive"
        case .failed: "failed"
        case .archived: "archived"
        }
    }

    /// 16-color ANSI palette (the theme's *Terminal* space, THM-04).
    public static func terminalColor(_ color: TerminalColor, isBackground: Bool) -> Color {
        switch color {
        case .default:
            return isBackground ? .clear : primaryText
        case .rgb(let red, let green, let blue):
            return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .ansi(let code):
            return ansiPalette[Int(code) % ansiPalette.count]
        }
    }

    static let ansiPalette: [Color] = [
        Color(white: 0.1), Color(red: 0.8, green: 0.25, blue: 0.25),
        Color(red: 0.3, green: 0.75, blue: 0.4), Color(red: 0.85, green: 0.75, blue: 0.3),
        Color(red: 0.35, green: 0.55, blue: 0.9), Color(red: 0.75, green: 0.45, blue: 0.85),
        Color(red: 0.3, green: 0.75, blue: 0.8), Color(white: 0.85),
        Color(white: 0.4), Color(red: 0.95, green: 0.4, blue: 0.4),
        Color(red: 0.45, green: 0.9, blue: 0.55), Color(red: 0.95, green: 0.85, blue: 0.45),
        Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 0.85, green: 0.6, blue: 0.95),
        Color(red: 0.45, green: 0.9, blue: 0.95), .white,
    ]
}
