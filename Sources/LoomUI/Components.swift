import LoomCore
import SwiftUI

// The visual vocabulary of the landing page's charter: tab pills, mono
// tags, status dots, accent-filled buttons, hairline edges. Everything
// clickable responds to hover the same way — the surface rises a step, the
// edge lightens a step, the text lights up — in 160 ms on a sharp
// ease-out, never a slow fade or a bounce.

public extension Animation {
    /// The hover transition shared by all controls: cubic-bezier(0.16, 1, 0.3, 1), 160 ms.
    static var hover: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.16) }
}

/// Brightens the control on hover — for hand-rolled filled buttons
/// (the bar's "+", ⌘K…) that do not go through a component.
public struct HoverBrightnessModifier: ViewModifier {
    let amount: Double
    @State private var hovered = false

    public func body(content: Content) -> some View {
        content
            .brightness(hovered ? amount : 0)
            .onHover { hovered = $0 }
            .animation(.hover, value: hovered)
    }
}

/// Raises the surface on hover — for clickable rows (stacks, lists).
public struct HoverSurfaceModifier: ViewModifier {
    let opacity: Double
    @State private var hovered = false

    public func body(content: Content) -> some View {
        content
            .background(hovered ? DefaultTheme.surfaceRaised.opacity(opacity) : .clear)
            .onHover { hovered = $0 }
            .animation(.hover, value: hovered)
    }
}

public extension View {
    func hoverBrightness(_ amount: Double = 0.06) -> some View {
        modifier(HoverBrightnessModifier(amount: amount))
    }

    func hoverSurface(_ opacity: Double = 1) -> some View {
        modifier(HoverSurfaceModifier(opacity: opacity))
    }
}

/// Navigation bar tab (Projects / Sessions): a Lucide icon and a label; the
/// active one sits on a raised pill with a hairline edge.
public struct NavTab: View {
    let title: String
    let icon: LucideIcon.Glyph?
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    public init(_ title: String, icon: LucideIcon.Glyph? = nil, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(6)) {
                if let icon { LucideIcon(icon, size: 14) }
                Text(title).themeFont(size: 12)
            }
            .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText : DefaultTheme.mutedText)
            .padding(.horizontal, DefaultTheme.space(8))
            .frame(height: DefaultTheme.size(24))
            .background(isActive ? DefaultTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(4))
                .strokeBorder(isActive ? DefaultTheme.line : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// A status tag: mono capitals in the colour of what it reports, on a 7 %
/// wash with a 32 % edge ("● HOOKS ONLINE", "LIVE").
public struct StatusTag: View {
    let text: String
    let color: Color
    let showsDot: Bool

    public init(_ text: String, color: Color, dot: Bool = true) {
        self.text = text
        self.color = color
        self.showsDot = dot
    }

    public var body: some View {
        HStack(spacing: DefaultTheme.space(6)) {
            if showsDot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text.uppercased())
                .themeFont(size: 10.5, weight: .medium, design: .monospaced, tracking: 0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DefaultTheme.space(6))
        .frame(height: DefaultTheme.size(20))
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: DefaultTheme.radius(3)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(3)).strokeBorder(color.opacity(0.32), lineWidth: 1))
        .fixedSize()
    }
}

