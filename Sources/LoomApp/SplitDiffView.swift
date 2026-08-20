import LoomGit
import LoomUI
import SwiftUI

/// GitHub-style side-by-side diff: per-file sections (path, +/- counts,
/// collapsible), aligned old/new columns with line-number gutters and
/// red/green tinted backgrounds.
/// A selection, ready to be sent to the review session — possibly spanning
/// several files, in which case the code carries per-file headers.
struct DiffSnippet {
    let spans: [DiffSelection.FileSpan]

    /// A GitHub comment anchors to ONE place: only a single-span selection
    /// can be commented or suggested on.
    var isAnchorable: Bool { spans.count == 1 }
    /// All spans in one file: a file-level GitHub comment can still carry it.
    var isSingleFile: Bool { Set(spans.map(\.file)).count == 1 }
    var file: String { spans.first?.file ?? "" }
    var firstLine: Int { spans.first?.firstLine ?? 0 }
    var lastLine: Int { spans.last?.lastLine ?? 0 }
    var lineCount: Int {
        spans.reduce(0) { $0 + $1.code.split(separator: "\n", omittingEmptySubsequences: false).count }
    }

    /// One file: just the code. Several: each block titled by its file, so
    /// the reader never has to guess where a line came from.
    var code: String {
        guard spans.count > 1 else { return spans.first?.code ?? "" }
        return spans
            .map { "// \($0.file) L\($0.firstLine)–L\($0.lastLine)\n\($0.code)" }
            .joined(separator: "\n\n")
    }

