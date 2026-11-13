import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The PRs tab's Browse mode: a rail of scopes on the left (waiting on me,
/// the projects, a GitHub search, the repositories to add), and the scope's
/// pull requests in a sortable table. Nothing is reviewed here: a
/// double-click, Return or "Open in Review" hands the PR to Review.
struct PRBrowserView: View {
    let model: AppModel

    /// The instant filter over the table; Return asks GitHub, or opens the
    /// PR the text names (a pasted URL, `o/r#12`).
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The text of the GitHub search on screen — the SEARCH scope's name.
    @State private var lastSearch = ""
    @State private var selection: Set<PRBrowseRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\PRBrowseRow.updatedAt, order: .reverse)]
    @State private var repoSelection: Set<GitHubService.Repository.ID> = []
    @State private var repoSortOrder = [KeyPathComparator(\GitHubService.Repository.pushedAt,
                                                          order: .reverse)]
    @State private var addRepoShown = false
    @State private var addRepoText = ""

    static let railWidth: CGFloat = 240

    private var scope: PRBrowseScope { model.prBrowseScope }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    PRModeSwitch(model: model)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DefaultTheme.space(12))
                .frame(width: Self.railWidth)
                Divider().overlay(DefaultTheme.cardBorder)
                toolbar
            }
            .frame(height: PRModeSwitch.barHeight)
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            HStack(spacing: 0) {
                rail
                    .frame(width: Self.railWidth)
                Divider().overlay(DefaultTheme.cardBorder)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DefaultTheme.background)
        .task {
            // Both come from disk first; gh is only asked past their TTL. The
            // catalog also names the organizations a search covers.
            async let inbox: Void = model.ensureInbox()
            async let catalog: Void = model.ensureCatalog()
            _ = await (inbox, catalog)
        }
        .task(id: scope) { await load(scope) }
        .onChange(of: scope) {
            selection = []
            repoSelection = []
        }
    }

    // MARK: Loading

    private func load(_ scope: PRBrowseScope) async {
        switch scope {
        case .inbox: await model.ensureInbox()
        case .allProjects, .project: await model.ensurePRs(for: model.projectIDs(in: scope))
        case .repositories: await model.ensureCatalog()
        case .search: break
        }
    }

    private func refresh() async {
        switch scope {
        case .inbox:
            await model.refreshInbox()
        case .allProjects, .project:
            let ids = model.projectIDs(in: scope)
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await model.refreshPRs(for: id) } }
            }
        case .repositories:
            await model.refreshCatalog()
        case .search:
            if !lastSearch.isEmpty { await model.searchPRs(lastSearch) }
        }
    }

    private var isLoading: Bool {
        switch scope {
        case .inbox: return model.inboxLoading
        case .search: return model.searchLoading
        case .repositories: return model.catalogLoading
        case .allProjects, .project:
            return model.projectIDs(in: scope).contains { model.isLoadingPRs(for: $0) }
        }
    }

    // MARK: Rail — the scopes

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DefaultTheme.space(16)) {
                railSection("REVIEW REQUESTS") {
                    PRScopeRow(systemImage: "tray", title: "Waiting on me",
                               count: model.inbox.count, loading: model.inboxLoading,
                               isSelected: scope == .inbox) { model.prBrowseScope = .inbox }
                }
                if model.searchResults != nil || model.searchLoading {
                    railSection("SEARCH") {
                        PRScopeRow(systemImage: "magnifyingglass",
                                   title: lastSearch.isEmpty ? "Results" : "“\(lastSearch)”",
                                   count: model.searchResults?.count, loading: model.searchLoading,
                                   isSelected: scope == .search,
                                   onClose: { clearSearch() }) { model.prBrowseScope = .search }
                    }
                }
                railSection("PROJECTS") {
                    PRScopeRow(systemImage: "square.stack.3d.up", title: "All projects",
                               count: model.projects.reduce(0) { $0 + model.prs(for: $1.id).count },
                               loading: false, isSelected: scope == .allProjects) {
                        model.prBrowseScope = .allProjects
                    }
                    ForEach(model.projects, id: \.id) { project in
                        let repo = model.repoName(for: project.id)
                        PRScopeRow(systemImage: "folder", title: project.name,
                                   subtitle: repo.flatMap {
                                       $0.caseInsensitiveCompare(project.name) == .orderedSame ? nil : $0
                                   },
                                   count: model.prCacheAge(for: project.id) == nil
                                       ? nil : model.prs(for: project.id).count,
                                   loading: model.isLoadingPRs(for: project.id),
                                   isSelected: scope == .project(project.id)) {
                            model.prBrowseScope = .project(project.id)
                        }
                        .padding(.leading, DefaultTheme.space(10))
                    }
                }
                railSection("GITHUB") {
                    PRScopeRow(systemImage: "building.2", title: "Add a repository",
                               subtitle: "Your organizations' repositories",
                               count: nil, loading: model.catalogLoading,
                               isSelected: scope == .repositories) { model.prBrowseScope = .repositories }
                }
                ScheduledReviewsSidebarSection(model: model, activeTabID: nil)
            }
            .padding(DefaultTheme.space(10))
        }
        .background(DefaultTheme.background)
    }

    private func railSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(3)) {
            Text(title)
                .themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
                .foregroundStyle(DefaultTheme.mutedText)
                .padding(.horizontal, DefaultTheme.space(6))
                .padding(.bottom, DefaultTheme.space(2))
            content()
        }
    }

    // MARK: Toolbar — the scope, the search, the actions on the selection

    private var toolbar: some View {
        HStack(spacing: DefaultTheme.space(10)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(scopeTitle)
                    .themeFont(size: 13, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Text(scopeCaption)
                    .themeFont(size: 10)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            selectionActions
            searchField
            if scope.isProjectScope {
                PRFilterMenu(model: model, projectsToRefresh: { model.projectIDs(in: model.prBrowseScope) })
            }
            if isLoading {
                ProgressView().controlSize(.mini)
            }
            HoverIconButton(systemImage: "arrow.clockwise", help: refreshHelp) {
                Task { await refresh() }
            }
            HoverIconButton(systemImage: "plus", help: "Add a repository by owner/name or URL") {
                addRepoShown = true
            }
            .popover(isPresented: $addRepoShown, arrowEdge: .bottom) { addRepoPopover }
        }
        .padding(.horizontal, DefaultTheme.space(14))
        .frame(maxWidth: .infinity)
    }

    private var scopeTitle: String {
        switch scope {
        case .inbox: return "Waiting on me"
        case .allProjects: return "All projects"
        case .project(let id): return model.projects.first { $0.id == id }?.name ?? "Project"
        case .search: return lastSearch.isEmpty ? "Search results" : "Search: “\(lastSearch)”"
        case .repositories: return "Add a repository"
        }
    }

    private var scopeCaption: String {
        var parts: [String] = []
        if scope == .repositories {
            let count = repoRows.count
            parts.append(count == 1 ? "1 repository not added yet" : "\(count) repositories not added yet")
            if !repoSelection.isEmpty { parts.append("\(repoSelection.count) selected") }
        } else {
            let count = rows.count
            parts.append(count == 1 ? "1 pull request" : "\(count) pull requests")
            if scope.isProjectScope && model.selectedPRFilterID != PRFilter.all.id {
                parts.append(model.selectedPRFilter.name)
            }
            if !selection.isEmpty { parts.append("\(selection.count) selected") }
        }
        if !query.isEmpty { parts.append("filtered") }
        return parts.joined(separator: " · ")
    }

    private var refreshHelp: String {
        switch scope {
        case .project(let id): return model.prCacheHelp(for: id)
        case .inbox: return "Refresh the reviews waiting on you"
        case .repositories: return "Refresh the organizations' repositories"
        case .search: return "Run the search again"
        case .allProjects: return "Refresh every project's pull requests"
        }
    }

    /// What the selection can become: a review, or projects.
    @ViewBuilder
    private var selectionActions: some View {
        if scope == .repositories {
            if !repoSelection.isEmpty {
                AccentButton(repoSelection.count == 1 ? "Add as project"
                             : "Add \(repoSelection.count) as projects",
                             systemImage: "plus") { addRepositories(repoSelection) }
            }
        } else {
            let picked = rows(for: selection)
            if picked.count == 1, let row = picked.first, let pr = row.pr, let projectID = row.projectID {
                if model.isLaunchingReview(forPR: pr.number, in: projectID) {
                    ProgressView().controlSize(.small)
                } else {
                    GhostButton(model.reviewSession(forPR: pr.number, in: projectID) != nil
                                ? "Review session" : "Start review", systemImage: "sparkles") {
                        model.startPRReview(pr, in: projectID)
                    }
                }
            }
            if !picked.isEmpty {
                AccentButton(picked.count == 1 ? "Open in Review" : "Open \(picked.count) in Review",
                             systemImage: "arrow.right.circle") {
                    model.openForReview(picked)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DefaultTheme.space(6)) {
            AppIcon("magnifyingglass", size: 13)
                .foregroundStyle(DefaultTheme.secondaryText)
            TextField(scope == .repositories ? "Filter repositories"
                      : "Filter — Return searches GitHub or opens a PR URL",
                      text: $query)
                .textFieldStyle(.plain)
                .themeFont(size: 12)
                .focused($searchFocused)
                .onSubmit { submitSearch() }
                .onExitCommand { query = "" }
            if model.searchLoading {
                ProgressView().controlSize(.mini)
            } else if !query.isEmpty {
                HoverIconButton(systemImage: "xmark.circle.fill", help: "Clear") { query = "" }
            }
            // ⌘F lands in the field; the button itself is never seen.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(5))
        .frame(width: 300)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
            .stroke(searchFocused ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.fieldBorder,
                    lineWidth: 1))
        .themeShadow(.xs, radius: 6)
    }

    /// Return: a PR reference opens in Review; any other text becomes a
    /// GitHub search — its own scope, the field emptied: GitHub matches the
    /// bodies too, and the local filter would hide what it found.
    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, scope != .repositories else { return }
        if let reference = PRReference.parse(text) {
            query = ""
            Task { await model.openPR(reference: reference, pin: true) }
        } else {
            lastSearch = text
            query = ""
            model.prBrowseScope = .search
            Task { await model.searchPRs(text) }
        }
    }

    private func clearSearch() {
        model.clearSearch()
        lastSearch = ""
        if scope == .search { model.prBrowseScope = .inbox }
    }

    // MARK: Content — the table of the scope

    @ViewBuilder
    private var content: some View {
        if scope == .repositories {
            repositoriesTable
        } else {
            pullRequestsTable
        }
    }

    /// The scope's rows, filtered by the typed text, in the table's order.
    private var rows: [PRBrowseRow] {
        model.browseRows(in: scope)
            .filter { $0.matches(query: query) }
            .sorted(using: sortOrder)
    }

    /// The rows behind a set of ids, in the table's order.
    private func rows(for ids: Set<PRBrowseRow.ID>) -> [PRBrowseRow] {
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    private var pullRequestsTable: some View {
        let rows = self.rows
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("CI", value: \PRBrowseRow.ciRank) { row in PRBrowseCells.ci(row) }
                .width(30)
            TableColumn("#", value: \PRBrowseRow.number) { row in PRBrowseCells.number(row) }
                .width(min: 44, ideal: 56, max: 80)
            TableColumn("Title", value: \PRBrowseRow.title) { row in PRBrowseCells.title(row) }
                .width(min: 220, ideal: 420)
            TableColumn("Repository", value: \PRBrowseRow.place) { row in PRBrowseCells.place(row) }
                .width(min: 100, ideal: 170, max: 280)
            TableColumn("Author", value: \PRBrowseRow.author) { row in PRBrowseCells.author(row) }
                .width(min: 80, ideal: 110, max: 180)
            TableColumn("Review", value: \PRBrowseRow.reviewRank) { row in PRBrowseCells.review(row) }
                .width(min: 90, ideal: 150, max: 240)
            TableColumn("Size", value: \PRBrowseRow.size) { row in PRBrowseCells.size(row) }
                .width(min: 70, ideal: 90, max: 130)
            TableColumn("Updated", value: \PRBrowseRow.updatedAt) { row in PRBrowseCells.updated(row) }
                .width(min: 60, ideal: 76, max: 110)
            TableColumn("Session", value: \PRBrowseRow.sessionRank) { row in
                PRBrowseCells.session(row, launching: row.projectID.map {
                    model.isLaunchingReview(forPR: row.number, in: $0)
                } ?? false)
            }
            .width(min: 54, ideal: 64, max: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(DefaultTheme.tableHeaderFont)
        .scrollContentBackground(.hidden)
        .background(DefaultTheme.contentBackground)
        .contextMenu(forSelectionType: PRBrowseRow.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            model.openForReview(self.rows(for: ids))
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<PRBrowseRow.ID>) -> some View {
        let picked = rows(for: ids)
        if !picked.isEmpty {
            Button(picked.count == 1 ? "Open in Review" : "Open \(picked.count) in Review") {
                model.openForReview(picked)
            }
            if picked.count == 1, let row = picked.first, let pr = row.pr, let projectID = row.projectID {
                Button(model.reviewSession(forPR: pr.number, in: projectID) != nil
                       ? "Open the review session" : "Start a review session") {
                    model.startPRReview(pr, in: projectID)
                }
            }
            Divider()
            Button(picked.count == 1 ? "Open on GitHub" : "Open \(picked.count) on GitHub") {
                for row in picked {
                    if let url = URL(string: row.url), !row.url.isEmpty { NSWorkspace.shared.open(url) }
                }
            }
            Button(picked.count == 1 ? "Copy link" : "Copy links") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(picked.map(\.url).joined(separator: "\n"),
                                               forType: .string)
            }
        }
    }

    /// Why the table is empty — and, when there is one, the way out.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DefaultTheme.space(8)) {
            switch scope {
            case .inbox:
                if let error = model.inboxError {
                    emptyText(error, isError: true)
                } else if model.inboxLoading {
                    emptyText("Asking GitHub…")
                } else {
                    emptyTitle("Nothing waiting on you")
                    emptyText(query.isEmpty ? "No review is requested from you right now."
                              : "No request matches “\(query)”.")
                }
            case .search:
                if let error = model.searchError {
                    emptyText(error, isError: true)
                } else if model.searchLoading {
                    emptyText("Searching GitHub…")
                } else {
                    emptyText("Nothing open matches on GitHub.")
                }
            case .allProjects, .project:
                if model.projects.isEmpty {
                    emptyTitle("No project yet")
                    emptyText("Add one of your organizations' repositories to list its pull requests.")
                    GhostButton("Add a repository", systemImage: "building.2") {
                        model.prBrowseScope = .repositories
                    }
                } else if isLoading {
                    emptyText("Loading pull requests…")
                } else if !query.isEmpty {
                    emptyText("No loaded PR matches “\(query)”.")
                } else if model.selectedPRFilterID != PRFilter.all.id {
                    emptyText("No PR matches “\(model.selectedPRFilter.name)”.")
                } else {
                    emptyText("No open pull request — or gh is not authenticated for this repository.")
                }
            case .repositories:
                EmptyView()
            }
        }
        .padding(DefaultTheme.space(24))
        .frame(maxWidth: 420)
        .allowsHitTesting(true)
    }

    private func emptyTitle(_ text: String) -> some View {
        Text(text)
            .themeFont(size: 14, weight: .semibold)
            .foregroundStyle(DefaultTheme.secondaryText)
    }

    private func emptyText(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .themeFont(size: 12)
            .foregroundStyle(isError ? DefaultTheme.danger : DefaultTheme.mutedText)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
    }

    // MARK: Repositories — the catalog, one click from becoming projects

    private var repoRows: [GitHubService.Repository] {
        model.visibleOwners
            .flatMap { model.catalogRepositories(of: $0) }
            .filter { PRSidebarFilter.matches($0, query: query) }
            .sorted(using: repoSortOrder)
    }

    private var repositoriesTable: some View {
        let repos = repoRows
        return VStack(spacing: 0) {
            Table(repos, selection: $repoSelection, sortOrder: $repoSortOrder) {
                TableColumn("Repository", value: \GitHubService.Repository.nameWithOwner) { repo in
                    CatalogCells.name(repo, cloning: model.isCloning(repo.nameWithOwner))
                }
                .width(min: 180, ideal: 260)
                TableColumn("Description", value: \GitHubService.Repository.description) { repo in
                    CatalogCells.description(repo)
                }
                .width(min: 160, ideal: 380)
                TableColumn("Visibility", value: \GitHubService.Repository.visibility) { repo in
                    CatalogCells.visibility(repo)
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Pushed", value: \GitHubService.Repository.pushedAt) { repo in
                    CatalogCells.pushed(repo)
                }
                .width(min: 60, ideal: 76, max: 110)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .font(DefaultTheme.tableHeaderFont)
            .scrollContentBackground(.hidden)
            .background(DefaultTheme.contentBackground)
            .contextMenu(forSelectionType: GitHubService.Repository.ID.self) { ids in
                repoMenu(ids)
            } primaryAction: { ids in
                addRepositories(ids)
            }
            .overlay {
                if repos.isEmpty { repositoriesEmptyState }
            }
            repositoriesFooter
        }
    }

    @ViewBuilder
    private func repoMenu(_ ids: Set<GitHubService.Repository.ID>) -> some View {
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Clone and add as a project" : "Clone and add \(ids.count) as projects") {
                addRepositories(ids)
            }
            Button(ids.count == 1 ? "Open on GitHub" : "Open \(ids.count) on GitHub") {
                for id in ids {
                    if let url = URL(string: "https://github.com/" + id) { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
            Button(ids.count == 1 ? "Hide this repository" : "Hide \(ids.count) repositories") {
                for id in ids { model.hide(repo: id) }
                repoSelection.subtract(ids)
            }
            let owners = Set(ids.map { GitHubRepoName.owner(of: $0) }).sorted()
            ForEach(owners, id: \.self) { owner in
                Button("Hide everything from \(owner)") { model.hide(owner: owner) }
            }
        }
    }

    /// One repository: the clone dialog. Several, picked on purpose: cloned
    /// one after the other, the clone folder asked once.
    private func addRepositories(_ ids: Set<GitHubService.Repository.ID>) {
        let names = ids.sorted()
        if names.count == 1, let name = names.first {
            model.pendingClone = .init(repo: name, number: nil)
        } else if !names.isEmpty {
            Task {
                for name in names { await model.addRepositoryAsProject(name) }
            }
        }
        repoSelection = []
    }

    @ViewBuilder
    private var repositoriesEmptyState: some View {
        VStack(spacing: DefaultTheme.space(8)) {
            if let error = model.catalogError {
                emptyText(error, isError: true)
            } else if model.catalog == nil {
                emptyText(model.catalogLoading ? "Asking GitHub for your organizations' repositories…"
                          : "Your organizations' repositories will show here once gh answers.")
            } else if !query.isEmpty {
                emptyText("No repository matches “\(query)”.")
            } else {
                emptyTitle("All caught up")
                emptyText("Every repository here is already a project.")
            }
        }
        .padding(DefaultTheme.space(24))
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var repositoriesFooter: some View {
        if model.hiddenCount > 0 || model.catalogError != nil {
            HStack(spacing: DefaultTheme.space(8)) {
                if model.hiddenCount > 0 {
                    Button {
                        model.unhideAll()
                    } label: {
                        Text(model.hiddenCount == 1 ? "1 hidden — show"
                             : "\(model.hiddenCount) hidden — show")
                            .themeFont(size: 11)
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(6))
            .background(DefaultTheme.background)
        }
    }

    // MARK: Add a repository by name

    /// `owner/name`, a repository URL, or a PR URL: the repository is cloned
    /// and added as a project; a PR URL opens the PR once it is.
    private var addRepoPopover: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            Text("Add a repository")
                .themeFont(size: 12, weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
            TextField("owner/name, or a GitHub URL", text: $addRepoText)
                .textFieldStyle(.plain)
                .themeFont(size: 12, design: .monospaced)
                .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(6))
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.fieldBorder, lineWidth: 1))
                .themeShadow(.xs, radius: 6)
                .onSubmit { submitAddRepo() }
            Text("Cloned with gh into your clone folder, then added as a project — its PRs appear with the others. A PR URL opens that PR right after.")
                .themeFont(size: 10)
                .foregroundStyle(DefaultTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                GhostButton("Cancel") { addRepoShown = false }
                AccentButton("Add") { submitAddRepo() }
            }
        }
        .padding(DefaultTheme.space(14))
        .frame(width: 340)
        .background(DefaultTheme.background)
    }

    private func submitAddRepo() {
        let text = addRepoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addRepoShown = false
        addRepoText = ""
        if let reference = PRReference.parse(text), reference.repo != nil {
            Task { await model.openPR(reference: reference, pin: true) }
        } else if let repo = GitHubRepoName.parse(nameWithOwner: text)
                    ?? GitHubRepoName.parse(remoteURL: text) {
            model.pendingClone = .init(repo: repo, number: nil)
        } else {
            model.startupError = "“\(text)” is neither owner/name nor a GitHub URL."
        }
    }
}

// MARK: - The mode switch

/// Browse | Review, at the leading edge of both modes' top bar — the same
/// place either way. Review counts its tabs and lights up when a review
/// session waits on the user. ⌘1 and ⌘2 switch.
struct PRModeSwitch: View {
    let model: AppModel

    /// Both modes' top bars: the switch never moves when the mode changes.
    static var barHeight: CGFloat { DefaultTheme.size(44) }

    var body: some View {
        HStack(spacing: DefaultTheme.space(2)) {
            PRModeSegment(title: "Browse", systemImage: "tablecells",
                          isActive: model.prMode == .browse, count: nil, alert: false,
                          shortcut: "1") {
                withAnimation(.hover) { model.prMode = .browse }
            }
            PRModeSegment(title: "Review", systemImage: "sparkles",
                          isActive: model.prMode == .review, count: model.prTabs.tabs.count,
                          alert: model.reviewNeedsInput, shortcut: "2") {
                withAnimation(.hover) { model.prMode = .review }
            }
        }
        .padding(DefaultTheme.space(2))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        .fixedSize()
    }
}

private struct PRModeSegment: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let count: Int?
    let alert: Bool
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(6)) {
                AppIcon(systemImage, size: 12)
                    .foregroundStyle(isActive ? DefaultTheme.accent : DefaultTheme.secondaryText)
                Text(title)
                    .themeFont(size: 12, weight: isActive ? .semibold : .regular)
                    .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                         : DefaultTheme.secondaryText)
                if let count, count > 0 {
                    Text("\(count)")
                        .themeFont(size: 9, weight: .semibold, design: .monospaced)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .padding(.horizontal, DefaultTheme.space(5)).padding(.vertical, DefaultTheme.space(1))
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                if alert {
                    Circle()
                        .fill(DefaultTheme.badgeColor(for: .needsInput))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(5))
            .background(isActive ? DefaultTheme.surfaceRaised
                        : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help(alert ? "\(title) (⌘\(shortcut.character)) — a review session waits on you"
                    : "\(title) (⌘\(shortcut.character))")
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

// MARK: - The rail's rows

/// A scope in the Browse rail: icon, name, the repository under it when it
/// differs, a count, a spinner while it loads.
private struct PRScopeRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    let count: Int?
    let loading: Bool
    let isSelected: Bool
    var onClose: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(8)) {
                AppIcon(systemImage, size: 13)
                    .foregroundStyle(isSelected ? DefaultTheme.accent : DefaultTheme.secondaryText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .themeFont(size: 12, weight: isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected || hovered ? DefaultTheme.primaryText
                                                               : DefaultTheme.secondaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .themeFont(size: 9, design: .monospaced)
                            .foregroundStyle(DefaultTheme.mutedText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if loading {
                    ProgressView().controlSize(.mini)
                } else if let onClose, hovered {
                    HoverIconButton(systemImage: "xmark", help: "Close the results", action: onClose)
                } else if let count, count > 0 {
                    Text("\(count)")
                        .themeFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundStyle(isSelected ? DefaultTheme.accent : DefaultTheme.mutedText)
                }
            }
            .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(5))
            .background(isSelected ? DefaultTheme.surfaceRaised
                        : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

// MARK: - The table's cells

/// One function per column: small, typed views keep the table's builder
/// cheap for the compiler and each cell cheap to redraw.
@MainActor
enum PRBrowseCells {
    private static let dash = "—"

    private static func unknown() -> some View {
        Text(dash)
            .themeFont(size: 11)
            .foregroundStyle(DefaultTheme.mutedText)
    }

    static func ci(_ row: PRBrowseRow) -> some View {
        Group {
            if let pr = row.pr {
                Circle()
                    .fill(PRChips.checksColor(pr))
                    .frame(width: 7, height: 7)
                    .help(PRChips.checksSummary(pr))
            } else {
                Circle()
                    .stroke(DefaultTheme.mutedText, lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .help("CI unknown until the PR is opened")
            }
        }
        .frame(maxWidth: .infinity)
    }

    static func number(_ row: PRBrowseRow) -> some View {
        Text("#\(row.number)")
            .themeFont(size: 11, weight: .bold, design: .monospaced)
            .foregroundStyle(DefaultTheme.accent)
    }

    static func title(_ row: PRBrowseRow) -> some View {
        HStack(spacing: DefaultTheme.space(6)) {
            if row.isDraft {
                Text("draft")
                    .themeFont(size: 9, weight: .semibold)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(1))
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
                    .fixedSize()
            }
            Text(row.title)
                .themeFont(size: 12, weight: .medium)
                .foregroundStyle(row.isDraft ? DefaultTheme.secondaryText : DefaultTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.title)
            if row.pr?.isConflicting == true {
                Text("conflicts")
                    .themeFont(size: 9, weight: .semibold)
                    .foregroundStyle(DefaultTheme.danger)
                    .fixedSize()
            }
            ForEach(row.labels.prefix(2), id: \.name) { PRChips.label($0) }
        }
    }

    static func place(_ row: PRBrowseRow) -> some View {
        Text(row.place)
            .themeFont(size: 11, design: .monospaced)
            .foregroundStyle(DefaultTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.head)
            .help(row.place)
    }

    static func author(_ row: PRBrowseRow) -> some View {
        Text("@" + row.author)
            .themeFont(size: 11, design: .monospaced)
            .foregroundStyle(DefaultTheme.secondaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    static func review(_ row: PRBrowseRow) -> some View {
        if let pr = row.pr {
            HStack(spacing: DefaultTheme.space(6)) {
                switch pr.reviewDecision {
                case "APPROVED":
                    Label("approved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DefaultTheme.groupHeader)
                case "CHANGES_REQUESTED":
                    Label("changes", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(DefaultTheme.danger)
                case "REVIEW_REQUIRED":
                    Label("required", systemImage: "circle.dashed")
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                default:
                    Text(dash).foregroundStyle(DefaultTheme.mutedText)
                }
                if !pr.reviewers.isEmpty {
                    Text(PRChips.reviewers(pr, limit: 2))
                        .themeFont(size: 10, design: .monospaced)
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                }
            }
            .themeFont(size: 11)
            .labelStyle(.titleAndIcon)
            .help(pr.reviewers.isEmpty ? pr.reviewDecision.lowercased()
                  : "Waiting on " + PRChips.reviewers(pr, limit: 10))
        } else {
            unknown()
        }
    }

    @ViewBuilder
    static func size(_ row: PRBrowseRow) -> some View {
        if let pr = row.pr, pr.additions + pr.deletions > 0 {
            PRChips.size(pr)
                .help(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files")
        } else {
            unknown()
        }
    }

    static func updated(_ row: PRBrowseRow) -> some View {
        Text(row.updatedAt.isEmpty ? dash : PRAge.text(row.updatedAt))
            .themeFont(size: 11)
            .foregroundStyle(DefaultTheme.mutedText)
            .help(row.updatedAt)
    }

    @ViewBuilder
    static func session(_ row: PRBrowseRow, launching: Bool) -> some View {
        if launching {
            ProgressView().controlSize(.mini)
                .help("Preparing the review worktree…")
        } else {
            switch row.sessionRank {
            case PRBrowseRow.SessionRank.needsInput:
                Image(systemName: "sparkles")
                    .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                    .help("Its review session waits on you")
            case PRBrowseRow.SessionRank.working:
                Image(systemName: "sparkles")
                    .foregroundStyle(DefaultTheme.badgeColor(for: .working))
                    .help("Its review session is working")
            case PRBrowseRow.SessionRank.exists:
                Image(systemName: "sparkles")
                    .foregroundStyle(DefaultTheme.mutedText)
                    .help("A review session exists for this PR")
            default:
                EmptyView()
            }
        }
    }
}

@MainActor
private enum CatalogCells {
    static func name(_ repo: GitHubService.Repository, cloning: Bool) -> some View {
        HStack(spacing: DefaultTheme.space(6)) {
            Image(systemName: repo.isPrivate ? "lock" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 12)
            HStack(spacing: 0) {
                Text(repo.owner + "/")
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(DefaultTheme.mutedText)
                Text(repo.name)
                    .themeFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(DefaultTheme.primaryText)
            }
            if repo.isFork {
                AppIcon("tuningfork", size: 11)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .help("Fork")
            }
            if cloning {
                ProgressView().controlSize(.mini)
                    .help("Cloning…")
            }
        }
        .lineLimit(1)
    }

    static func description(_ repo: GitHubService.Repository) -> some View {
        Text(repo.description)
            .themeFont(size: 11)
            .foregroundStyle(DefaultTheme.secondaryText)
            .lineLimit(1)
            .help(repo.description)
    }

    static func visibility(_ repo: GitHubService.Repository) -> some View {
        Text(repo.visibility)
            .themeFont(size: 10, weight: .medium)
            .foregroundStyle(repo.isArchived ? DefaultTheme.mutedText : DefaultTheme.secondaryText)
    }

    static func pushed(_ repo: GitHubService.Repository) -> some View {
        Text(repo.pushedAt.isEmpty ? "—" : PRAge.text(repo.pushedAt))
            .themeFont(size: 11)
            .foregroundStyle(DefaultTheme.mutedText)
    }
}

extension GitHubService.Repository {
    /// What the Visibility column shows and sorts on.
    var visibility: String {
        if isArchived { return "archived" }
        return isPrivate ? "private" : "public"
    }
}
