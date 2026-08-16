import BunshinCore
import SwiftUI

// Le vocabulaire visuel de la référence : pilules d'onglets, tags mono,
// points de statut, boutons pleins à l'accent.

/// Onglet de la barre de navigation (Projects / Sessions).
public struct NavTab: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    public init(_ title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? DefaultTheme.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Bouton plein à l'accent (« + Add Project », « Lancer »).
public struct AccentButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

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
        }
        .buttonStyle(.plain)
    }
}

/// Bouton discret (« Import », « Git », icônes de la barre).
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

    public var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12)) }
                if let title { Text(title).font(.system(size: 13)) }
            }
            .foregroundStyle(role == .destructive ? DefaultTheme.danger : DefaultTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Point + libellé de statut (● working).
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

/// Tag mono (branche `bunshin/corrige-cache`, chemin…).
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
