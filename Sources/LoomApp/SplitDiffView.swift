import LoomGit
import LoomUI
import SwiftUI

/// GitHub-style side-by-side diff: per-file sections (path, +/- counts,
/// collapsible), aligned old/new columns with line-number gutters and
/// red/green tinted backgrounds.
struct SplitDiffView: View {
    let files: [DiffParser.File]
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files) { file in
                fileSection(file)
            }
        }
    }

    private func fileSection(_ file: DiffParser.File) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: collapsed.contains(file.path) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text(file.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text("+\(file.additions)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.groupHeader)
                Text("−\(file.deletions)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.danger)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(DefaultTheme.surfaceRaised)
            .contentShape(Rectangle())
            .onTapGesture {
                if collapsed.contains(file.path) {
                    collapsed.remove(file.path)
                } else {
                    collapsed.insert(file.path)
                }
            }

            if !collapsed.contains(file.path) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkView(hunk)
                }
            }
        }
        .background(DefaultTheme.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func hunkView(_ hunk: DiffParser.Hunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.branch)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DefaultTheme.surface)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(DiffParser.splitRows(hunk).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 0) {
                            side(row.left, isOld: true)
                            Rectangle()
                                .fill(DefaultTheme.cardBorder)
                                .frame(width: 1)
                            side(row.right, isOld: false)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// One half of a row: number gutter + text, tinted by kind. An absent
    /// side (unpaired add/delete) renders as a dimmed void, like GitHub.
    @ViewBuilder
    private func side(_ line: DiffParser.Line?, isOld: Bool) -> some View {
        let background: Color = switch line?.kind {
        case .addition: DefaultTheme.groupHeader.opacity(0.12)
        case .deletion: DefaultTheme.danger.opacity(0.12)
        case .context, nil: .clear
        }
        HStack(alignment: .top, spacing: 8) {
            Text(line.flatMap { isOld ? $0.oldNumber : $0.newNumber }.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 34, alignment: .trailing)
            Text(line.map { marker($0) + $0.text } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line?.kind == .context || line == nil
                                 ? DefaultTheme.primaryText.opacity(0.75)
                                 : DefaultTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
        .background(line == nil ? DefaultTheme.surface.opacity(0.4) : background)
    }

    private func marker(_ line: DiffParser.Line) -> String {
        switch line.kind {
        case .addition: "+ "
        case .deletion: "− "
        case .context: "  "
        }
    }
}
