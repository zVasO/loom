import LoomGit
import LoomUI
import SwiftUI

/// A PR found outside a project's list — the inbox, a GitHub search: number,
/// title, author, age, labels. Clicking opens it in its project (or asks to
/// clone the repository first).
struct PRHitRow: View {
    let hit: GitHubService.PRSearchHit
    let isSelected: Bool
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("#\(hit.number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text("@" + hit.author)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                    if !hit.updatedAt.isEmpty {
                        Text(Self.age(hit.updatedAt))
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.mutedText)
                    }
                    ForEach(hit.labels.prefix(2), id: \.name) { PRChips.label($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hit.isDraft {
                Text("draft")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(isSelected ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }

    /// One formatter for every row: ISO8601DateFormatter is among the most
    /// expensive objects Foundation builds, and one was made per row per pass.
    private static let iso = ISO8601DateFormatter()

    /// "3 d", "5 h", "12 min" — from GitHub's ISO-8601 timestamp.
    static func age(_ iso: String, now: Date = Date()) -> String {
        guard let date = Self.iso.date(from: iso) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}

/// A repository of the catalog that is not a project yet: name, visibility,
/// and the one action — add it (clone) — plus hide in the context menu.
struct CatalogRepoRow: View {
    let repo: GitHubService.Repository
    let cloning: Bool
    let onAdd: () -> Void
    let onHide: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: repo.isPrivate ? "lock" : "globe")
                .font(.system(size: 9))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 12)
                .help(repo.isPrivate ? "Private" : "Public")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(repo.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .lineLimit(1)
                    if repo.isFork {
                        Image(systemName: "tuningfork")
                            .font(.system(size: 8))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .help("Fork")
                    }
                }
                if !repo.description.isEmpty {
                    Text(repo.description)
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if cloning {
                ProgressView().controlSize(.mini)
                    .help("Cloning…")
            } else if hovered {
                HoverIconButton(systemImage: "plus.circle", help: "Clone and add as a project",
                                action: onAdd)
            } else if !repo.pushedAt.isEmpty {
                Text(PRHitRow.age(repo.pushedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(DefaultTheme.mutedText)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .help(repo.description.isEmpty ? repo.nameWithOwner : repo.nameWithOwner + " — " + repo.description)
        .onTapGesture(count: 2, perform: onAdd)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .contextMenu {
            Button("Clone and add as a project", action: onAdd)
            Button("Open on GitHub") {
                if let url = URL(string: "https://github.com/" + repo.nameWithOwner) {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Hide this repository", action: onHide)
        }
    }
}
