import LoomCore
import LoomTerminal
import SwiftUI

/// Default theme tokens — modeled on the validated visual reference (Xirp):
/// near-black background, flat outlined cards, warm orange accent, mono for
/// paths and branches. Every token proxies the active ThemePalette held by
/// ThemeStore; no hardcoded color in the views.
@MainActor
public enum DefaultTheme {

    /// Every token proxies the ACTIVE palette (ThemeStore) — views observe the
    /// store through these reads, so a theme switch re-renders live without a
    /// single call-site change.
    static var palette: ThemePalette { ThemeStore.shared.palette }

    /// The colour scheme system controls (fields, pickers, sheets) should
    /// take: the one the active palette was made for.
    public static var colorScheme: ColorScheme { palette.isLight ? .light : .dark }

    // Backgrounds
    public static var background: Color { palette.background }
    public static var contentBackground: Color { palette.contentBackground }
    public static var surface: Color { palette.surface }
    public static var surfaceRaised: Color { palette.surfaceRaised }
    /// Every edge is a hairline (the charter's 1 px at 8 % of the text):
    /// the palette's own `cardBorder` still feeds Claude Code's theme and
    /// the theme preview, the views draw the hairline. A theme with a
    /// border of its own (a tweakcn import) is drawn with it instead.
    public static var cardBorder: Color { line }

    // Hairlines: the text colour at low opacity, so a rule reads the same on
    // every surface of every theme (the landing page's --line, --line-2, --line-3)
    // — or the theme's own `--border` and `--input` (ThemePalette.line).
    public static var line: Color { palette.line }
    public static var line2: Color { palette.line2 }
    public static var line3: Color { palette.line3 }
    /// The edge of a text field: the hairline, or the theme's `--input`.
    public static var fieldBorder: Color { palette.fieldLine }
    /// Row washes: hover, then selection.
    public static var wash: Color { palette.wash }
    public static var wash2: Color { palette.wash2 }

    // Geometry and type (ADR-0022). The charter's value in, the active
    // theme's out: the same number for a theme without a design, the
    // theme's own `--radius`, `--spacing`, `--font-*` and `--letter-spacing`
    // for one that has it.

    /// A corner radius of the charter (10 a card, 6 a control, 4 a tab, 3 a tag).
    public static func radius(_ charter: CGFloat) -> CGFloat { palette.radius(charter) }

    /// A padding, a gap or a control's height of the charter.
    public static func space(_ charter: CGFloat) -> CGFloat { palette.space(charter) }

    /// The height or width of a control or a row of the charter: like
    /// `space`, but never under four fifths — a row still holds its text.
    public static func size(_ charter: CGFloat) -> CGFloat { palette.size(charter) }

    /// The theme's letter-spacing for a text of this size, in points; 0
    /// without one. A text with a tracking of its own adds it to this.
    public static func tracking(at size: CGFloat) -> CGFloat { palette.tracking(at: size) }

    /// The colour of the controls macOS draws — switches, segmented
    /// pickers, progress bars: an imported theme's accent (shadcn's Switch
    /// is `bg-primary`), macOS's own for a built-in theme.
    public static var controlTint: Color? { palette.design == nil ? nil : palette.accent }

    /// The theme's font for this size, weight and design — the system's
    /// when the theme names none. Text takes it through `themeFont(…)`,
    /// which also applies the letter-spacing.
    public static func font(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        palette.font(size: size, weight: weight, design: design)
    }

    /// The font of text that sets none — a field, a menu, a picker: the
    /// theme's sans at the system's body size. nil when the theme names no
    /// family of its own: the system's body font stays what it is.
    public static var bodyFont: Font? {
        guard let stack = palette.design?.fontSans,
              ThemeFonts.shared.familyName(for: stack) != nil else { return nil }
        return palette.font(size: 13)
    }

    /// The font of a table's header, which macOS draws: the theme's sans
    /// at the header's own small size — it would otherwise take the body
    /// font, larger than the rows under it. nil when the theme names no
    /// family of its own: the system's header stays what it is.
    public static var tableHeaderFont: Font? {
        bodyFont == nil ? nil : palette.font(size: 11, weight: .medium)
    }

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

    public static let ansiPalette: [Color] = [
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
