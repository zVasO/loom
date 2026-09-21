import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import SwiftUI

/// The global PRs tab: every project's open pull requests in one sidebar, the
/// shared PR workspace in the middle, and the review session in a drawer that
/// slides over the right edge — the diff never gives up width for it.
/// "Start review" is the one-click quick action — one claude session per PR,
/// badged, reattached when it already exists.
struct GlobalPRsView: View {
    let model: AppModel
    /// Opens the session in the Sessions tab (used until the pane is embedded).
    let onOpenSession: (SessionID) -> Void

    // The selection, the drawer and the folded list are the MODEL's
    // (`prTabs`, `prSidebarHidden`, `expandedPRProjects`): this view is
    // rebuilt every time the app's tabs switch, and its @State with it.

    /// The tab on screen — what the toolbar, workspace and drawer show.
    private var activeTab: PRTab? { model.prTabs.active }

    /// The active tab's review session, when it exists and is still around:
    /// what the drawer embeds. Derived, so diff and conversation always
    /// talk about the same PR.
    private var paneSessionID: SessionID? {
        guard let tab = activeTab,
              let id = model.reviewSession(forPR: tab.pr.number, in: tab.projectID),
              model.sessions.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The drawer shows only when its tab asked for it AND a session exists.
    private var paneOpen: Bool { (activeTab?.drawerOpen ?? false) && paneSessionID != nil }

    private func setPaneOpen(_ open: Bool) {
        guard let tab = activeTab else { return }
        model.setPRTabDrawer(open: open, for: tab.id)
    }
    /// What is typed in the search field: an instant filter over every list,
    /// a GitHub search (or a PR to open) on Return.
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Organizations whose repositories are unfolded — folded by default,
    /// an organization can hold hundreds.
    @State private var expandedOwners: Set<String> = []
    @State private var addRepoShown = false
    @State private var addRepoText = ""
    /// Which region of the workspace is showing. Persisted: whichever one you
    /// work in, you come back to it.
    @State private var pane = PRPane(rawValue: UserDefaults.standard
        .string(forKey: Self.paneKey) ?? "") ?? .files
    /// UserDefaults answers 0 for a key never written — that is "unset", not
    /// a width the user chose.
    @State private var drawerWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: GlobalPRsView.drawerWidthKey)
        return stored > 0 ? stored : 420
    }()
    /// A drag reports its translation from where it started, not since the
    /// last frame: the width it started from has to be remembered.
    @State private var drawerWidthAtDragStart: CGFloat?

    private static let paneKey = "loom.pr.pane"
    private static let drawerWidthKey = "loom.review.drawerWidth"
    private static let drawerMinWidth: CGFloat = 320
    /// However wide the drawer is dragged, this much diff stays uncovered.
    private static let workspaceMinWidth: CGFloat = 360

    private var gitProjects: [ProjectRecord] { model.projects }

    var body: some View {
        if !GitHubService.isAvailable {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 34))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("GitHub CLI required")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text("brew install gh — then gh auth login")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DefaultTheme.background)
        } else {
            HStack(spacing: 0) {
                if !model.prSidebarHidden {
                    sidebar
                    Divider().overlay(DefaultTheme.cardBorder)
                }
                detail
                PRTabShortcuts(model: model)
            }
            .background(DefaultTheme.background)
            .onAppear { consumePendingPR() }
            .onChange(of: model.pendingPR) { consumePendingPR() }
        }
    }

    /// A PR clicked in the project tab, the inbox, a search or a pasted URL
    /// lands here: previewed in a tab, its project unfolded, the cache
    /// warmed, the channel cleared.
    private func consumePendingPR() {
        guard let pending = model.pendingPR else { return }
        model.showPR(pending.pr, in: pending.projectID)
        model.expandedPRProjects.insert(pending.projectID)
        Task { await model.ensurePRs(for: pending.projectID) }
        model.pendingPR = nil
    }

    // MARK: Sidebar — search, inbox, projects, the organizations' catalog

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            // The question every list below answers: all open, mine, waiting
            // on my review… Changing it refetches the expanded projects only.
            HStack(spacing: 8) {
                PRFilterMenu(model: model,
                             projectsToRefresh: { Array(model.expandedPRProjects) })
                Spacer()
                if model.catalogLoading || model.inboxLoading {
                    ProgressView().controlSize(.mini)
                }
                HoverIconButton(systemImage: "arrow.clockwise",
                                help: "Refresh the inbox and the organizations' repositories") {
                    Task {
                        async let inbox: Void = model.refreshInbox()
                        async let catalog: Void = model.refreshCatalog()
                        _ = await (inbox, catalog)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let results = model.searchResults {
                        searchSection(results)
                    }
                    inboxSection
                    projectsSection
                    ForEach(model.visibleOwners, id: \.self) { owner in
                        ownerGroup(owner)
                    }
                    catalogFooter
                }
                .padding(12)
            }
        }
        .frame(width: Self.sidebarWidth)
        .background(DefaultTheme.background)
        .task {
            // Both come from disk first; gh is only asked past their TTL.
            async let inbox: Void = model.ensureInbox()
            async let catalog: Void = model.ensureCatalog()
            _ = await (inbox, catalog)
        }
        .confirmationDialog(
            "Clone \(model.pendingClone?.repo ?? "") and add it as a project?",
            isPresented: Binding(get: { model.pendingClone != nil },
                                 set: { if !$0 { model.pendingClone = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.pendingClone?.number == nil ? "Clone" : "Clone and open the PR") {
                // Read now: dismissing the dialog clears pendingClone before
                // the task below gets to run.
                let pending = model.pendingClone
                Task { await model.confirmClone(pending) }
            }
            Button("Cancel", role: .cancel) { model.pendingClone = nil }
        } message: {
            Text(model.cloneDirectory.map { "The clone lands in \($0.path)." }
                 ?? "You will be asked where clones should land.")
        }
    }

    private static let sidebarWidth: CGFloat = 340

    /// One field, two behaviours: typing narrows every list on screen; Return
    /// asks GitHub — or opens the PR the text names (a pasted URL, `o/r#12`).
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
            TextField("Search PRs and repos, or paste a PR URL", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { submitSearch() }
                .onExitCommand { clearQuery() }
            if model.searchLoading {
                ProgressView().controlSize(.mini)
            } else if !query.isEmpty || model.searchResults != nil {
                HoverIconButton(systemImage: "xmark.circle.fill", help: "Clear") { clearQuery() }
            }
            HoverIconButton(systemImage: "plus", help: "Add a repository by owner/name or URL") {
                addRepoShown = true
            }
            .popover(isPresented: $addRepoShown, arrowEdge: .bottom) { addRepoPopover }
            // ⌘F lands in the field; the button itself is never seen.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(searchFocused ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let reference = PRReference.parse(text) {
            Task { await model.openPR(reference: reference) }
        } else {
            Task { await model.searchPRs(text) }
        }
    }

    private func clearQuery() {
        query = ""
        model.clearSearch()
    }

    /// `owner/name`, a repository URL, or a PR URL: the repository is cloned
    /// and added as a project; a PR URL opens the PR once it is.
    private var addRepoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a repository")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            TextField("owner/name, or a GitHub URL", text: $addRepoText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                .onSubmit { submitAddRepo() }
            Text("Cloned with gh into your clone folder, then added as a project — its PRs appear with the others. A PR URL opens that PR right after.")
                .font(.system(size: 10))
                .foregroundStyle(DefaultTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                GhostButton("Cancel") { addRepoShown = false }
                AccentButton("Add") { submitAddRepo() }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(DefaultTheme.background)
    }

    private func submitAddRepo() {
        let text = addRepoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addRepoShown = false
        addRepoText = ""
        if let reference = PRReference.parse(text), reference.repo != nil {
            Task { await model.openPR(reference: reference) }
        } else if let repo = GitHubRepoName.parse(nameWithOwner: text)
                    ?? GitHubRepoName.parse(remoteURL: text) {
            model.pendingClone = .init(repo: repo, number: nil)
        } else {
            model.startupError = "“\(text)” is neither owner/name nor a GitHub URL."
        }
    }

    // MARK: Sections

    private func header(_ title: String, count: Int?, systemImage: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
            }
        }
        .foregroundStyle(DefaultTheme.groupHeader)
    }

    /// GitHub's answer to the typed text, grouped by repository. A hit in a
    /// repository nobody cloned yet offers the clone.
    private func searchSection(_ results: [GitHubService.PRSearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                header("SEARCH RESULTS", count: results.count, systemImage: "magnifyingglass")
                Spacer()
                HoverIconButton(systemImage: "xmark", help: "Close the results") { clearQuery() }
            }
            .padding(.horizontal, 2)
            if let error = model.searchError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.danger)
                    .textSelection(.enabled)
            } else if results.isEmpty {
                Text("Nothing open matches on GitHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .padding(.leading, 2)
            }
            hitList(results)
        }
    }

    /// Every PR waiting on the user's review — all organizations, external
    /// repositories included. Filtered by the typed text like the rest.
    @ViewBuilder
    private var inboxSection: some View {
        let hits = model.inbox.filter { PRSidebarFilter.matches($0, query: query) }
        if !hits.isEmpty || query.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    header("WAITING ON ME", count: hits.count, systemImage: "tray")
                    Spacer()
                    if model.inboxLoading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 2)
                if let error = model.inboxError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.danger)
                        .textSelection(.enabled)
                } else if hits.isEmpty && !model.inboxLoading {
                    Text("No review requested from you.")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.leading, 2)
                }
                hitList(hits)
            }
        }
    }

    /// Hits grouped by repository, repositories alphabetical.
    private func hitList(_ hits: [GitHubService.PRSearchHit]) -> some View {
        let groups = Dictionary(grouping: hits, by: \.repo)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let selectedRepo = activeTab.flatMap { model.repoName(for: $0.projectID) } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.key) { group in
                let repo = group.key
                let hits = group.value
                let cloned = model.project(forRepo: repo) != nil
                HStack(spacing: 5) {
                    Image(systemName: cloned ? "folder" : "icloud.and.arrow.down")
                        .font(.system(size: 9))
                    Text(repo)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(DefaultTheme.mutedText)
                .help(cloned ? "Cloned as a project" : "Not cloned yet — opening a PR asks to clone it")
                .padding(.leading, 2)
                ForEach(hits) { hit in
                    let selected = activeTab?.pr.number == hit.number
                        && selectedRepo.caseInsensitiveCompare(hit.repo) == .orderedSame
                    PRHitRow(hit: hit, isSelected: selected) {
                        Task { await model.openPR(repo: hit.repo, number: hit.number) }
                    }
                }
            }
        }
    }

    /// The projects, each with its PRs. The typed text keeps a project when
    /// its name matches (every PR shown) or when some of its PRs do (those).
    @ViewBuilder
    private var projectsSection: some View {
        let visible = gitProjects.filter { project in
            query.isEmpty
                || PRSidebarFilter.matches(projectName: project.name,
                                           repo: model.repoName(for: project.id), query: query)
                || model.prs(for: project.id).contains { PRSidebarFilter.matches($0, query: query) }
        }
        if !visible.isEmpty || query.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("PROJECTS", count: visible.count, systemImage: "folder")
                    .padding(.horizontal, 2)
                if visible.isEmpty {
                    Text("No project yet — add one from an organization below, or with +.")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.leading, 2)
                }
                ForEach(visible, id: \.id) { project in
                    projectGroup(project)
                }
            }
        }
    }

    private func projectGroup(_ project: ProjectRecord) -> some View {
        let nameMatches = !query.isEmpty && PRSidebarFilter.matches(
            projectName: project.name, repo: model.repoName(for: project.id), query: query)
        let prs = model.prs(for: project.id).filter {
            nameMatches || PRSidebarFilter.matches($0, query: query)
        }
        // A search opens every project with a match: what was typed is what
        // the user wants to see, not a chevron away.
        let expanded = model.expandedPRProjects.contains(project.id) || (!query.isEmpty && !prs.isEmpty)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if expanded {
                        model.expandedPRProjects.remove(project.id)
                    } else {
                        model.expandedPRProjects.insert(project.id)
                        Task { await model.ensurePRs(for: project.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.8)
                            if let repo = model.repoName(for: project.id),
                               repo.caseInsensitiveCompare(project.name) != .orderedSame {
                                Text(repo)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.mutedText)
                                    .lineLimit(1)
                            }
                        }
                        if !prs.isEmpty {
                            Text("\(prs.count)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(DefaultTheme.surfaceRaised, in: Capsule())
                        }
                    }
                    .foregroundStyle(DefaultTheme.groupHeader)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.isLoadingPRs(for: project.id) {
                    ProgressView().controlSize(.mini)
                }
                if expanded {
                    HoverIconButton(systemImage: "arrow.clockwise",
                                    help: model.prCacheHelp(for: project.id)) {
                        Task { await model.refreshPRs(for: project.id) }
                    }
                }
            }
            .padding(.horizontal, 2)
            if expanded {
                if prs.isEmpty && !model.isLoadingPRs(for: project.id) {
                    Text(!query.isEmpty ? "No loaded PR matches."
                         : model.selectedPRFilterID == PRFilter.all.id
                         ? "No open PR" : "No PR matches “\(model.selectedPRFilter.name)”")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.leading, 2)
                }
                ForEach(prs) { pr in
                    PRSidebarRow(pr: pr,
                                 isSelected: activeTab?.id == PRTab.key(project.id, pr.number),
                                 isOpen: model.prTabs.contains(PRTab.key(project.id, pr.number)),
                                 hasSession: model.reviewSession(forPR: pr.number,
                                                                 in: project.id) != nil,
                                 launching: model.isLaunchingReview(forPR: pr.number,
                                                                    in: project.id),
                                 onSelect: { model.showPR(pr, in: project.id) },
                                 onOpen: { model.openPRTab(pr, in: project.id) },
                                 onStartReview: { startReview(pr, project: project) })
                }
            }
        }
    }

    /// One organization (or the account itself): its repositories that are
    /// not projects yet, each one click from becoming one.
    @ViewBuilder
    private func ownerGroup(_ owner: String) -> some View {
        let repos = model.catalogRepositories(of: owner)
            .filter { PRSidebarFilter.matches($0, query: query) }
        let isViewer = owner == model.catalog?.viewer
        if !repos.isEmpty || query.isEmpty {
            let expanded = expandedOwners.contains(owner) || (!query.isEmpty && !repos.isEmpty)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        if expanded { expandedOwners.remove(owner) } else { expandedOwners.insert(owner) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 0 : -90))
                            Image(systemName: isViewer ? "person" : "building.2")
                                .font(.system(size: 9, weight: .semibold))
                            Text(owner.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.8)
                            if !repos.isEmpty {
                                Text("\(repos.count)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.secondaryText)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(DefaultTheme.surfaceRaised, in: Capsule())
                            }
                        }
                        .foregroundStyle(DefaultTheme.groupHeader)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isViewer ? "Your own repositories" : "Organization — repositories not added as projects yet")
                    Spacer()
                }
                .padding(.horizontal, 2)
                .contextMenu {
                    Button("Hide \(owner)") { model.hide(owner: owner) }
                }
                if expanded {
                    if repos.isEmpty {
                        Text("Every repository here is already a project.")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .padding(.leading, 2)
                    }
                    ForEach(repos) { repo in
                        CatalogRepoRow(repo: repo, cloning: model.isCloning(repo.nameWithOwner),
                                       onAdd: { model.pendingClone = .init(repo: repo.nameWithOwner, number: nil) },
                                       onHide: { model.hide(repo: repo.nameWithOwner) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var catalogFooter: some View {
        if let error = model.catalogError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.danger)
                .textSelection(.enabled)
        } else if model.catalog == nil && !model.catalogLoading {
            Text("Your organizations' repositories will show here once gh answers.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.mutedText)
        }
        if model.hiddenCount > 0 {
            Button {
                model.unhideAll()
            } label: {
                Text(model.hiddenCount == 1 ? "1 hidden — show" : "\(model.hiddenCount) hidden — show")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
    }
    private func startReview(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        guard !model.isLaunchingReview(forPR: pr.number, in: project.id) else { return }
        // A review pins its tab: browsing the list must not take it away.
        model.openPRTab(pr, in: project.id)
        Task {
            if await model.launchPRReviewSession(pr, in: project.id) != nil {
                // Stay in the PR tab: the session opens in the drawer, and the
                // PR list steps aside to give the diff room.
                withAnimation(.hover) {
                    model.setPRTabDrawer(open: true, for: PRTab.key(project.id, pr.number))
                    model.prSidebarHidden = true
                }
            }
        }
    }

    // MARK: Detail — toolbar, workspace, session drawer

    @ViewBuilder
    private var detail: some View {
        if let tab = activeTab,
           let project = gitProjects.first(where: { $0.id == tab.projectID }) {
            let pr = tab.pr
            VStack(spacing: 0) {
                PRTabStrip(model: model)
                Divider().overlay(DefaultTheme.cardBorder)
                toolbar(pr, project: project)
                Divider().overlay(DefaultTheme.cardBorder)
                GeometryReader { geometry in
                    // One width for the three of them: the drawer, the space
                    // the controls keep clear of it, and the handle's offset.
                    let width = clampedDrawerWidth(available: geometry.size.width)
                    let drawer = paneOpen ? width : 0
                    ZStack(alignment: .trailing) {
                        workspace(pr, project: project, controlsInset: drawer)
                        if paneOpen, let sessionID = paneSessionID {
                            // The drawer's OWN width never animates: it slides
                            // in at full size. Animating 0 → width resized the
                            // terminal on every frame of the slide, and each
                            // resize made the agent repaint its whole
                            // conversation — the duplicated blocks.
                            sessionDrawer(sessionID, width: width,
                                          available: geometry.size.width)
                        }
                        if paneSessionID != nil {
                            sessionToggle.padding(.trailing, drawer + 12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("Pick a pull request")
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("A click previews a PR in a tab; a double-click, or sparkles, keeps the tab for a review.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.mutedText)
                if model.prSidebarHidden {
                    // No toolbar without a tab: the way back to the list is here.
                    GhostButton("Show the PR list", systemImage: "sidebar.leading") {
                        withAnimation(.hover) { model.prSidebarHidden = false }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DefaultTheme.contentBackground)
        }
    }

    private func toolbar(_ pr: GitHubService.PullRequest,
                         project: ProjectRecord) -> some View {
        HStack(spacing: 10) {
            HoverIconButton(systemImage: "sidebar.leading",
                            help: model.prSidebarHidden ? "Show the PR list" : "Hide the PR list") {
                withAnimation(.hover) { model.prSidebarHidden.toggle() }
            }
            Text("#\(pr.number)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
            Text(pr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if !pr.checks.isEmpty {
                PRChips.checksChip(pr)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(PRPane.allCases) { candidate in
                    NavTab(candidate.rawValue, isActive: pane == candidate) {
                        pane = candidate
                        UserDefaults.standard.set(candidate.rawValue, forKey: Self.paneKey)
                    }
                }
            }
            Spacer(minLength: 12)
            GhostButton("GitHub", systemImage: "arrow.up.forward.square") {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            }
            if model.isLaunchingReview(forPR: pr.number, in: project.id) {
                // The checkout fetches from the network: without this the
                // click felt like a frozen app.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the review worktree…")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            } else {
                AccentButton(model.reviewSession(forPR: pr.number, in: project.id) != nil
                             ? "Review session" : "Start review",
                             systemImage: "sparkles") {
                    startReview(pr, project: project)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(DefaultTheme.background)
    }

    /// The drawer slides over the diff instead of shrinking it: opening it
    /// never reflows the code, so no line changes where it wraps.
    private func sessionDrawer(_ sessionID: SessionID, width: CGFloat,
                               available: CGFloat) -> some View {
        embeddedSession(sessionID)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(DefaultTheme.background)
            .overlay(alignment: .leading) { drawerResizeHandle(available: available) }
            .shadow(color: .black.opacity(0.45), radius: 20, x: -8)
            .transition(.move(edge: .trailing))
    }

    private func clampedDrawerWidth(available: CGFloat) -> CGFloat {
        let ceiling = max(available - Self.workspaceMinWidth, Self.drawerMinWidth)
        return min(max(drawerWidth, Self.drawerMinWidth), ceiling)
    }

    private func drawerResizeHandle(available: CGFloat) -> some View {
        Rectangle()
            .fill(DefaultTheme.cardBorder)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    // set(), not push()/pop(): a hover whose exit is missed
                    // would leave the resize cursor stuck on the stack.
                    .onHover { inside in
                        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(DragGesture()
                        .onChanged { value in
                            let start = drawerWidthAtDragStart ?? drawerWidth
                            drawerWidthAtDragStart = start
                            let ceiling = max(available - Self.workspaceMinWidth,
                                              Self.drawerMinWidth)
                            drawerWidth = min(max(start - value.translation.width,
                                                  Self.drawerMinWidth), ceiling)
                        }
                        .onEnded { _ in
                            drawerWidthAtDragStart = nil
                            UserDefaults.standard.set(drawerWidth, forKey: Self.drawerWidthKey)
                        })
            }
    }

    /// The floating handle: the one control that shows or hides the session,
    /// riding the drawer's edge so it stays the same target either way.
    private var sessionToggle: some View {
        let state = paneSessionID.flatMap { id in
            model.sessions.first { $0.id == id }?.state
        }
        return Button {
            withAnimation(.hover) { setPaneOpen(!paneOpen) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: paneOpen ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.accent)
                if let state, !paneOpen {
                    Circle()
                        .fill(DefaultTheme.badgeColor(for: state))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 11)
            .background(DefaultTheme.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(DefaultTheme.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
            .hoverBrightness()
        }
        .buttonStyle(.plain)
        .help(paneOpen ? "Hide the review session" : "Show the review session")
    }
}

extension GlobalPRsView {
    /// The shared PR workspace, wired once for both regions. `controlsInset`
    /// is what the drawer covers: the diff may pass under it, its buttons
    /// may not. Keyed by the tab: switching tabs starts the workspace clean
    /// (its loads come from the model's caches, so no gh call).
    fileprivate func workspace(_ pr: GitHubService.PullRequest,
                               project: ProjectRecord,
                               controlsInset: CGFloat) -> some View {
        let key = PRTab.key(project.id, pr.number)
        return PRWorkspaceView(model: model, project: project, pr: pr, pane: pane,
                        controlsInset: controlsInset,
                        onOpenSession: onOpenSession,
                        sendToSession: { message in
                            // A quick action pins the tab too: the answer lands
                            // in a session the user will come back to.
                            model.pinPRTab(key)
                            Task {
                                if await model.sendToPRReviewSession(
                                    message, pr: pr, in: project.id) != nil {
                                    withAnimation(.hover) { model.setPRTabDrawer(open: true, for: key) }
                                }
                            }
                        },
                        transcribeToSession: paneOpen ? { snippet in
                            guard let id = paneSessionID else { return }
                            Task {
                                await model.typeIntoSession("""
                                \(snippet.label):
                                ```diff
                                \(snippet.code)
                                ```

                                """, id: id)
                            }
                        } : nil,
                        reviewSummary: Binding(
                            get: { model.prTabs.tab(key)?.reviewSummary ?? "" },
                            set: { model.setPRTabSummary($0, for: key) }))
        .id(key)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    fileprivate func embeddedSession(_ sessionID: SessionID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.accent)
                Text(model.sessions.first { $0.id == sessionID }?.title ?? "Review session")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                if let state = model.sessions.first(where: { $0.id == sessionID })?.state {
                    StatusLabel(state)
                }
                Spacer()
                HoverIconButton(systemImage: "arrow.up.forward.square",
                                help: "Open in the Sessions tab") {
                    onOpenSession(sessionID)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            TerminalPane(model: model, sessionID: sessionID)
        }
    }
}

/// A PR in the global sidebar: CI dot, number, title — sparkles quick action
/// on hover starts (or reopens) its review session.
private struct PRSidebarRow: View {
    let pr: GitHubService.PullRequest
    let isSelected: Bool
    /// Has a tab (pinned or preview) — shown with a faint mark.
    let isOpen: Bool
    let hasSession: Bool
    let launching: Bool
    /// One click: preview in a tab. Two: keep the tab.
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onStartReview: () -> Void
    @State private var hovered = false

    private func chip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(DefaultTheme.surfaceRaised, in: Capsule())
            // One line, at its own width: the HStack would otherwise offer it
            // half the remaining room and "changes requested" would fold.
            .lineLimit(1)
            .fixedSize()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(PRChips.checksColor(pr))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .help(PRChips.checksSummary(pr))
            Text("#\(pr.number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text("@" + pr.author)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                    MonoTag(pr.branch, systemImage: "arrow.triangle.branch",
                            color: DefaultTheme.mutedText)
                }
                // One more line at most: who it waits on, what it is tagged,
                // how big it is, whether it still merges. The chips are rigid,
                // so the line can be wider than the row; a disabled horizontal
                // ScrollView takes exactly the proposed width and clips the
                // rest — a plain frame(maxWidth:) would grow to fit the child
                // and push the whole sidebar past its 300 pt.
                if !pr.reviewers.isEmpty || !pr.labels.isEmpty || pr.additions + pr.deletions > 0
                    || pr.isConflicting {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if !pr.reviewers.isEmpty {
                                Label(PRChips.reviewers(pr, limit: 2), systemImage: "person.2")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.mutedText)
                                    .lineLimit(1)
                            }
                            ForEach(pr.labels.prefix(2), id: \.name) { PRChips.label($0) }
                            if pr.additions + pr.deletions > 0 { PRChips.size(pr) }
                            if pr.isConflicting {
                                Text("conflicts")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(DefaultTheme.danger)
                            }
                        }
                    }
                    .scrollDisabled(true)
                }
            }
            // The column takes every point the trailing chips leave — safe now
            // that none of its lines can outgrow the proposal. Not a Spacer: one
            // would share that width fifty-fifty with the equally greedy column.
            .frame(maxWidth: .infinity, alignment: .leading)
            if launching {
                ProgressView().controlSize(.mini)
                    .help("Preparing the review worktree…")
            } else if hovered {
                HoverIconButton(systemImage: "sparkles",
                                help: hasSession ? "Open the review session"
                                                 : "Start a review session",
                                action: onStartReview)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    if pr.isDraft { chip("draft", color: DefaultTheme.secondaryText) }
                    if !pr.reviewDecision.isEmpty {
                        chip(pr.reviewDecision.replacingOccurrences(of: "_", with: " ").lowercased(),
                             color: pr.reviewDecision == "APPROVED" ? DefaultTheme.groupHeader
                                                                    : DefaultTheme.secondaryText)
                    }
                    if hasSession {
                        Circle().fill(AppModel.color(hex: "#A78BFA")).frame(width: 5, height: 5)
                            .help("A review session exists for this PR")
                    }
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(isSelected ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? DefaultTheme.accent.opacity(0.6)
                    : isOpen ? DefaultTheme.accent.opacity(0.25) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        // The double-tap is declared first so a second click is not two
        // single ones.
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
