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
                sidebar
                    .frame(width: 320)
                Divider().overlay(DefaultTheme.cardBorder)
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
    }

    private func reload() async {
        data = await model.gitPanel(for: sessionID)
        loaded = true
        if let file, data?.changes.contains(where: { $0.path == file }) != true { self.file = nil }
        if side == .history || commits != nil { commits = await model.gitHistory(for: sessionID) }
    }

    // MARK: Header — where we are, and Ship

    private var header: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            HStack(spacing: DefaultTheme.space(8)) {
                GhostButton(title, systemImage: "chevron.left", action: onShowSession)
                    .help("Back to the session")
                AppIcon("arrow.triangle.branch", size: 13).foregroundStyle(DefaultTheme.accentInk)
                Text("Git").themeFont(size: 13, weight: .semibold).foregroundStyle(DefaultTheme.primaryText)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                GhostButton(systemImage: "arrow.clockwise") { Task { await reload() } }
                    .help("Read the repository again")
                GhostButton(systemImage: "xmark", action: onClose)
                    .help("Close the Git tab")
            }
            HStack(spacing: DefaultTheme.space(6)) {
                TextField("Commit message…", text: $message)
                    .textFieldStyle(.plain)
                    .themeFont(size: 12)
                    .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(6))
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                        .stroke(DefaultTheme.fieldBorder, lineWidth: 1))
                    .frame(maxWidth: 520)
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
            }
            // Every outcome verbatim, stderr included: no phantom success.
            if let output {
                Text(output)
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(output.hasSuffix("✓") ? DefaultTheme.groupHeader : DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(10))
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
                    case .history: commitRows
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
        Task {
            let text = await model.gitCommit(entry.hash, for: sessionID)
            if commit == entry { commitText = text }
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
                GitDiffText(text: shownDiff(data.diff)).padding(DefaultTheme.space(10))
            } else {
                placeholder(loaded ? "Nothing to show: the worktree is clean." : "Reading the repository…")
            }
        case .history:
            if commit == nil {
                placeholder("Pick a commit to see what it changed.")
            } else if let commitText {
                GitDiffText(text: commitText).padding(DefaultTheme.space(10))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func shownDiff(_ diff: String) -> String {
        guard let file else { return diff }
        return GitService.sections(ofDiff: diff).first { $0.path == file }?.text ?? diff
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 12)
            .foregroundStyle(DefaultTheme.mutedText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
