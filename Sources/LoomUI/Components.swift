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

/// Navigation bar tab (Projects / Sessions).
public struct NavTab: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    public init(_ title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                     : DefaultTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? DefaultTheme.surfaceRaised
                            : hovered ? DefaultTheme.surfaceRaised.opacity(0.6) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
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

/// Mono tag (`loom/corrige-cache` branch, path…).
public struct MonoTag: View {
    let text: String
    let systemImage: String?
    let color: Color

    public init(_ text: String, systemImage: String? = nil, color: Color = DefaultTheme.branch) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
            Text(text).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }
}
