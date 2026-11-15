import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import LoomWorkflows
import Observation
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

    // Nothing here reads `model.sessions`, a launch or a refresh in
    // progress: this body is the workspace's parent, and what re-runs it
    // re-compares the workspace. Those reads live in the leaves below — the
    // toolbar's actions, the drawer, the state dots (audit 2026-11-15).

    /// Which region of the workspace is showing. Persisted: whichever one you
    /// work in, you come back to it.
    @State private var pane = PRPane(rawValue: UserDefaults.standard
        .string(forKey: Self.paneKey) ?? "") ?? .files
    /// The drawer's width, shared by the drawer and the two bars that step
    /// aside for it. A reference: dragging it re-runs its readers, not this
    /// view and the workspace under it.
    @State private var drawerLayout = PRDrawerLayout()

    private static let paneKey = "loom.pr.pane"

    private var gitProjects: [ProjectRecord] { model.projects }

    /// The PR the minute poll follows: the active tab's, in Review only —
    /// Browse shows no diff to keep true.
    private var watchedTabID: String? {
        model.prMode == .review ? activeTab?.id : nil
    }

    var body: some View {
        if !GitHubService.isAvailable {
            VStack(spacing: DefaultTheme.space(10)) {
                AppIcon("arrow.triangle.pull", size: 41)
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("GitHub CLI required")
                    .themeFont(size: 15, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                Text("brew install gh — then gh auth login")
                    .themeFont(size: 12, design: .monospaced)
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
                Button(Self.cloneTitle(model.pendingClone)) {
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

    /// What confirming the clone goes on to do, in the button's words: a
    /// review asked for by reference carries on into that review.
    private static func cloneTitle(_ pending: AppModel.PendingClone?) -> String {
        guard let pending, pending.number != nil else { return "Clone" }
        return pending.startsReview ? "Clone and start the review" : "Clone and open the PR"
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

    // MARK: Review — the open tabs, the workspace, the session drawer

    /// The top bar: the mode switch, then one tab per open PR.
    private var reviewBar: some View {
        HStack(spacing: 0) {
            PRModeSwitch(model: model)
                .padding(.horizontal, DefaultTheme.space(12))
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
                // "Add to claude session" needs an input on screen: the
                // drawer open on a session that runs. Which sessions run,
                // not what state they are in: a transition does not come here.
                let transcribes: Bool = tab.drawerOpen
                    && model.liveReviewSession(forPR: pr.number, in: project.id) != nil
                toolbar(pr, project: project)
                Divider().overlay(DefaultTheme.cardBorder)
                ZStack(alignment: .trailing) {
                    workspace(pr, project: project, transcribes: transcribes)
                    // Over the diff, never beside it: opening the drawer
                    // reflows no code. Empty where it shows nothing, so the
                    // diff under it keeps its clicks.
                    PRSessionDrawer(model: model, tabID: tab.id, projectID: project.id, pr: pr,
                                    layout: drawerLayout, onOpenSession: onOpenSession)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PRReviewEmptyState(model: model)
            }
        }
    }

    private func toolbar(_ pr: GitHubService.PullRequest,
                         project: ProjectRecord) -> some View {
        HStack(spacing: DefaultTheme.space(10)) {
            Text("#\(pr.number)")
                .themeFont(size: 13, weight: .bold, design: .monospaced)
                .foregroundStyle(DefaultTheme.accentInk)
            Text(pr.title)
                .themeFont(size: 13, weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if !pr.checks.isEmpty {
                PRChips.checksChip(pr)
            }
            Spacer(minLength: 12)
            HStack(spacing: DefaultTheme.space(4)) {
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
            PRReviewToolbarActions(model: model, pr: pr, projectID: project.id)
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(8))
        .background(DefaultTheme.background)
    }
}

extension GlobalPRsView {
    /// The shared PR workspace, wired once for both regions. Keyed by the
    /// tab: switching tabs starts the workspace clean (its loads come from
    /// the model's caches, so no gh call). Compared, not rebuilt: this body
    /// runs again whenever a tab changes — a summary written, a drawer
    /// toggled — and the diff must not run again with it.
    fileprivate func workspace(_ pr: GitHubService.PullRequest,
                               project: ProjectRecord,
                               transcribes: Bool) -> some View {
        let key = PRTab.key(project.id, pr.number)
        let model = self.model
        let projectID = project.id
        // The two closures read nothing of this pass: a workspace SwiftUI
        // keeps (it compared equal) keeps the closures it was built with.
        return PRWorkspaceView(model: model, project: project, pr: pr, pane: pane,
                               drawerLayout: drawerLayout,
                               transcribes: transcribes,
                               onOpenSession: onOpenSession,
                               sendToSession: { message in
                                   // The drawer first, the session behind it — as for
                                   // "Start review": the message waits for claude to
                                   // boot and for the PR to load, the click does not.
                                   // The animated write before any other to the tabs:
                                   // the first one of a pass decides how it is drawn.
                                   let drawerWasOpen = model.prTabs.tab(key)?.drawerOpen ?? false
                                   withAnimation(.hover) { model.setPRTabDrawer(open: true, for: key) }
                                   // A quick action pins the tab too: the answer lands
                                   // in a session the user will come back to.
                                   model.pinPRTab(key)
                                   // Started here, not in the task: the PR is
                                   // "launching" in the frame the drawer opens in.
                                   model.reviewLaunchTask(pr, in: projectID)
                                   Task {
                                       let id = await model.sendToPRReviewSession(
                                           message, pr: pr, in: projectID)
                                       // No session came of it (the error is on
                                       // screen): a drawer this opened closes again.
                                       if id == nil, !drawerWasOpen {
                                           model.setPRTabDrawer(open: false, for: key)
                                       }
                                   }
                               },
                               transcribeToSession: { snippet in
                                   // Asked at the click: the session the drawer shows now.
                                   guard let id = model.liveReviewSession(forPR: pr.number,
                                                                          in: projectID) else { return }
                                   Task {
                                       await model.typeIntoSession("""
                                       \(snippet.label):
                                       ```diff
                                       \(snippet.code)
                                       ```

                                       """, id: id)
                                   }
                               })
        .equatable()
        .id(key)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The drawer's width

private let reviewDrawerWidthKey = "loom.review.drawerWidth"

/// The drawer's width as last dragged. UserDefaults answers 0 for a key
/// never written — that is "unset", not a width the user chose.
private func storedReviewDrawerWidth() -> CGFloat {
    let stored = UserDefaults.standard.double(forKey: reviewDrawerWidthKey)
    return stored > 0 ? CGFloat(stored) : TerminalPaneRole.defaultReviewDrawerWidth
}

/// The session drawer's width, and the room it has. One object for the
/// drawer and for the two bars of the workspace that must stay clear of it
/// (the files header, the verdict bar): a drag of the handle re-runs those
/// three, not `GlobalPRsView`, the workspace and the diff, which each drag
/// sample used to re-run (audit 2026-09-22, hot path 4; 2026-11-15).
@MainActor @Observable final class PRDrawerLayout {
    static let minWidth: CGFloat = 320
    /// However wide the drawer is dragged, this much diff stays uncovered.
    static let workspaceMinWidth: CGFloat = 360

    /// The width the user gave the drawer, kept across launches.
    var width: CGFloat = storedReviewDrawerWidth()
    /// The width of the review area, as the drawer last measured it.
    var available: CGFloat = .greatestFiniteMagnitude

    /// Keeps the width for the next launch: at the end of a drag, not at
    /// each of its samples.
    func persistWidth() {
        UserDefaults.standard.set(Double(width), forKey: reviewDrawerWidthKey)
    }

    /// `width` held between the drawer's minimum and what leaves the diff
    /// its own.
    static func clamped(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let ceiling = max(available - workspaceMinWidth, minWidth)
        return min(max(width, minWidth), ceiling)
    }

    /// Whether the PR's drawer shows: its tab asked for it AND there is
    /// something to put in it — the review session when it runs, or the
    /// word that it is being prepared.
    static func isOpen(_ model: AppModel, pr number: Int, in projectID: ProjectID) -> Bool {
        guard model.prTabs.tab(PRTab.key(projectID, number))?.drawerOpen == true else { return false }
        return model.liveReviewSession(forPR: number, in: projectID) != nil
            || model.isLaunchingReview(forPR: number, in: projectID)
    }

    /// How much of the PR's workspace the drawer covers: its width while it
    /// shows, nothing otherwise. The diff may pass under it, the controls
    /// of a bar may not.
    func covered(by model: AppModel, pr number: Int, in projectID: ProjectID) -> CGFloat {
        guard Self.isOpen(model, pr: number, in: projectID) else { return 0 }
        return Self.clamped(width, available: available)
    }
}

/// Keeps a bar's controls out from under the session drawer. A view of its
/// own: the drawer opening, closing or being dragged moves this padding,
/// and re-runs nothing of the view the bar belongs to.
struct PRDrawerClearance<Content: View>: View {
    let model: AppModel
    let projectID: ProjectID
    let number: Int
    let layout: PRDrawerLayout
    let content: Content

    init(model: AppModel, projectID: ProjectID, number: Int, layout: PRDrawerLayout,
         @ViewBuilder content: () -> Content) {
        self.model = model
        self.projectID = projectID
        self.number = number
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        content.padding(.trailing, layout.covered(by: model, pr: number, in: projectID))
    }
}

// MARK: - The toolbar's actions

/// What the toolbar does with the PR: its review (start, reopen, start
/// over), its workflows, its refresh. A view of its own: what these read —
/// a launch or a refresh running, the workflow runs — changes several times
/// while a review starts, and re-runs three buttons instead of the PRs tab.
private struct PRReviewToolbarActions: View {
    let model: AppModel
    let pr: GitHubService.PullRequest
    let projectID: ProjectID

    var body: some View {
        let launching: Bool = model.isLaunchingReview(forPR: pr.number, in: projectID)
        HStack(spacing: DefaultTheme.space(10)) {
            if launching {
                // The checkout fetches from the network: without this the
                // click felt like a frozen app.
                HStack(spacing: DefaultTheme.space(6)) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the review worktree…")
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            } else if model.reviewSession(forPR: pr.number, in: projectID) != nil {
                // Reopens the PR's session; the chevron starts over in a new
                // one (new brief, Settings' /setup-pr-review, empty context).
                HStack(spacing: DefaultTheme.space(2)) {
                    AccentButton("Review session", systemImage: "sparkles") {
                        model.startPRReview(pr, in: projectID)
                    }
                    Menu {
                        Button {
                            model.startPRReview(pr, in: projectID, fresh: true)
                        } label: {
                            Label("New review session", systemImage: "plus.bubble")
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DefaultTheme.accentText)
                            .frame(width: DefaultTheme.size(22), height: DefaultTheme.size(30))
                            .background(DefaultTheme.accent, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Review this PR in a fresh session — the current one stays in the sidebar")
                }
            } else {
                AccentButton("Start review", systemImage: "sparkles") {
                    model.startPRReview(pr, in: projectID)
                }
            }
            workflowMenu
            if !launching {
                // The poll runs every minute; this is "now": PR, diff,
                // comments, and the review worktree fetched again.
                if model.isRefreshingPR(pr.number, in: projectID) {
                    ProgressView().controlSize(.small).frame(width: 26)
                } else {
                    HoverIconButton(systemImage: "arrow.clockwise",
                                    help: "Refresh from GitHub — PR, diff, comments, review worktree") {
                        Task { await model.refreshOpenPR(pr.number, in: projectID, force: true) }
                    }
                }
            }
        }
        // The accent button's height, whatever shows: the bar is as tall
        // while a review launches as once it has its button, and what is
        // under it does not move when the launch ends.
        .frame(minHeight: DefaultTheme.size(32))
    }

    /// The workflows a PR can start (ADR-0017): run one on this PR, the
    /// Jira key found in it; the run opens in the Workflows tab.
    @ViewBuilder
    private var workflowMenu: some View {
        // A workflow that works on its own branch does not run on a PR's read-only checkout (ADR-0021).
        let candidates = model.workflows.workflows.filter {
            $0.triggers.contains(.pullRequest) && $0.workspace == .project
        }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates) { workflow in
                    Button(workflow.name) {
                        let inputs = RunInputs(trigger: .pullRequest, projectID: projectID, prNumber: pr.number)
                        if let run = model.startWorkflowRun(workflow.id, inputs: inputs) {
                            model.workflows.detail = .run(run)
                            model.workflows.revealRequest = UUID()
                        }
                    }
                }
                let runs = model.workflows.runs.filter { $0.inputs.prNumber == pr.number && $0.inputs.projectID == projectID }
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
                    .themeFont(size: 12, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Run a workflow on this PR — or open one of its runs")
        }
    }
}

// MARK: - Review with no tab

/// No PR open: Review has nothing of its own — the way to Browse is here.
/// Unless a review asked for by reference is on its way: the wait says so
/// instead of "nothing open".
private struct PRReviewEmptyState: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: DefaultTheme.space(10)) {
            if let reference = model.prReviewsOpening.first {
                ProgressView().controlSize(.small)
                Text("Opening \(PRReviewsOpening.label(reference)) for review…")
                    .themeFont(size: 14, weight: .semibold)
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("Its tab opens, and its review starts, as soon as GitHub answers.")
                    .themeFont(size: 12)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                AppIcon("sparkles", size: 31)
                    .foregroundStyle(DefaultTheme.mutedText)
                Text("No pull request open for review")
                    .themeFont(size: 14, weight: .semibold)
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("Pick one in Browse: double-click a row, press Return, or select several and open them together.")
                    .themeFont(size: 12)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                AccentButton("Browse pull requests", systemImage: "tablecells") {
                    withAnimation(.hover) { model.prMode = .browse }
                }
                .padding(.top, DefaultTheme.space(4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
    }
}

// MARK: - The session drawer

/// The review session's drawer, over the right edge of the workspace: its
/// floating handle, its header, its resize edge and the terminal. It slides
/// over the diff instead of shrinking it: opening it never reflows the
/// code, so no line changes where it wraps.
/// A view of its own: which session runs, whether a launch is under way,
/// how wide it was dragged — what it reads re-runs it alone, never the
/// workspace it covers (audit 2026-11-15).
struct PRSessionDrawer: View {
    let model: AppModel
    let tabID: String
    let projectID: ProjectID
    let pr: GitHubService.PullRequest
    let layout: PRDrawerLayout
    /// Opens the session in the Sessions tab.
    let onOpenSession: (SessionID) -> Void

    /// A drag reports its translation from where it started, not since the
    /// last frame: the width it started from has to be remembered.
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        // The PR's review session, when it runs: what the drawer embeds.
        // Derived, so diff and conversation always talk about the same PR.
        let sessionID: SessionID? = model.liveReviewSession(forPR: pr.number, in: projectID)
        let launching: Bool = model.isLaunchingReview(forPR: pr.number, in: projectID)
        let open: Bool = PRDrawerLayout.isOpen(model, pr: pr.number, in: projectID)
        // Read here, in the body itself: what this view depends on is not
        // left to a closure the geometry reader runs later.
        let preferred: CGFloat = layout.width
        GeometryReader { geometry in
            // One width for the drawer and for the handle's offset — and,
            // clamped the same way, for the bars that step aside
            // (`PRDrawerLayout.covered`).
            let width: CGFloat = PRDrawerLayout.clamped(preferred, available: geometry.size.width)
            ZStack(alignment: .trailing) {
                if open {
                    // The drawer's OWN width never animates: it slides in at
                    // full size. Animating 0 → width resized the terminal on
                    // every frame of the slide, and each resize made the
                    // agent repaint its whole conversation — the duplicated
                    // blocks. The same frame holds the placeholder and then
                    // the terminal: the session arriving changes no width.
                    panel(sessionID)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(DefaultTheme.background)
                        .overlay(alignment: .leading) { resizeHandle(available: geometry.size.width) }
                        .shadow(color: .black.opacity(0.45), radius: 20, x: -8)
                        .transition(.move(edge: .trailing))
                }
                if sessionID != nil || launching {
                    toggle(sessionID, open: open)
                        .padding(.trailing, (open ? width : 0) + 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // The bars that step aside clamp the width as the drawer does.
            .onChange(of: geometry.size.width, initial: true) { _, available in
                if layout.available != available { layout.available = available }
            }
        }
    }

    /// The session's header and terminal — or, before the session exists,
    /// the word that it is on its way.
    @ViewBuilder
    private func panel(_ sessionID: SessionID?) -> some View {
        if let sessionID {
            VStack(spacing: 0) {
                header(sessionID)
                Divider().overlay(DefaultTheme.cardBorder)
                TerminalPane(model: model, sessionID: sessionID, role: .review)
                    .id(sessionID)
            }
        } else {
            launchPlaceholder
        }
    }

    /// A fresh review is a network fetch and a checkout away from its
    /// session: the drawer opens on the click and says so, in the place and
    /// the words the terminal's own "claude is starting…" takes over from.
    private var launchPlaceholder: some View {
        VStack(spacing: DefaultTheme.space(10)) {
            ProgressView().controlSize(.small)
            Text("Preparing the review worktree…")
                .themeFont(size: 12)
                .foregroundStyle(DefaultTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ sessionID: SessionID) -> some View {
        let reviews: [SessionID] = model.reviewSessions(forPR: pr.number, in: projectID)
        return HStack(spacing: DefaultTheme.space(8)) {
            AppIcon("sparkles", size: 12)
                .foregroundStyle(DefaultTheme.accentInk)
            if reviews.count > 1 {
                // One tab per review of this PR: the fresh ones and the
                // ones before them, a click away.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DefaultTheme.space(4)) {
                        ForEach(Array(reviews.enumerated()), id: \.element) { index, id in
                            ReviewSessionTab(model: model, id: id,
                                             label: "Review \(index + 1)",
                                             isActive: id == sessionID) {
                                Task {
                                    await model.selectReviewSession(id, forPR: pr.number,
                                                                    in: projectID)
                                }
                            }
                        }
                    }
                }
            } else {
                ReviewSessionTitle(model: model, id: sessionID)
                Spacer()
            }
            HoverIconButton(systemImage: "plus", help: "New review session") {
                model.startPRReview(pr, in: projectID, fresh: true)
            }
            .disabled(model.isLaunchingReview(forPR: pr.number, in: projectID))
            AgentBrowsingMark(model: model, sessionID: sessionID)
            HoverIconButton(systemImage: "arrow.up.forward.square",
                            help: "Open in the Sessions tab") {
                if model.hasAgentBrowser(sessionID) { model.showInSidePanel(.agent, for: sessionID) }
                onOpenSession(sessionID)
            }
        }
        .padding(.horizontal, DefaultTheme.space(12)).padding(.vertical, DefaultTheme.space(8))
        .background(DefaultTheme.background)
    }

    private func resizeHandle(available: CGFloat) -> some View {
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
                            let start: CGFloat = widthAtDragStart ?? layout.width
                            widthAtDragStart = start
                            layout.width = PRDrawerLayout.clamped(start - value.translation.width,
                                                                  available: available)
                        }
                        .onEnded { _ in
                            widthAtDragStart = nil
                            layout.persistWidth()
                        })
            }
    }

    /// The floating handle: the one control that shows or hides the session,
    /// riding the drawer's edge so it stays the same target either way.
    private func toggle(_ sessionID: SessionID?, open: Bool) -> some View {
        Button {
            withAnimation(.hover) { model.setPRTabDrawer(open: !open, for: tabID) }
        } label: {
            VStack(spacing: DefaultTheme.space(5)) {
                Image(systemName: open ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                AppIcon("sparkles", size: 14.5)
                    .foregroundStyle(DefaultTheme.accentInk)
                if let sessionID, !open {
                    SessionStateDot(model: model, id: sessionID)
                }
            }
            .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(11))
            .background(DefaultTheme.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(DefaultTheme.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
            .hoverBrightness()
        }
        .buttonStyle(.plain)
        .help(open ? "Hide the review session" : "Show the review session")
    }
}

/// What a review session is called: its live title, else the one its
/// record kept, else a generic name.
@MainActor
private func reviewSessionTitle(_ id: SessionID, in model: AppModel) -> String {
    model.sessions.first { $0.id == id }?.title
        ?? model.allRecords.first { $0.id == id }?.title
        ?? "Review session"
}

/// The drawer's title when the PR has one review: the session's name and
/// its state. They change while the agent works, and repaint here alone.
private struct ReviewSessionTitle: View {
    let model: AppModel
    let id: SessionID

    var body: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            Text(reviewSessionTitle(id, in: model))
                .themeFont(size: 12, weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if let state = model.sessions.first(where: { $0.id == id })?.state {
                StatusLabel(state)
            }
        }
    }
}

/// The review's agent browses out of sight (no side panel in the drawer):
/// a globe says so, and the Sessions tab shows it.
private struct AgentBrowsingMark: View {
    let model: AppModel
    let sessionID: SessionID

    var body: some View {
        if model.agentBrowsers[sessionID]?.activity?.isRunning == true {
            AppIcon("globe", size: 12)
                .foregroundStyle(DefaultTheme.accentInk)
                .help("claude is using its browser — open the session to watch")
        }
    }
}

/// A review session in the drawer's tab row: its state dot, "Review n".
/// Dormant sessions have no state: a hollow dot, resumed on click. It reads
/// its session itself — the dot and the tooltip follow the agent without
/// the drawer around them running again.
private struct ReviewSessionTab: View {
    let model: AppModel
    let id: SessionID
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DefaultTheme.space(5)) {
                SessionStateDot(model: model, id: id, size: 6, hollowWhenDormant: true)
                Text(label)
                    .themeFont(size: 11, weight: isActive ? .semibold : .regular)
                    .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                         : DefaultTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, DefaultTheme.space(9))
            .padding(.vertical, DefaultTheme.space(4))
            .background(isActive ? DefaultTheme.surfaceRaised
                        : hovered ? DefaultTheme.surfaceRaised.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(reviewSessionTitle(id, in: model))
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
