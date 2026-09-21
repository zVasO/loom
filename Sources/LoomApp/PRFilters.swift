import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The filter picker shared by the PRs tab sidebar and the project's PRs
/// sub-tab: built-ins, then the user's own filters, then the editor.
struct PRFilterMenu: View {
    let model: AppModel
    /// Every project whose list should be refetched when the filter changes.
    let projectsToRefresh: () -> [ProjectID]
    var compact = false
    @State private var editorShown = false

    var body: some View {
        Menu {
            ForEach(PRFilter.builtIns) { filter in
                filterItem(filter)
            }
            if !model.customPRFilters.isEmpty {
                Divider()
                ForEach(model.customPRFilters) { filter in
                    filterItem(filter)
                }
            }
            Divider()
            Button("Edit filters…") { editorShown = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                if !compact {
                    Text(model.selectedPRFilter.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(model.selectedPRFilterID == PRFilter.all.id
                             ? DefaultTheme.secondaryText : DefaultTheme.accent)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.selectedPRFilter.query.isEmpty ? "Every open pull request"
              : model.selectedPRFilter.query)
        .sheet(isPresented: $editorShown) {
            PRFilterEditorSheet(model: model, projectsToRefresh: projectsToRefresh)
        }
    }

    private func filterItem(_ filter: PRFilter) -> some View {
        Button {
            model.selectedPRFilterID = filter.id
            Task {
                for projectID in projectsToRefresh() { await model.ensurePRs(for: projectID) }
            }
        } label: {
            if filter.id == model.selectedPRFilterID {
                Label(filter.name, systemImage: "checkmark")
            } else {
                Text(filter.name)
            }
        }
    }
}

/// Custom filters: a name and a GitHub search query, tested against a real
/// project before it is trusted. gh's own error is shown verbatim — a bad
/// qualifier is the one message worth reading.
struct PRFilterEditorSheet: View {
    let model: AppModel
    let projectsToRefresh: () -> [ProjectID]
    @Environment(\.dismiss) private var dismiss

    /// nil = a new filter; otherwise the custom filter being edited.
    @State private var editingID: String?
    @State private var name = ""
    @State private var query = ""
    @State private var validation: String?
    @State private var testResult: String?
    @State private var testing = false
    @State private var testProjectID: ProjectID?

    private static let examples: [(String, String)] = [
        ("My team's requests", "team-review-requested:acme/core"),
        ("Hotfixes to main", "base:main label:hotfix"),
        ("Stale, unreviewed", "review:none updated:<2026-01-01"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("PR filters")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton("Done") { dismiss() }
            }
            HStack(alignment: .top, spacing: 16) {
                filterList.frame(width: 220)
                Divider().overlay(DefaultTheme.cardBorder)
                form
            }
        }
        .padding(20)
        .frame(width: 720, height: 440)
        .background(DefaultTheme.background)
        .onAppear { testProjectID = model.selectedProject ?? model.projects.first?.id }
    }

    private var filterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR FILTERS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.customPRFilters) { filter in
                        Button {
                            editingID = filter.id
                            name = filter.name
                            query = filter.query
                            validation = nil
                            testResult = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(filter.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DefaultTheme.primaryText)
                                Text(filter.query)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.mutedText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(editingID == filter.id ? DefaultTheme.surfaceRaised
                                        : DefaultTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.customPRFilters.isEmpty {
                        Text("None yet — the built-ins cover the usual questions; write your own for a team, a label, a base branch.")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.mutedText)
                    }
                }
            }
            GhostButton("New filter", systemImage: "plus") {
                editingID = nil
                name = ""
                query = ""
                validation = nil
                testResult = nil
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingID == nil ? "NEW FILTER" : "EDIT FILTER")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            field("Name", text: $name, mono: false)
            field("Query", text: $query, mono: true)
            Text("GitHub's search qualifiers, the ones the search box on github.com takes. gh adds the repository and is:pr itself; name a state (is:merged…) to look beyond open PRs.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.examples, id: \.1) { example in
                    Button {
                        if name.isEmpty { name = example.0 }
                        query = example.1
                    } label: {
                        HStack(spacing: 6) {
                            Text(example.0).font(.system(size: 11))
                                .foregroundStyle(DefaultTheme.secondaryText)
                            Text(example.1).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DefaultTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Link("Search syntax reference",
                     destination: URL(string: "https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests")!)
                    .font(.system(size: 11))
            }
            if let validation {
                Text(validation).font(.system(size: 11)).foregroundStyle(DefaultTheme.danger)
            }
            if let testResult {
                Text(testResult).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 8) {
                if !model.projects.isEmpty {
                    Picker("", selection: $testProjectID) {
                        ForEach(model.projects, id: \.id) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    GhostButton(testing ? "Testing…" : "Test", systemImage: "play") { test() }
                        .disabled(testing)
                }
                Spacer()
                if let editingID {
                    GhostButton("Delete", systemImage: "trash", role: .destructive) {
                        model.removeCustomPRFilter(id: editingID)
                        self.editingID = nil
                        name = ""
                        query = ""
                    }
                }
                AccentButton(editingID == nil ? "Save" : "Update") { save() }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                .frame(width: 44, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        }
    }

    private func save() {
        if let problem = PRFilter.validate(name: name, query: query) {
            validation = problem
            return
        }
        validation = nil
        if let editingID, var existing = model.customPRFilters.first(where: { $0.id == editingID }) {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            model.updateCustomPRFilter(existing)
            model.selectedPRFilterID = existing.id
        } else {
            let filter = model.addCustomPRFilter(name: name, query: query)
            editingID = filter.id
            model.selectedPRFilterID = filter.id
        }
        Task {
            for projectID in projectsToRefresh() { await model.ensurePRs(for: projectID) }
        }
    }

    private func test() {
        guard let projectID = testProjectID else { return }
        if let problem = PRFilter.validate(name: name.isEmpty ? "probe" : name, query: query) {
            validation = problem
            return
        }
        validation = nil
        testing = true
        testResult = nil
        Task {
            switch await model.testPRFilter(query: query, in: projectID) {
            case .success(let count):
                testResult = count == 1 ? "1 pull request matches." : "\(count) pull requests match."
            case .failure(let error):
                if case GitHubService.GitHubError.commandFailed(_, let stderr) = error {
                    testResult = stderr.isEmpty ? "gh failed without a message." : stderr
                } else {
                    testResult = String(describing: error)
                }
            }
            testing = false
        }
    }
}

/// Small shared chips for the enriched PR rows.
@MainActor
enum PRChips {
    /// A label name comes from the repository, not from us: capped so one
    /// verbose label cannot eat the whole row.
    private static let labelWidth: CGFloat = 64

    static func label(_ label: GitHubService.Label) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AppModel.color(hex: label.colorHex))
                .frame(width: 6, height: 6)
            Text(label.name)
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: labelWidth, alignment: .leading)
        }
        .foregroundStyle(DefaultTheme.secondaryText)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(DefaultTheme.surfaceRaised, in: Capsule())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    static func size(_ pr: GitHubService.PullRequest) -> some View {
        HStack(spacing: 3) {
            Text("+\(pr.additions)").foregroundStyle(DefaultTheme.groupHeader)
            Text("−\(pr.deletions)").foregroundStyle(DefaultTheme.danger)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Red when a check failed, amber while one still runs, green otherwise
    /// (no check at all is green: no signal is not a failure).
    static func checksColor(_ pr: GitHubService.PullRequest) -> Color {
        if !pr.checksPassing { return DefaultTheme.danger }
        if pr.checksPending { return DefaultTheme.badgeColor(for: .needsInput) }
        return DefaultTheme.groupHeader
    }

    /// "4 passing · 1 failing · 2 pending" — only the non-zero parts.
    static func checksSummary(_ pr: GitHubService.PullRequest) -> String {
        guard !pr.checks.isEmpty else { return "No CI check reported" }
        var parts: [String] = []
        if pr.passingChecks > 0 { parts.append("\(pr.passingChecks) passing") }
        if pr.failingChecks > 0 { parts.append("\(pr.failingChecks) failing") }
        if pr.pendingChecks > 0 { parts.append("\(pr.pendingChecks) pending") }
        let other = pr.checks.count - pr.passingChecks - pr.failingChecks - pr.pendingChecks
        if other > 0 { parts.append("\(other) skipped") }
        return parts.joined(separator: " · ")
    }

    /// `@a, @b, team/core` — the people the PR is waiting on.
    static func reviewers(_ pr: GitHubService.PullRequest, limit: Int = 3) -> String {
        let shown = pr.reviewers.prefix(limit).map { $0.hasPrefix("team/") ? $0 : "@" + $0 }
        let extra = pr.reviewers.count - shown.count
        return shown.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
    }
}
