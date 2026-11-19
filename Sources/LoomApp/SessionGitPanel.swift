import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The session's Git panel, under its Ship controls: what changed (a file at
/// a time, its diff in colours) and the branch's history (a commit at a
/// time: its message, its files, its patch).
struct SessionGitPanelBody: View {
    let model: AppModel
    let sessionID: SessionID
    let data: AppModel.GitPanelData?

    enum Tab: String, CaseIterable {
        case changes = "Changes", history = "History"
    }

    @State private var tab = Tab.changes
    /// The file whose diff shows; nil shows them all.
    @State private var file: String?
    @State private var commits: [GitService.Commit]?
    @State private var commit: GitService.Commit?
    @State private var commitText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(DefaultTheme.controlTint)
            switch tab {
            case .changes: changes
            case .history: history
            }
        }
        .task(id: tab) {
            if tab == .history, commits == nil { commits = await model.gitHistory(for: sessionID) }
        }
        // The changes moved (a commit, a refresh): the history may have too.
        .onChange(of: data?.diff) {
            commits = nil
            if tab == .history { Task { commits = await model.gitHistory(for: sessionID) } }
        }
    }

    // MARK: Changes

    @ViewBuilder
    private var changes: some View {
        if let data {
            if data.changes.isEmpty {
                note("Clean: nothing changed since the last commit.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                        ForEach(data.changes, id: \.path) { change in
                            fileRow(change.path, symbol: Self.symbol(for: change.kind))
                        }
                    }
                }
                .frame(maxHeight: 132)
                .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(DefaultTheme.cardBorder)
                GitDiffText(text: shownDiff(data.diff))
            }
        } else {
            note("No git repository for this session.")
        }
    }

    private func shownDiff(_ diff: String) -> String {
        guard let file else { return diff }
        return GitService.sections(ofDiff: diff).first { $0.path == file }?.text ?? diff
    }

    private func fileRow(_ path: String, symbol: String) -> some View {
        let selected = file == path
        return Button {
            file = selected ? nil : path
        } label: {
            HStack(spacing: DefaultTheme.space(6)) {
                AppIcon(symbol, size: 11).foregroundStyle(DefaultTheme.secondaryText)
                Text(path)
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(selected ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DefaultTheme.space(6))
            .frame(height: DefaultTheme.size(22))
            .background(selected ? DefaultTheme.surfaceRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Show every file's diff" : "Show this file's diff only")
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

    // MARK: History

    @ViewBuilder
    private var history: some View {
        if let commit {
            HStack(spacing: DefaultTheme.space(6)) {
                GhostButton("Commits", systemImage: "chevron.left") {
                    self.commit = nil
                    commitText = nil
                }
                Text(commit.shortHash)
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(DefaultTheme.accentInk)
                Spacer(minLength: 0)
            }
            if let commitText {
                GitDiffText(text: commitText)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } else if let commits {
            if commits.isEmpty {
                note("No commit yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                        ForEach(commits) { entry in commitRow(entry) }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func commitRow(_ entry: GitService.Commit) -> some View {
        Button {
            commit = entry
            commitText = nil
            Task {
                let text = await model.gitCommit(entry.hash, for: sessionID)
                if commit == entry { commitText = text }
            }
        } label: {
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                Text(entry.subject)
                    .themeFont(size: 12, weight: .medium)
                    .foregroundStyle(DefaultTheme.primaryText)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this commit's changes")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 12)
            .foregroundStyle(DefaultTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A diff or a commit, line by line in the theme's colours: additions,
/// deletions, hunk headers, file headers. Scrolls both ways; long files are
/// laid out as they come into view.
struct GitDiffText: View {
    let text: String

    /// Past this the rest is not drawn: a generated file's diff is not read here.
    private static let lineLimit = 4_000

    var body: some View {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = Array(all.prefix(Self.lineLimit))
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .themeFont(size: 11, design: .monospaced)
                        .foregroundStyle(Self.ink(for: line))
                        .padding(.horizontal, DefaultTheme.space(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.fill(for: line))
                        .fixedSize(horizontal: true, vertical: false)
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