/// Accent-filled button ("+ Add Project", "Launch").
public struct AccentButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    @State private var hovered = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(8)) {
                if let systemImage { AppIcon(systemImage, size: 14) }
                Text(title).themeFont(size: 13, weight: .medium)
            }
            .foregroundStyle(DefaultTheme.accentText)
            .padding(.horizontal, DefaultTheme.space(14))
            .frame(height: DefaultTheme.size(32))
            .background(DefaultTheme.accent, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .brightness(hovered ? 0.06 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Discreet button ("Import", "Git", bar icons).
public struct GhostButton: View {
    let title: String?
    let systemImage: String?
    let role: ButtonRole?
    let action: () -> Void

    public init(_ title: String? = nil, systemImage: String? = nil,
                role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    @State private var hovered = false

    public var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: DefaultTheme.space(6)) {
                if let systemImage { AppIcon(systemImage, size: 14) }
                if let title { Text(title).themeFont(size: 12.5) }
            }
            .foregroundStyle(role == .destructive ? DefaultTheme.danger
                             : hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(10))
            .frame(height: DefaultTheme.size(28))
            .background(hovered ? (role == .destructive ? DefaultTheme.danger.opacity(0.12)
                                                        : DefaultTheme.surfaceRaised)
                                : .clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                .strokeBorder(hovered ? DefaultTheme.line : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Icon button of the top bar (Mission Control, browser, usage, settings):
/// one size and one hover for all of them. A transparent glyph shows no
/// brightness change, so the hover raises a surface and lights the glyph,
/// like the tabs beside it. `isActive`: the screen it opens is showing.
public struct BarIconButton: View {
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    public init(systemImage: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            AppIcon(systemImage, size: 15)
                .foregroundStyle(isActive ? DefaultTheme.accentInk
                                 : hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .frame(width: DefaultTheme.size(28), height: DefaultTheme.size(26))
                .background(isActive ? DefaultTheme.surfaceRaised
                            : hovered ? DefaultTheme.surfaceRaised.opacity(0.7) : .clear,
                            in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                    .strokeBorder(isActive ? DefaultTheme.line2 : hovered ? DefaultTheme.line : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Dot + status label (● working).
public struct StatusLabel: View {
    let state: SessionState

    public init(_ state: SessionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            Circle().fill(DefaultTheme.badgeColor(for: state)).frame(width: 6, height: 6)
            Text(DefaultTheme.label(for: state))
                .themeFont(size: 11, design: .monospaced, tracking: 0.22)
                .foregroundStyle(DefaultTheme.badgeColor(for: state))
        }
    }
}

/// Mono tag (`loom/fix-cache` branch, path…).
public struct MonoTag: View {
    let text: String
    let systemImage: String?
    /// nil = the theme's branch color, resolved at render time (a default
    /// argument would be evaluated outside the main actor).
    let color: Color?

    public init(_ text: String, systemImage: String? = nil, color: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        HStack(spacing: DefaultTheme.space(5)) {
            if let systemImage { AppIcon(systemImage, size: 12) }
            Text(text).themeFont(size: 11.5, design: .monospaced)
        }
        .foregroundStyle(color ?? DefaultTheme.branch)
        .lineLimit(1)
    }
}

/// A keyboard key, drawn the way shortcut hints show it (⌘, ↵, K…).
public struct KeyCap: View {
    let key: String

    public init(_ key: String) {
        self.key = key
    }

    public var body: some View {
        Text(key)
            .themeFont(size: 10.5, weight: .medium, design: .monospaced)
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(4))
            .frame(minWidth: DefaultTheme.size(18), minHeight: DefaultTheme.size(18))
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(4)).strokeBorder(DefaultTheme.line2, lineWidth: 1))
            .fixedSize()
    }
}

/// Context ring: a track that fills clockwise from the top as the session's
/// window fills. `nil` draws the track alone — nothing recorded yet. The
/// colour is the caller's: LoomUI knows neither the level nor the model.
public struct ContextRing: View {
    let fraction: Double?
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat

    public init(fraction: Double?, color: Color, size: CGFloat = 14, lineWidth: CGFloat = 2) {
        self.fraction = fraction
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(DefaultTheme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Fields

/// A text field as the theme draws one. The charter leaves a bordered
/// field to macOS; an imported theme followed whole draws it itself —
/// shadcn's Input: the theme's radius, `border-input`, `shadow-xs` — so a
/// form does not mix the system's rounded fields with the theme's.
struct ThemedField: ViewModifier {
    func body(content: Content) -> some View {
        if DefaultTheme.redraws {
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(4))
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                .fieldEdge()
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

public extension View {
    /// What `.textFieldStyle(.roundedBorder)` was: macOS's field under the
    /// charter, the theme's own under an imported theme followed whole.
    func themedField() -> some View { modifier(ThemedField()) }

    /// The edge shadcn gives a Card (`border`), for a card the charter
    /// draws as a fill alone: nothing under the charter; under an imported
    /// theme followed whole, the card's edge — its shadow falls on two
    /// sides only, and a card without an edge looked cut on the others.
    @MainActor
    func cardEdge(radius: CGFloat = 10) -> some View {
        overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(radius))
            .strokeBorder(DefaultTheme.redraws ? DefaultTheme.cardBorder : Color.clear, lineWidth: 1))
    }

    /// The edge and the shadow shadcn gives an Input, for a field the
    /// charter draws bare (a filter in a sidebar): nothing under the
    /// charter, the theme's under an imported theme followed whole.
    @MainActor
    func fieldEdge(radius: CGFloat = 6) -> some View {
        overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(radius))
            .strokeBorder(DefaultTheme.redraws ? DefaultTheme.fieldBorder : Color.clear, lineWidth: 1))
            .themeShadow(.xs, radius: radius)
    }
}

// MARK: - Toolbar buttons

/// A toolbar's button as the theme draws one: its raised surface, its
/// radius, its edge.
struct ThemedBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DefaultTheme.secondaryText)
            .frame(minWidth: DefaultTheme.size(28), minHeight: DefaultTheme.size(22))
            .padding(.horizontal, DefaultTheme.space(3))
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                .strokeBorder(DefaultTheme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct ThemedBarButtons: ViewModifier {
    func body(content: Content) -> some View {
        if DefaultTheme.redraws {
            content.buttonStyle(ThemedBarButtonStyle())
        } else {
            content
        }
    }
}

public extension View {
    /// For the buttons of a toolbar the charter leaves to macOS (a web
    /// panel's back, forward, reload): macOS's under the charter, the
    /// theme's own under an imported theme followed whole — beside a
    /// field the theme draws, they no longer look like another app's.
    func themedBarButtons() -> some View { modifier(ThemedBarButtons()) }
}
