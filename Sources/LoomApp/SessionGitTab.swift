import AppKit
import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// A session's Git, as a tab of its stack — one per session, like the
/// agent's browser: the full width for what a side panel squeezed. On the
/// left, what changed and the branch's history; on the right, the diff of
/// the file or of the commit picked. Commit, push and PR on top.
struct SessionGitTab: View {
    let model: AppModel
    let sessionID: SessionID
    /// Back to the session's terminal.
    let onShowSession: () -> Void
    let onClose: () -> Void
    /// A review session was started on this worktree: show it.
    let onReviewStarted: (SessionID) -> Void

    enum Side: String, CaseIterable {
        case changes = "Changes", history = "History"
    }

    @State private var side = Side.changes
    @State private var data: AppModel.GitPanelData?
    @State private var loaded = false
    /// The file whose diff shows; nil shows them all.
    @State private var file: String?
    @State private var commits: [GitService.Commit]?
    @State private var commit: GitService.Commit?
    @State private var commitText: String?
    /// The picked commit's files, and the one whose diff shows (nil: all).
    @State private var commitFiles: [GitService.FileSection] = []
    @State private var commitFile: String?
    @State private var commitMessage = ""
    /// The diff shown, as the review's diff view takes it: parsed and paired
    /// rows, then their syntax colours.
    @State private var rows: DiffPipeline.Rows?
    @State private var colours = DiffHighlights.none
    @State private var unified = UserDefaults.standard.bool(forKey: "loom.diff.unified")
    @Environment(\.colorScheme) private var colorScheme
    /// The list of files and commits folded away: the diff takes the tab.
    @AppStorage("loom.git.listHidden") private var listHidden = false
    @State private var message = ""
    @State private var output: String?
    @State private var busy = false