    /// What the bar shows: one file's range, or how many files are covered.
    var label: String {
        guard let first = spans.first else { return "" }
        if spans.count == 1 { return "\(first.file) L\(first.firstLine)–L\(first.lastLine)" }
        return "\(spans.count) blocks across \(Set(spans.map(\.file)).count) files"
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
    /// Posts a comment on a whole FILE (multi-hunk selections, "Select file").
    var onFileComment: ((String, String) -> Void)?
    /// Existing review comments, shown under the line they talk about.
    var comments: [GitHubService.ReviewComment] = []
    /// Replies inside a thread (thread's root comment id, text).
    var onReply: ((Int, String) -> Void)?
    /// Unified layout: one full-width column (deletions then additions) —
    /// whole lines stay readable; split keeps old/new aligned side by side.
    var unified = false

    @State private var collapsed: Set<String> = []
    /// The selection's two ends, addressed globally — an interval between two
    /// row identifiers naturally spans hunks AND files.
    @State private var anchor: DiffSelection.RowID?
    @State private var head: DiffSelection.RowID?
    /// Set while a drag is in flight (nil between drags).
    @State private var dragging = false
    /// What the action bar is composing, and its text.
    @State private var composer: Composer = .none
    @State private var draft = ""
    /// EVERY row's y span, in ONE coordinate space keyed by global row id.
    /// (A per-hunk dictionary meant each hunk overwrote the others' entries,
    /// so a drag in one file was resolved against another file's geometry —
    /// that is what selected lines nowhere near the cursor.)
    @State private var rowSpans: [DiffSelection.RowID: ClosedRange<CGFloat>] = [:]
    /// The mouse is up: only then do the actions appear — a bar following the
    /// cursor mid-drag is in the way of the very lines being picked.
    @State private var selectionSettled = false
    /// The action bar is draggable: it must never be the thing hiding the
    /// code being discussed.
    @State private var barOffset: CGSize = .zero
    @State private var barOffsetAtDragStart: CGSize = .zero
    /// The diff's own size, so the bar can never be dragged out of reach
    /// (the button that brings it back lives inside it).
    @State private var diffSize: CGSize = .zero

    var body: some View {
        // Lazy: a large PR materializes thousands of rows — only what is
        // visible gets built.
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(files.enumerated()), id: \.element.id) { fileIndex, file in
                fileSection(file, fileIndex: fileIndex)
            }
        }
        // ONE space for the whole diff: row positions and the drag's position
        // are then measured against the same origin, whatever file they are in.
        .coordinateSpace(name: Self.diffSpace)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: DiffSizeKey.self, value: geometry.size)
        })
        .onPreferenceChange(DiffSizeKey.self) { diffSize = $0 }
        .onPreferenceChange(DiffRowSpansKey.self) { spans in
            if !spans.isEmpty { rowSpans = spans }
        }
        .gesture(selectionDrag)
        .overlay(alignment: .topLeading) {
            // Anchored right under the SELECTION — an overlay at the content's
            // bottom floated next to the last file, screens away from the
            // lines being acted on. snippet, not just "a range exists": a
            // selection covering only collapsed files has nothing to act on.
            if selectionSettled, snippet != nil, let anchorY = selectionBottomY {
                quickActionBar
                    .padding(.leading, 44)
                    .offset(x: barOffset.width, y: anchorY + 8 + barOffset.height)
                    .transition(.opacity)
            }
        }
        .animation(.hover, value: selectionSettled)
        .onExitCommand { clearSelection() }
    }

    /// One drag for the entire diff — dragging past a file's last line simply
    /// continues into the next file's rows.
    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.diffSpace))
            .onChanged { value in
                // Outside every row (a file header, a comment thread, the gap
                // between cards): keep what we have rather than inventing a
                // nearest row — that guesswork is what selected stray lines.
                guard let current = rowAt(value.location.y) else { return }
                selectionSettled = false
                if !dragging {
                    dragging = true
                    let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    // Shift keeps the previous anchor: extend, don't restart.
                    if !shift || anchor == nil {
                        anchor = rowAt(value.startLocation.y) ?? current
                    }
                }
                head = current
            }
            .onEnded { _ in
                dragging = false
                if selection != nil { selectionSettled = true }
            }
    }

    private static let diffSpace = "loom.diff"

    /// The selection's ordered ends, once both exist.
    private var selection: (from: DiffSelection.RowID, to: DiffSelection.RowID)? {
        guard let anchor, let head else { return nil }
        return (min(anchor, head), max(anchor, head))
    }

    /// Selects every row of a file — the header button's action. Expands a
    /// collapsed file first: an invisible selection helps nobody.
    private func selectFile(_ index: Int, entry: DiffFileRows) {
        collapsed.remove(entry.file.path)
        guard let lastHunk = entry.hunkRows.indices.last,
              let lastRow = entry.hunkRows[lastHunk].indices.last else { return }
        anchor = DiffSelection.RowID(file: index, hunk: 0, row: 0)
        head = DiffSelection.RowID(file: index, hunk: lastHunk, row: lastRow)
        composer = .none
        draft = ""
        selectionSettled = true
    }

    private func clearSelection() {
        anchor = nil
        head = nil
        dragging = false
        composer = .none
        draft = ""
        selectionSettled = false
    }

    private func isSelected(_ id: DiffSelection.RowID) -> Bool {
        guard let selection else { return false }
        return id >= selection.from && id <= selection.to
    }

    /// The row under a y position in the diff's own space — nil when the
    /// cursor is between rows rather than on one.
    private func rowAt(_ y: CGFloat) -> DiffSelection.RowID? {
        rowSpans.first { $0.value.contains(y) }?.key
    }

    /// Bottom edge of the lowest visible selected row — where the action bar
    /// belongs. Selected rows are on screen (the user just dragged them).
    private var selectionBottomY: CGFloat? {
        guard let selection else { return nil }
        return rowSpans
            .filter { $0.key >= selection.from && $0.key <= selection.to }
            .map(\.value.upperBound)
            .max()
    }

    /// The selected rows as a snippet — grouping, clamping and markers all
    /// live in the tested model.
    private var snippet: DiffSnippet? {
        guard let selection else { return nil }
        let spans = DiffSelection.spans(in: files, from: selection.from, to: selection.to,
                                        skipping: collapsed)
        return spans.isEmpty ? nil : DiffSnippet(spans: spans)
    }

    /// What the composer field is currently writing.
    enum Composer: Equatable { case none, ask, comment, suggestion, fileComment }

    /// Floating bar over the diff: what is selected + what to do with it.
    /// Nothing leaves this bar without an explicit click.
    private var quickActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snippet {
                HStack(spacing: 10) {
                    // The grip: the bar must be movable off the very lines
                    // being discussed.
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .help("Drag to move")
                    Text(snippet.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                    Text("\(snippet.lineCount) lines")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                    Spacer(minLength: 8)
                    if barOffset != .zero {
                        HoverIconButton(systemImage: "arrow.counterclockwise",
                                        help: "Snap back to the bottom") {
                            withAnimation(.hover) { barOffset = .zero }
                            barOffsetAtDragStart = .zero
                        }
                    }
                    HoverIconButton(systemImage: "xmark", help: "Clear selection (esc)") {
                        clearSelection()
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        barOffset = clampedOffset(CGSize(
                            width: barOffsetAtDragStart.width + value.translation.width,
                            height: barOffsetAtDragStart.height + value.translation.height))
                    }
                    .onEnded { _ in barOffsetAtDragStart = barOffset })
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
                        // GitHub anchors a comment to ONE range: a selection
                        // spanning files can go to claude, not to a review.
                        if onComment != nil, snippet.isAnchorable {
                            GhostButton("Comment", systemImage: "text.bubble") {
                                composer = .comment
                            }
                            GhostButton("Suggest", systemImage: "plus.forwardslash.minus") {
                                // A suggestion EDITS these lines: start from them.
                                draft = strippedCode(snippet)
                                composer = .suggestion
                            }
                        } else if onFileComment != nil, snippet.isSingleFile {
                            // Several hunks of one file: GitHub still takes a
                            // comment on the file itself.
                            GhostButton("Comment on file", systemImage: "text.bubble") {
                                composer = .fileComment
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
        .contentShape(Rectangle())
        // The bar floats OVER the rows: without this absorber, a click on its
        // padding would fall through and reselect the line underneath.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in }.onEnded { _ in })
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(DefaultTheme.accent.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
    }

    /// The composer: one field, three destinations. Return submits, esc cancels.
    @ViewBuilder
    private func composerField(_ snippet: DiffSnippet) -> some View {
        let placeholder = switch composer {
        case .ask: "Ask claude about these lines…"
        case .comment: "Leave a review comment on these lines…"
        case .suggestion: "Your suggested replacement for these lines…"
        case .fileComment: "Leave a review comment on \(snippet.file)…"
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
        case .fileComment: onFileComment?(snippet.file, text)
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

    private func fileSection(_ entry: DiffFileRows, fileIndex: Int) -> some View {
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
                // The file-wide entry point to the same actions as a line
                // selection: select every row, the action bar takes over.
                HoverIconButton(systemImage: "selection.pin.in.out",
                                help: "Select the whole file") {
                    selectFile(fileIndex, entry: entry)
                }
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
                // Comments on the file itself (no line anchor) sit right
                // under the header, before the code.
                ForEach(fileThreads(file.path), id: \.root.id) { thread in
                    CommentThreadView(thread: thread, onReply: onReply)
                }
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    hunkView(hunk, rows: entry.hunkRows[hunkIndex],
                             file: file.path, fileIndex: fileIndex, hunkIndex: hunkIndex)
                }
            }
        }
        .background(DefaultTheme.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func hunkView(_ hunk: DiffParser.Hunk, rows: [DiffParser.SplitRow],
                          file: String, fileIndex: Int, hunkIndex: Int) -> some View {
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
                    let id = DiffSelection.RowID(file: fileIndex, hunk: hunkIndex, row: rowIndex)
                    Group {
                        if unified {
                            // Full width: the deletion (when any) stacked over
                            // the addition/context line, both with dual gutters.
                            VStack(alignment: .leading, spacing: 0) {
                                if let left = row.left, left.kind == .deletion {
                                    unifiedLine(left, isOld: true)
                                }
                                if let right = row.right {
                                    unifiedLine(right, isOld: false)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                side(row.left, isOld: true)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                Rectangle()
                                    .fill(DefaultTheme.cardBorder)
                                    .frame(width: 1)
                                side(row.right, isOld: false)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(Rectangle().fill(DefaultTheme.accent.opacity(
                        isSelected(id) ? 0.10 : 0)))
                    .background {
                        // Every row publishes its y span in the DIFF's space,
                        // under its global id — comment threads sit between
                        // rows, so positions are looked up, never computed.
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.diffSpace))
                            Color.clear.preference(key: DiffRowSpansKey.self,
                                                   value: [id: frame.minY...frame.maxY])
                        }
                    }
                    // GitHub-style: the threads anchored to this line sit
                    // right under it, inside the diff.
                    ForEach(threads(file: file, row: row), id: \.root.id) { thread in
                        CommentThreadView(thread: thread, onReply: onReply)
                    }
                }
            }
        }
    }

    /// Threads on the file itself — rendered under its header.
    private func fileThreads(_ file: String) -> [CommentThread] {
        comments
            .filter { $0.path == file && $0.isFileLevel && $0.replyToID == nil }
            .map { root in
                CommentThread(root: root,
                              replies: comments.filter { $0.replyToID == root.id })
            }
    }

    /// The comment threads anchored to a diff row: matched on the new-side
    /// line for additions/context, the old side for deletions.
    private func threads(file: String, row: DiffParser.SplitRow) -> [CommentThread] {
        guard !comments.isEmpty else { return [] }
        let roots = comments.filter { comment in
            guard comment.path == file, comment.replyToID == nil,
                  !comment.isFileLevel else { return false }
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

    /// Keeps the bar inside the diff, whichever selection it hangs under.
    private func clampedOffset(_ offset: CGSize) -> CGSize {
        guard diffSize.width > 0, diffSize.height > 0 else { return offset }
        let anchor = selectionBottomY ?? 0
        let horizontal = max(diffSize.width - 660, 0)
        return CGSize(width: min(max(offset.width, -20), horizontal),
                      height: min(max(offset.height, -anchor), diffSize.height - anchor - 80))
    }

    private struct DiffSizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    private struct DiffRowSpansKey: PreferenceKey {
        static let defaultValue: [DiffSelection.RowID: ClosedRange<CGFloat>] = [:]
        static func reduce(value: inout [DiffSelection.RowID: ClosedRange<CGFloat>],
                           nextValue: () -> [DiffSelection.RowID: ClosedRange<CGFloat>]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    struct CommentThread {
        let root: GitHubService.ReviewComment
        let replies: [GitHubService.ReviewComment]
    }

    /// One full-width unified line: old + new number gutters, then the text.
    @ViewBuilder
    private func unifiedLine(_ line: DiffParser.Line, isOld: Bool) -> some View {
        let background: Color = switch line.kind {
        case .addition: DefaultTheme.groupHeader.opacity(0.12)
        case .deletion: DefaultTheme.danger.opacity(0.12)
        case .context: .clear
        }
        HStack(alignment: .top, spacing: 8) {
            Text(line.oldNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 34, alignment: .trailing)
            Text(marker(line) + line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .context
                                 ? DefaultTheme.primaryText.opacity(0.75)
                                 : DefaultTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
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
