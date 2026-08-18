import LoomGit
import LoomUI
import SwiftUI

/// GitHub-style side-by-side diff: per-file sections (path, +/- counts,
/// collapsible), aligned old/new columns with line-number gutters and
/// red/green tinted backgrounds.
/// A selected span of diff lines, ready to be sent to the review session.
struct DiffSnippet {
    let file: String
    let firstLine: Int
    let lastLine: Int
    let code: String
}

/// Precomputed display model: parsing and row pairing happen ONCE, off the
/// main thread, when the diff loads — the view was re-running both on every
/// render (every hover, every keystroke), which crawled on large PRs.
struct DiffFileRows: Identifiable, Equatable, Sendable {
    let file: DiffParser.File
    /// splitRows for each hunk, same order as file.hunks.
    let hunkRows: [[DiffParser.SplitRow]]
    var id: String { file.path }

    static func compute(_ files: [DiffParser.File]) -> [DiffFileRows] {
        files.map { DiffFileRows(file: $0, hunkRows: $0.hunks.map(DiffParser.splitRows)) }
    }
}

struct SplitDiffView: View {
    let files: [DiffFileRows]
    /// Phase 4 — quick actions on a line selection. nil hides the bar's
    /// session actions (Copy always works).
    var onExplain: ((DiffSnippet) -> Void)?
    var onAsk: ((DiffSnippet, String) -> Void)?

    @State private var collapsed: Set<String> = []
    /// Selection: click anchors, shift-click extends — one hunk at a time.
    @State private var anchor: SelectionPoint?
    @State private var range: SelectionRange?
    @State private var askText = ""
    @State private var asking = false

    struct SelectionPoint: Equatable { let file: String; let hunk: Int; let row: Int }
    struct SelectionRange: Equatable { let file: String; let hunk: Int; let rows: ClosedRange<Int> }

    var body: some View {
        // Lazy: a large PR materializes thousands of rows — only what is
        // visible gets built.
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(files) { file in
                fileSection(file)
            }
        }
        .overlay(alignment: .bottom) {
            if range != nil { quickActionBar }
        }
        .onExitCommand { clearSelection() }
    }

    private func clearSelection() {
        anchor = nil
        range = nil
        asking = false
        askText = ""
    }

    private func handleTap(file: String, hunk: Int, row: Int) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shift, let anchor, anchor.file == file, anchor.hunk == hunk {
            range = SelectionRange(file: file, hunk: hunk,
                                   rows: min(anchor.row, row)...max(anchor.row, row))
        } else {
            anchor = SelectionPoint(file: file, hunk: hunk, row: row)
            range = SelectionRange(file: file, hunk: hunk, rows: row...row)
        }
    }

    private func isSelected(file: String, hunk: Int, row: Int) -> Bool {
        guard let range else { return false }
        return range.file == file && range.hunk == hunk && range.rows.contains(row)
    }

    /// The selected rows as a snippet: the NEW side when present, else the
    /// old — with +/− markers so the agent sees what changed.
    private var snippet: DiffSnippet? {
        guard let range,
              let file = files.first(where: { $0.id == range.file }),
              range.hunk < file.hunkRows.count else { return nil }
        let rows = file.hunkRows[range.hunk]
        let picked = range.rows.clamped(to: 0...(rows.count - 1))
        var lines: [String] = []
        var numbers: [Int] = []
        for index in picked {
            let row = rows[index]
            if let left = row.left, row.right == nil {
                lines.append("- " + left.text)
                left.oldNumber.map { numbers.append($0) }
            }
            if let right = row.right {
                lines.append((row.left == nil && right.kind == .addition ? "+ " :
                              right.kind == .addition ? "+ " : "  ") + right.text)
                right.newNumber.map { numbers.append($0) }
            }
        }
        guard !lines.isEmpty else { return nil }
        return DiffSnippet(file: range.file,
                           firstLine: numbers.min() ?? 0,
                           lastLine: numbers.max() ?? 0,
                           code: lines.joined(separator: "\n"))
    }

    /// Floating bar over the diff: what is selected + what to do with it.
    private var quickActionBar: some View {
        HStack(spacing: 10) {
            if let snippet {
                Text("\(snippet.file) L\(snippet.firstLine)–\(snippet.lastLine)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
                if asking {
                    TextField("Ask about these lines…", text: $askText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 240)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                        .onSubmit {
                            let question = askText.trimmingCharacters(in: .whitespaces)
                            guard !question.isEmpty else { return }
                            onAsk?(snippet, question)
                            clearSelection()
                        }
                } else {
                    if onExplain != nil {
                        AccentButton("Explain these lines") {
                            onExplain?(snippet)
                            clearSelection()
                        }
                    }
                    if onAsk != nil {
                        GhostButton("Ask…", systemImage: "bubble.left") { asking = true }
                    }
                    GhostButton("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet.code, forType: .string)
                        clearSelection()
                    }
                }
                HoverIconButton(systemImage: "xmark", help: "Clear selection (esc)") {
                    clearSelection()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(DefaultTheme.accent.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        .padding(.bottom, 10)
    }

    private func fileSection(_ entry: DiffFileRows) -> some View {
        let file = entry.file
        return VStack(alignment: .leading, spacing: 0) {
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
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    hunkView(hunk, rows: entry.hunkRows[hunkIndex],
                             file: file.path, hunkIndex: hunkIndex)
                }
            }
        }
        .background(DefaultTheme.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func hunkView(_ hunk: DiffParser.Hunk, rows: [DiffParser.SplitRow],
                          file: String, hunkIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.branch)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DefaultTheme.surface)
            // Two EQUAL columns filling the available width — a nested
            // horizontal ScrollView proposed infinite widths and the rows
            // rendered blank; long lines truncate with a tail, like GitHub's
            // collapsed view.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        side(row.left, isOld: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Rectangle()
                            .fill(DefaultTheme.cardBorder)
                            .frame(width: 1)
                        side(row.right, isOld: false)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // Line selection: click anchors, shift-click extends.
                    .overlay(Rectangle().fill(DefaultTheme.accent.opacity(
                        isSelected(file: file, hunk: hunkIndex, row: rowIndex) ? 0.10 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(file: file, hunk: hunkIndex, row: rowIndex) }
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
        let text = Text(line.map { marker($0) + $0.text } ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(line?.kind == .context || line == nil
                             ? DefaultTheme.primaryText.opacity(0.75)
                             : DefaultTheme.primaryText)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)
        HStack(alignment: .top, spacing: 8) {
            Text(line.flatMap { isOld ? $0.oldNumber : $0.newNumber }.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 34, alignment: .trailing)
            // A tooltip means a tracking area PER LINE — thousands on a big
            // PR. Only lines long enough to plausibly truncate get one.
            if let full = line?.text, full.count > 110 {
                text.help(full)
            } else {
                text
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
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
