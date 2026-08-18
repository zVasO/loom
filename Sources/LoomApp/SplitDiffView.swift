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
    /// Adds the lines to the review session's input WITHOUT submitting —
    /// nil when no session pane is open.
    var onAddToSession: ((DiffSnippet) -> Void)?
    /// Posts a review comment on the PR; the Bool asks for a ```suggestion
    /// block (GitHub renders it as a one-click apply).
    var onComment: ((DiffSnippet, String, Bool) -> Void)?
    /// Existing review comments, shown under the line they talk about.
    var comments: [GitHubService.ReviewComment] = []
    /// Replies inside a thread (thread's root comment id, text).
    var onReply: ((Int, String) -> Void)?

    @State private var collapsed: Set<String> = []
    /// Selection: click anchors, shift-click extends — one hunk at a time.
    @State private var anchor: SelectionPoint?
    @State private var range: SelectionRange?
    /// What the action bar is composing, and its text.
    @State private var composer: Composer = .none
    @State private var draft = ""
    /// Row index → its y span in the hunk: comment threads break the uniform
    /// row height, so a drag's position is looked up, not divided.
    @State private var rowSpans: [Int: ClosedRange<CGFloat>] = [:]

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
        composer = .none
        draft = ""
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

    /// What the composer field is currently writing.
    enum Composer: Equatable { case none, ask, comment, suggestion }

    /// Floating bar over the diff: what is selected + what to do with it.
    /// Nothing leaves this bar without an explicit click.
    private var quickActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snippet {
                HStack(spacing: 10) {
                    Text("\(snippet.file) L\(snippet.firstLine)–\(snippet.lastLine)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                    Text("\(snippet.lastLine - snippet.firstLine + 1) lines")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                    Spacer(minLength: 8)
                    HoverIconButton(systemImage: "xmark", help: "Clear selection (esc)") {
                        clearSelection()
                    }
                }
                if composer == .none {
                    HStack(spacing: 8) {
                        if onAddToSession != nil {
                            AccentButton("Add to claude session", systemImage: "sparkles") {
                                onAddToSession?(snippet)
                                clearSelection()
                            }
                        } else if onExplain != nil {
                            AccentButton("Explain these lines") {
                                onExplain?(snippet)
                                clearSelection()
                            }
                        }
                        if onAsk != nil {
                            GhostButton("Ask claude…", systemImage: "bubble.left") {
                                composer = .ask
                            }
                        }
                        if onComment != nil {
                            GhostButton("Comment", systemImage: "text.bubble") {
                                composer = .comment
                            }
                            GhostButton("Suggest", systemImage: "plus.forwardslash.minus") {
                                // A suggestion EDITS these lines: start from them.
                                draft = strippedCode(snippet)
                                composer = .suggestion
                            }
                        }
                        GhostButton("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet.code, forType: .string)
                            clearSelection()
                        }
                    }
                } else {
                    composerField(snippet)
                }
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(DefaultTheme.accent.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        .padding(.bottom, 10)
    }

    /// The composer: one field, three destinations. Return submits, esc cancels.
    @ViewBuilder
    private func composerField(_ snippet: DiffSnippet) -> some View {
        let placeholder = switch composer {
        case .ask: "Ask claude about these lines…"
        case .comment: "Leave a review comment on these lines…"
        case .suggestion: "Your suggested replacement for these lines…"
        case .none: ""
        }
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12,
                              design: composer == .suggestion ? .monospaced : .default))
                .lineLimit(composer == .suggestion ? 3...10 : 1...5)
                .padding(8)
                .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { submitComposer(snippet) }
            HStack(spacing: 8) {
                if composer == .suggestion {
                    Text("Posted as a GitHub suggestion — one click to apply.")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                Spacer()
                GhostButton("Cancel") { composer = .none; draft = "" }
                AccentButton(composer == .ask ? "Send" : "Post") { submitComposer(snippet) }
            }
        }
    }

    private func submitComposer(_ snippet: DiffSnippet) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch composer {
        case .ask: onAsk?(snippet, text)
        case .comment: onComment?(snippet, text, false)
        case .suggestion: onComment?(snippet, draft, true)
        case .none: break
        }
        clearSelection()
    }

    /// The selected lines without diff markers — what a suggestion edits
    /// (deletions dropped: they are gone in the new version).
    private func strippedCode(_ snippet: DiffSnippet) -> String {
        snippet.code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("- ") }
            .map { $0.hasPrefix("+ ") || $0.hasPrefix("  ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
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
                    .overlay(Rectangle().fill(DefaultTheme.accent.opacity(
                        isSelected(file: file, hunk: hunkIndex, row: rowIndex) ? 0.10 : 0)))
                    .background {
                        // Each row publishes its y span: comment threads sit
                        // between rows, so a drag's y can no longer be divided
                        // by a uniform height — it is looked up.
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named("hunk"))
                            Color.clear.preference(key: DiffRowSpansKey.self,
                                                   value: [rowIndex: frame.minY...frame.maxY])
                        }
                    }
                    // GitHub-style: the threads anchored to this line sit
                    // right under it, inside the diff.
                    ForEach(threads(file: file, row: row), id: \.root.id) { thread in
                        CommentThreadView(thread: thread, onReply: onReply)
                    }
                }
            }
            .coordinateSpace(name: "hunk")
            .contentShape(Rectangle())
            // Press-and-drag selection: press anchors, dragging extends row
            // by row, releasing hands the snippet over (shift-press extends
            // from the previous anchor instead).
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !rowSpans.isEmpty else { return }
                    let row = rowAt(value.location.y, count: rows.count)
                    let start = rowAt(value.startLocation.y, count: rows.count)
                    let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    if shift, let anchor, anchor.file == file, anchor.hunk == hunkIndex {
                        range = SelectionRange(file: file, hunk: hunkIndex,
                                               rows: min(anchor.row, row)...max(anchor.row, row))
                    } else {
                        if anchor?.file != file || anchor?.hunk != hunkIndex
                            || anchor?.row != start {
                            anchor = SelectionPoint(file: file, hunk: hunkIndex, row: start)
                        }
                        range = SelectionRange(file: file, hunk: hunkIndex,
                                               rows: min(start, row)...max(start, row))
                    }
                }
                // Releasing only ARMS the action bar — the selection is never
                // sent anywhere on its own.
                .onEnded { _ in })
        }
        .onPreferenceChange(DiffRowSpansKey.self) { spans in
            if !spans.isEmpty { rowSpans = spans }
        }
    }

    /// Which row a drag's y lands on: the span containing it, else the
    /// nearest one (dragging past the last row selects to the end).
    private func rowAt(_ y: CGFloat, count: Int) -> Int {
        if let hit = rowSpans.first(where: { $0.value.contains(y) })?.key { return hit }
        let nearest = rowSpans.min {
            abs(($0.value.lowerBound + $0.value.upperBound) / 2 - y)
                < abs(($1.value.lowerBound + $1.value.upperBound) / 2 - y)
        }
        return min(max(nearest?.key ?? 0, 0), max(count - 1, 0))
    }

    /// The comment threads anchored to a diff row: matched on the new-side
    /// line for additions/context, the old side for deletions.
    private func threads(file: String, row: DiffParser.SplitRow) -> [CommentThread] {
        guard !comments.isEmpty else { return [] }
        let roots = comments.filter { comment in
            guard comment.path == file, comment.replyToID == nil else { return false }
            let number = comment.side == "LEFT" ? row.left?.oldNumber : row.right?.newNumber
            guard let number else { return false }
            // A multi-line comment hangs under its LAST line, like GitHub.
            return comment.line == number
        }
        return roots.map { root in
            CommentThread(root: root,
                          replies: comments.filter { $0.replyToID == root.id })
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
            // No .textSelection here: it captured the mouse and broke the
            // press-and-drag line selection (Copy lives in the action bar).
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

    private struct DiffRowSpansKey: PreferenceKey {
        static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]
        static func reduce(value: inout [Int: ClosedRange<CGFloat>],
                           nextValue: () -> [Int: ClosedRange<CGFloat>]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    struct CommentThread {
        let root: GitHubService.ReviewComment
        let replies: [GitHubService.ReviewComment]
    }

    private func marker(_ line: DiffParser.Line) -> String {
        switch line.kind {
        case .addition: "+ "
        case .deletion: "− "
        case .context: "  "
        }
    }
}

/// A review thread, shown inside the diff under the line it talks about —
/// root comment, its replies, and an inline reply field.
private struct CommentThreadView: View {
    let thread: SplitDiffView.CommentThread
    let onReply: ((Int, String) -> Void)?
    @State private var replying = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            comment(thread.root)
            ForEach(thread.replies) { reply in
                comment(reply)
                    .padding(.leading, 18)
            }
            if let onReply {
                if replying {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Reply…", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(1...5)
                            .padding(8)
                            .background(DefaultTheme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 7))
                        HStack(spacing: 8) {
                            Spacer()
                            GhostButton("Cancel") { replying = false; draft = "" }
                            AccentButton("Reply") {
                                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                onReply(thread.root.id, text)
                                replying = false
                                draft = ""
                            }
                        }
                    }
                } else {
                    GhostButton("Reply", systemImage: "arrowshape.turn.up.left") {
                        replying = true
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(DefaultTheme.accent.opacity(0.7)).frame(width: 3)
        }
    }

    private func comment(_ item: GitHubService.ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AsyncImage(url: URL(string: "https://github.com/\(item.author).png?size=48")) {
                    image in image.resizable()
                } placeholder: {
                    Circle().fill(DefaultTheme.surfaceRaised)
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                Text("@" + item.author)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                if let start = item.startLine, start < item.line {
                    Text("L\(start)–L\(item.line)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                if item.isOutdated {
                    Text("outdated")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                Spacer()
            }
            MarkdownBlockView(item.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
