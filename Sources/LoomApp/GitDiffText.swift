import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// A diff or a commit, line by line in the theme's colours: additions,
/// deletions, hunk headers, file headers. Long files are laid out as they
/// come into view.
struct GitDiffText: View {
    let text: String

    /// Past this the rest is not drawn: a generated file's diff is not read here.
    private static let lineLimit = 4_000

    var body: some View {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = Array(all.prefix(Self.lineLimit))
        // Lines wrap: scrolling both ways set the text off to one side of
        // a panel this narrow.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .themeFont(size: 11, design: .monospaced)
                        .foregroundStyle(Self.ink(for: line))
                        .padding(.horizontal, DefaultTheme.space(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.fill(for: line))
                }
                if all.count > lines.count {
                    Text("… \(all.count - lines.count) more lines")
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(DefaultTheme.space(6))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
    }

    static func ink(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git")
            || line.hasPrefix("index ") { return DefaultTheme.mutedText }
        if line.hasPrefix("@@") { return DefaultTheme.accentInk }
        if line.hasPrefix("+") { return DefaultTheme.badgeColor(for: .working) }
        if line.hasPrefix("-") { return DefaultTheme.danger }
        return DefaultTheme.primaryText.opacity(0.85)
    }

    static func fill(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return DefaultTheme.badgeColor(for: .working).opacity(0.1) }
        if line.hasPrefix("-") { return DefaultTheme.danger.opacity(0.1) }
        return .clear
    }
}
