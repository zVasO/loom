import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import LoomWorkflows
import SwiftUI

/// The global PRs tab, in two modes that never share the screen (see
/// `PRMode`): BROWSE finds pull requests in a table (`PRBrowserView`);
/// REVIEW works on the ones opened from it — one tab each, the shared PR
/// workspace in the middle, and the review session in a drawer that slides
/// over the right edge, so the diff never gives up width for it.
/// "Start review" is the one-click quick action — one claude session per PR,
/// badged, reattached when it already exists.
struct GlobalPRsView: View {
    let model: AppModel
    /// Opens the session in the Sessions tab.
    let onOpenSession: (SessionID) -> Void

    // The mode, the scope, the tabs and their drawers are the MODEL's
    // (`prMode`, `prBrowseScope`, `prTabs`): this view is rebuilt every time
    // the app's tabs switch, and its @State with it.

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
    /// Which region of the workspace is showing. Persisted: whichever one you
    /// work in, you come back to it.
    @State private var pane = PRPane(rawValue: UserDefaults.standard
        .string(forKey: Self.paneKey) ?? "") ?? .files
    /// UserDefaults answers 0 for a key never written — that is "unset", not
    /// a width the user chose.
    @State private var drawerWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: GlobalPRsView.drawerWidthKey)
        return stored > 0 ? stored : TerminalPaneRole.defaultReviewDrawerWidth
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

    /// The PR the minute poll follows: the active tab's, in Review only —
    /// Browse shows no diff to keep true.
    private var watchedTabID: String? {
        model.prMode == .review ? activeTab?.id : nil
    }

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
            Group {
                switch model.prMode {
                case .browse: PRBrowserView(model: model)
                case .review: reviewMode
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DefaultTheme.background)
            .background(PRTabShortcuts(model: model))
            // The PR on screen stays true to GitHub: checked on every tab
            // switch, every minute, and whenever the app comes back to the
            // front (a push made meanwhile lands before anyone reviews it).
            .task(id: watchedTabID) { await watchActivePR() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                guard model.prMode == .review, let tab = activeTab else { return }
                Task { await model.refreshOpenPR(tab.pr.number, in: tab.projectID) }
            }
            .onAppear { consumePendingPR() }
            .onChange(of: model.pendingPR) { consumePendingPR() }
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
    }

    /// A PR clicked in the project tab or opened by a pasted URL lands here:
    /// previewed in a tab, shown in Review, the cache warmed, the channel
    /// cleared.
    private func consumePendingPR() {
        guard let pending = model.pendingPR else { return }
        model.showPR(pending.pr, in: pending.projectID)
        model.prMode = .review
        Task { await model.ensurePRs(for: pending.projectID) }
        model.pendingPR = nil
    }

    /// Polls the active tab's PR while the PR tab is on screen — cancelled
    /// by a tab switch (the next tab starts its own) or leaving the view.
    private func watchActivePR() async {
        guard model.prMode == .review, let tab = activeTab else { return }
        repeat {
            await model.refreshOpenPR(tab.pr.number, in: tab.projectID)
            try? await Task.sleep(for: .seconds(60))
        } while !Task.isCancelled
    }

    /// The workflows a PR can start (ADR-0017): run one on this PR, the
    /// Jira key found in it; the run opens in the Workflows tab.
    @ViewBuilder
    private func workflowMenu(_ pr: GitHubService.PullRequest, project: ProjectRecord) -> some View {
        let candidates = model.workflows.workflows.filter { $0.triggers.contains(.pullRequest) }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates) { workflow in
                    Button(workflow.name) {
                        let inputs = RunInputs(trigger: .pullRequest, projectID: project.id, prNumber: pr.number)
                        if let run = model.startWorkflowRun(workflow.id, inputs: inputs) {
                            model.workflows.detail = .run(run)
                            model.workflows.revealRequest = UUID()
                        }
                    }
                }
                let runs = model.workflows.runs.filter { $0.inputs.prNumber == pr.number && $0.inputs.projectID == project.id }
                if !runs.isEmpty {
                    Divider()
                    ForEach(runs.prefix(5)) { run in
                        Button("\(run.workflow.name) — \(RunStatusLabel.text(run.status)), "
                               + run.startedAt.formatted(.relative(presentation: .named))) {
                            model.workflows.detail = run.artifactPath != nil ? .report(run.id) : .run(run.id)
                            model.workflows.revealRequest = UUID()
                        }
                    }
                }
            } label: {
                Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Run a workflow on this PR — or open one of its runs")
        }
    }

    // MARK: Review — the open tabs, the workspace, the session drawer

    /// The top bar: the mode switch, then one tab per open PR.
    private var reviewBar: some View {
        HStack(spacing: 0) {
            PRModeSwitch(model: model)
                .padding(.horizontal, 12)
            Divider().overlay(DefaultTheme.cardBorder)
            PRTabStrip(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: PRModeSwitch.barHeight)
        .background(DefaultTheme.background)
    }

    @ViewBuilder
    private var reviewMode: some View {
        VStack(spacing: 0) {
            reviewBar
            Divider().overlay(DefaultTheme.cardBorder)
            if let tab = activeTab,
               let project = gitProjects.first(where: { $0.id == tab.projectID }) {
                let pr = tab.pr
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
            } else {
                reviewEmptyState
            }
        }
    }

    /// No PR open: Review has nothing of its own — the way to Browse is here.
    private var reviewEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(DefaultTheme.mutedText)
            Text("No pull request open for review")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("Pick one in Browse: double-click a row, press Return, or select several and open them together.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            AccentButton("Browse pull requests", systemImage: "tablecells") {
                withAnimation(.hover) { model.prMode = .browse }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
    }

    private func toolbar(_ pr: GitHubService.PullRequest,
                         project: ProjectRecord) -> some View {
        HStack(spacing: 10) {
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
            } else if model.reviewSession(forPR: pr.number, in: project.id) != nil {
                // Reopens the PR's session; the chevron starts over in a new
                // one (new brief, Settings' /setup-pr-review, empty context).
                HStack(spacing: 2) {
                    AccentButton("Review session", systemImage: "sparkles") {
                        model.startPRReview(pr, in: project.id)
                    }
                    Menu {
                        Button {
                            model.startPRReview(pr, in: project.id, fresh: true)
                        } label: {
                            Label("New review session", systemImage: "plus.bubble")
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DefaultTheme.accentText)
                            .frame(width: 22, height: 30)
                            .background(DefaultTheme.accent, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Review this PR in a fresh session — the current one stays in the sidebar")
                }
            } else {
                AccentButton("Start review", systemImage: "sparkles") {
                    model.startPRReview(pr, in: project.id)
                }
            }
            workflowMenu(pr, project: project)
            if !model.isLaunchingReview(forPR: pr.number, in: project.id) {
                // The poll runs every minute; this is "now": PR, diff,
                // comments, and the review worktree fetched again.
                if model.isRefreshingPR(pr.number, in: project.id) {
                    ProgressView().controlSize(.small).frame(width: 26)
                } else {
                    HoverIconButton(systemImage: "arrow.clockwise",
                                    help: "Refresh from GitHub — PR, diff, comments, review worktree") {
                        Task { await model.refreshOpenPR(pr.number, in: project.id, force: true) }
                    }
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
        let tab = activeTab
        let project = tab.flatMap { tab in gitProjects.first { $0.id == tab.projectID } }
        let reviews = tab.map { model.reviewSessions(forPR: $0.pr.number, in: $0.projectID) } ?? []
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.accent)
                if reviews.count > 1, let tab {
                    // One tab per review of this PR: the fresh ones and the
                    // ones before them, a click away.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(reviews.enumerated()), id: \.element) { index, id in
                                ReviewSessionTab(
                                    label: "Review \(index + 1)",
                                    help: sessionTitle(id),
                                    state: model.sessions.first { $0.id == id }?.state,
                                    isActive: id == sessionID) {
                                    Task {
                                        await model.selectReviewSession(id, forPR: tab.pr.number,
                                                                        in: tab.projectID)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text(sessionTitle(sessionID))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .lineLimit(1)
                    if let state = model.sessions.first(where: { $0.id == sessionID })?.state {
                        StatusLabel(state)
                    }
                    Spacer()
                }
                if let tab, let project {
                    HoverIconButton(systemImage: "plus", help: "New review session") {
                        model.startPRReview(tab.pr, in: project.id, fresh: true)
                    }
                    .disabled(model.isLaunchingReview(forPR: tab.pr.number, in: project.id))
                }
                // The review's agent browses out of sight (no side panel in
                // the drawer): a dot says so, and the Sessions tab shows it.
                if model.agentBrowsers[sessionID]?.activity?.isRunning == true {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.accent)
                        .help("claude is using its browser — open the session to watch")
                }
                HoverIconButton(systemImage: "arrow.up.forward.square",
                                help: "Open in the Sessions tab") {
                    if model.hasAgentBrowser(sessionID) { model.showInSidePanel(.agent, for: sessionID) }
                    onOpenSession(sessionID)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            TerminalPane(model: model, sessionID: sessionID, role: .review)
                .id(sessionID)
        }
    }

    private func sessionTitle(_ id: SessionID) -> String {
        model.sessions.first { $0.id == id }?.title
            ?? model.allRecords.first { $0.id == id }?.title
            ?? "Review session"
    }
}

/// A review session in the drawer's tab row: its state dot, "Review n".
/// Dormant sessions have no state: a hollow dot, resumed on click.
private struct ReviewSessionTab: View {
    let label: String
    let help: String
    let state: SessionState?
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.map { DefaultTheme.badgeColor(for: $0) } ?? .clear)
                    .overlay(Circle().stroke(state == nil ? DefaultTheme.mutedText : .clear,
                                             lineWidth: 1))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                         : DefaultTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isActive ? DefaultTheme.surfaceRaised
                        : hovered ? DefaultTheme.surfaceRaised.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
