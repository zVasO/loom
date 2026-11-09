import LoomCore
import SwiftUI

// The visual vocabulary of the reference: tab pills, mono tags,
// status dots, accent-filled buttons. Everything clickable
// responds to hover — same recipe everywhere: background rises, text
// lights up, 120 ms easeOut.

public extension Animation {
    /// The hover transition shared by all controls.
    static var hover: Animation { .easeOut(duration: 0.12) }
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
            HStack(spacing: 6) {
                if let icon { LucideIcon(icon, size: 14) }
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText : DefaultTheme.mutedText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isActive ? DefaultTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
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
        HStack(spacing: 6) {
            if showsDot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.32), lineWidth: 1))
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
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(DefaultTheme.accentText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DefaultTheme.accent, in: RoundedRectangle(cornerRadius: 9))
            .brightness(hovered ? 0.06 : 0)
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
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12)) }
                if let title { Text(title).font(.system(size: 13)) }
            }
            .foregroundStyle(role == .destructive ? DefaultTheme.danger
                             : hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovered ? (role == .destructive ? DefaultTheme.danger.opacity(0.12)
                                                        : DefaultTheme.surfaceRaised)
                                : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
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
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? DefaultTheme.accent
                                 : hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .frame(width: 30, height: 26)
                .background(isActive ? DefaultTheme.surfaceRaised
                            : hovered ? DefaultTheme.surfaceRaised.opacity(0.7) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
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
        HStack(spacing: 5) {
            Circle().fill(DefaultTheme.badgeColor(for: state)).frame(width: 6, height: 6)
            Text(DefaultTheme.label(for: state))
                .font(.system(size: 11))
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
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
            Text(text).font(.system(size: 11, design: .monospaced))
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
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DefaultTheme.line2, lineWidth: 1))
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
                .stroke(DefaultTheme.cardBorder, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(width: size, height: size)
    }
}