    private var title: String {
        model.sessions.first { $0.id == sessionID }?.title ?? "Session"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            HStack(spacing: 0) {
                if !listHidden {
                    sidebar
                        .frame(width: 264)
                    Divider().overlay(DefaultTheme.cardBorder)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
        .task(id: sessionID) { await reload() }
        .task(id: side) {
            if side == .history, commits == nil { commits = await model.gitHistory(for: sessionID) }
        }
        // The text on show, or the scheme, changed: its rows, then its
        // colours — the diff reads plain until they land.
        .task(id: DiffKey(text: shownText, dark: colorScheme == .dark)) {
            let text = shownText
            guard !text.isEmpty else {
                rows = nil
                return
            }
            let parsed = await model.gitDiffRows(for: sessionID, diff: text)
            guard !Task.isCancelled else { return }
            if rows?.hash != parsed.hash {
                rows = parsed
                colours = .none
            }
            let coloured = await model.gitDiffHighlights(for: sessionID, rows: parsed, dark: colorScheme == .dark)
            guard !Task.isCancelled else { return }
            colours = coloured
        }
        .onDisappear { model.forgetGitDiff(for: sessionID) }
        // The theme tour's "git-history": the latest commit, its files.
        .onReceive(NotificationCenter.default.publisher(for: .loomTourShow)) { note in
            guard note.object as? String == "git-history" else { return }
            side = .history
            Task {
                let found = await model.gitHistory(for: sessionID)
                commits = found
                if let first = found.first { show(first) }
            }
        }
    }

    private func reload() async {
        data = await model.gitPanel(for: sessionID)
        loaded = true
        if let file, data?.changes.contains(where: { $0.path == file }) != true { self.file = nil }
        if side == .history || commits != nil { commits = await model.gitHistory(for: sessionID) }
    }

    // MARK: Header — where we are, and Ship

    /// One row: where we are, Ship, and what the diff below looks like. The
    /// rest of the tab is the diff's.
    private var header: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            HStack(spacing: DefaultTheme.space(6)) {
                GhostButton(title, systemImage: "chevron.left", action: onShowSession)
                    .help("Back to the session")
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Commit message…", text: $message)
                    .textFieldStyle(.plain)
                    .themeFont(size: 12)
                    .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(5))
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                        .stroke(DefaultTheme.fieldBorder, lineWidth: 1))
                    .frame(minWidth: 120, maxWidth: 380)
                    .onSubmit { commitAll() }
                AccentButton("Commit") { commitAll() }
                GhostButton("Push", systemImage: "arrow.up.circle") {
                    run { await model.shipPush(sessionID) ?? "Pushed to origin ✓" }
                }
                GhostButton("Review", systemImage: "eyes") {
                    Task {
                        if let id = await model.launchReviewSession(reviewing: sessionID) { onReviewStarted(id) }
                    }
                }
                .help("A second claude reviews this worktree's diff")
                if GitHubService.ghPath != nil {
                    GhostButton("Create PR", systemImage: "arrow.triangle.pull") {
                        run {
                            guard let result = await model.shipCreatePR(sessionID) else { return "No repository" }
                            if result.success,
                               let url = URL(string: result.message.split(separator: "\n").last.map(String.init) ?? "") {
                                NSWorkspace.shared.open(url)
                            }
                            return result.message
                        }
                    }
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                HoverIconButton(systemImage: "sidebar.left",
                                help: listHidden ? "Show the list of files and commits"
                                                 : "Hide the list: the diff takes the whole tab") {
                    withAnimation(.hover) { listHidden.toggle() }
                }
                HoverIconButton(systemImage: unified ? "rectangle.split.2x1" : "list.bullet.rectangle",
                                help: unified ? "Split view (old | new)" : "Unified view (full-width lines)") {
                    unified.toggle()
                    UserDefaults.standard.set(unified, forKey: "loom.diff.unified")
                }
                HoverIconButton(systemImage: "arrow.clockwise", help: "Read the repository again") {
                    Task { await reload() }
                }
                HoverIconButton(systemImage: "xmark", help: "Close the Git tab", action: onClose)
            }
            // Every outcome verbatim, stderr included: no phantom success.
            if let output {
                Text(output)
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(output.hasSuffix("✓") ? DefaultTheme.groupHeader : DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(6))
        .background(DefaultTheme.background)
    }

    private func commitAll() {
        let text = message.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            output = "Write a commit message first."
            return
        }
        run {
            let error = await model.shipCommit(sessionID, message: text)
            if error == nil { message = "" }
            return error ?? "Committed ✓"
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String) {
        busy = true
        Task {
            output = await action()
            await reload()
            busy = false
        }
    }

    // MARK: Left — files and commits

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            Picker("", selection: $side) {
                ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(DefaultTheme.controlTint)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                    switch side {
                    case .changes: fileRows
                    case .history:
                        // A commit picked: the list becomes its files, one
                        // column for both — the diff keeps the rest.
                        if commit != nil { commitFileRows } else { commitRows }
                    }
                }
            }
        }
        .padding(DefaultTheme.space(10))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DefaultTheme.background)
    }

    @ViewBuilder
    private var fileRows: some View {
        if let data {
            if data.changes.isEmpty {
                note("Clean: nothing changed since the last commit.")
            } else {
                row(selected: file == nil, action: { file = nil }) {
                    AppIcon("square.stack", size: 11).foregroundStyle(DefaultTheme.secondaryText)
                    Text("All changes (\(data.changes.count))").themeFont(size: 12, weight: .medium)
                }
                ForEach(data.changes, id: \.path) { change in
                    row(selected: file == change.path, action: { file = change.path }) {
                        AppIcon(Self.symbol(for: change.kind), size: 11)
                            .foregroundStyle(DefaultTheme.secondaryText)
                        Text(change.path)
                            .themeFont(size: 11.5, design: .monospaced)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .help(change.path)
                }
            }
        } else if loaded {
            note("No git repository for this session.")
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var commitRows: some View {
        if let commits {
            if commits.isEmpty { note("No commit yet.") }
            ForEach(commits) { entry in
                row(selected: commit == entry, action: { show(entry) }) {
                    VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                        Text(entry.subject)
                            .themeFont(size: 12, weight: .medium)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: DefaultTheme.space(6)) {
                            Text(entry.shortHash)
                                .themeFont(size: 10.5, design: .monospaced)
                                .foregroundStyle(DefaultTheme.accentInk)
                            Text("\(entry.author) · \(entry.date.formatted(.relative(presentation: .named)))")
                                .themeFont(size: 10.5)
                                .foregroundStyle(DefaultTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    static func symbol(for kind: FileChange.Kind) -> String {
        switch kind {
        case .modified: "pencil"
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .untracked: "questionmark"
        }
    }

    private func show(_ entry: GitService.Commit) {
        commit = entry
        commitText = nil
        commitFiles = []
        commitFile = nil
        commitMessage = ""
        Task {
            let text = await model.gitCommit(entry.hash, for: sessionID)
            guard commit == entry else { return }
            let parts = GitService.commitParts(text)
            commitMessage = parts.message
            commitFiles = GitService.fileSections(ofDiff: parts.patch)
            commitText = parts.patch
        }
    }

    private func row<Label: View>(selected: Bool, action: @escaping () -> Void,
                                  @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(6)) {
                label()
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(5))
            .background(selected ? DefaultTheme.surfaceRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 12)
            .foregroundStyle(DefaultTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DefaultTheme.space(6))
    }

    // MARK: Right — the diff

    @ViewBuilder
    private var detail: some View {
        switch side {
        case .changes:
            if let data, !data.changes.isEmpty {
                diffView(preamble: nil)
            } else {
                placeholder(loaded ? "Nothing to show: the worktree is clean." : "Reading the repository…")
            }
        case .history:
            if commit == nil {
                placeholder("Pick a commit to see what it changed.")
            } else if commitText != nil {
                if commitFiles.isEmpty {
                    placeholder("This commit changes no file (a merge).")
                } else {
                    diffView(preamble: nil)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private struct DiffKey: Equatable {
        var text: String
        var dark: Bool
    }

    /// The unified diff on show: the changes (one file's, or all), or the
    /// picked commit's patch.
    private var shownText: String {
        switch side {
        case .changes:
            guard let diff = data?.diff else { return "" }
            guard let file else { return diff }
            return GitService.sections(ofDiff: diff).first { $0.path == file }?.text ?? diff
        case .history:
            guard let commitText else { return "" }
            guard let commitFile else { return commitText }
            return commitFiles.first { $0.path == commitFile }?.text ?? commitText
        }
    }

    /// The picked commit in the list's column: the way back to the commits,
    /// what it says, then its files — a click shows that file's diff.
    @ViewBuilder
    private var commitFileRows: some View {
        if let commit {
            GhostButton("Commits", systemImage: "chevron.left") {
                self.commit = nil
                commitText = nil
                commitFiles = []
                commitFile = nil
            }
            VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
                Text(commit.subject)
                    .themeFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let rest = commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    Text(rest)
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DefaultTheme.space(6)) {
                    Text(commit.shortHash)
                        .themeFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(DefaultTheme.accentInk)
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .themeFont(size: 10.5)
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                }
                Text(commit.author)
                    .themeFont(size: 10.5)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(6))
            if commitText == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if !commitFiles.isEmpty {
                row(selected: commitFile == nil, action: { commitFile = nil }) {
                    AppIcon("square.stack", size: 11).foregroundStyle(DefaultTheme.secondaryText)
                    Text("All files (\(commitFiles.count))")
                        .themeFont(size: 12, weight: .medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    counts(additions: commitFiles.reduce(0) { $0 + $1.additions },
                           deletions: commitFiles.reduce(0) { $0 + $1.deletions })
                }
                ForEach(commitFiles) { entry in
                    row(selected: commitFile == entry.path, action: { commitFile = entry.path }) {
                        AppIcon(Self.symbol(for: entry.kind), size: 11)
                            .foregroundStyle(DefaultTheme.secondaryText)
                        // The path takes the room: the counts line up at the edge.
                        Text(entry.path)
                            .themeFont(size: 11.5, design: .monospaced)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        counts(additions: entry.additions, deletions: entry.deletions)
                    }
                    .help(entry.path)
                }
            }
        }
    }

    /// "+12 −3", in the colours a diff uses.
    private func counts(additions: Int, deletions: Int) -> some View {
        HStack(spacing: DefaultTheme.space(4)) {
            if additions > 0 {
                Text("+\(additions)").foregroundStyle(DefaultTheme.badgeColor(for: .working))
            }
            if deletions > 0 {
                Text("−\(deletions)").foregroundStyle(DefaultTheme.danger)
            }
        }
        .themeFont(size: 10.5, design: .monospaced)
        .fixedSize()
    }

    /// The review's own diff view: side by side or unified, syntax colours,
    /// folding files, a selection to copy or hand to claude.
    private func diffView(preamble: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let preamble, !preamble.isEmpty {
                    Text(preamble)
                        .themeFont(size: 11.5, design: .monospaced)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DefaultTheme.space(12))
                }
                if let rows, !rows.files.isEmpty {
                    SplitDiffView(files: rows.files,
                                  onExplain: { snippet in
                                      send("Explain these lines (\(snippet.label)):\n```diff\n\(snippet.code)\n```")
                                  },
                                  onAsk: { snippet, question in
                                      send("About these lines (\(snippet.label)): \(question)\n```diff\n\(snippet.code)\n```")
                                  },
                                  onAddToSession: { snippet in
                                      let text = "\(snippet.label)\n```diff\n\(snippet.code)\n```\n"
                                      Task { await model.typeIntoSession(text, id: sessionID) }
                                      onShowSession()
                                  },
                                  unified: unified,
                                  highlights: colours)
                        // Close to the edges: the width is the code's.
                        .padding(.horizontal, DefaultTheme.space(6))
                        .padding(.vertical, DefaultTheme.space(6))
                } else if rows == nil, !shownText.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(DefaultTheme.space(24))
                }
            }
        }
    }

    /// A question about the lines picked goes to the session's claude, and
    /// the session shows.
    private func send(_ text: String) {
        Task { _ = await model.submitWhenReady(text, to: sessionID, timeout: .seconds(15)) }
        onShowSession()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 12)
            .foregroundStyle(DefaultTheme.mutedText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
