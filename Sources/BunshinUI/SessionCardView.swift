import BunshinCore
import SwiftUI

/// Carte de session (SES-03) : titre, badge d'état sémantique, aperçu.
public struct SessionCardView: View {
    public let title: String
    public let state: SessionState
    public let preview: String

    public init(title: String, state: SessionState, preview: String) {
        self.title = title
        self.state = state
        self.preview = preview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(DefaultTheme.badgeColor(for: state))
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(DefaultTheme.label(for: state))
                    .font(.caption)
                    .foregroundStyle(DefaultTheme.badgeColor(for: state))
            }
            Text(preview.isEmpty ? "—" : preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DefaultTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(12)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 11))
    }
}
