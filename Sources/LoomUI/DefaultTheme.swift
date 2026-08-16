import LoomCore
import LoomTerminal
import SwiftUI

/// Default theme tokens — modeled on the validated visual reference (Xirp):
/// near-black background, flat outlined cards, warm orange accent, mono for
/// paths and branches. The full theme system (Theme/ThemeResolver) translates
/// to these tokens; no hardcoded color in the views.
public enum DefaultTheme {

    // Backgrounds
    public static let background = Color(red: 0.051, green: 0.051, blue: 0.055)   // #0D0D0E
    public static let contentBackground = Color(red: 0.067, green: 0.067, blue: 0.075) // #111113
    public static let surface = Color(red: 0.090, green: 0.090, blue: 0.102)      // #17171A
    public static let surfaceRaised = Color(red: 0.118, green: 0.118, blue: 0.133)
    public static let cardBorder = Color(red: 0.149, green: 0.149, blue: 0.169)   // #26262B

    // Accent (filled buttons: dark text on top, like the reference)
    public static let accent = Color(red: 0.910, green: 0.580, blue: 0.360)       // #E8945C
    public static let accentText = Color(red: 0.125, green: 0.071, blue: 0.016)

    // Text
    public static let primaryText = Color(red: 0.925, green: 0.925, blue: 0.933)
    public static let secondaryText = Color(red: 0.525, green: 0.525, blue: 0.557) // #86868E
    public static let mutedText = Color(red: 0.42, green: 0.42, blue: 0.45)

    // Semantics
    public static let branch = Color(red: 0.36, green: 0.784, blue: 0.76)         // mono cyan
    public static let danger = Color(red: 0.898, green: 0.392, blue: 0.424)
    /// Sidebar group headers — the reference's green.
    public static let groupHeader = Color(red: 0.298, green: 0.764, blue: 0.541)

    /// Invariant semantics (THM-08): a theme adjusts the hue, never the meaning.
    public static func badgeColor(for state: SessionState) -> Color {
        switch state {
        case .working: Color(red: 0.298, green: 0.764, blue: 0.541)               // green
        case .needsInput: Color(red: 0.898, green: 0.706, blue: 0.333)            // amber
        // "inactive" (closed but not destroyed) shares the resting blue.
        case .idle, .starting, .completed, .interrupted:
            Color(red: 0.416, green: 0.635, blue: 0.910)                          // blue
        case .archived, .draft: secondaryText
        case .failed: danger
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
