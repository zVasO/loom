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

    @State private var selectedProjectID: ProjectID?
    @State private var selectedPR: GitHubService.PullRequest?
    /// The embedded review session: shown in the right drawer, so the user
    /// switches diff ↔ session without leaving the tab.
    @State private var paneSessionID: SessionID?
    @State private var paneOpen = false
    /// Collapsed by default: gh is only queried when a project is EXPANDED —
    /// opening the tab with many projects fires zero requests.
    @State private var expandedProjects: Set<ProjectID> = []
    /// The PR list steps aside when a review starts — toggle to bring it back.
    @State private var sidebarHidden = false
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
                if !sidebarHidden {
                    sidebar
                    Divider().overlay(DefaultTheme.cardBorder)
                }
                detail
            }
            .background(DefaultTheme.background)
            .onAppear { consumePendingPR() }
            .onChange(of: model.pendingPR) { consumePendingPR() }
        }
    }

    /// A PR clicked in the project tab lands here: select it, expand its
    /// project, warm the cache, clear the channel.
    private func consumePendingPR() {
        guard let pending = model.pendingPR else { return }
        selectedProjectID = pending.projectID
        selectedPR = pending.pr
        expandedProjects.insert(pending.projectID)
        Task { await model.ensurePRs(for: pending.projectID) }
        model.pendingPR = nil
    }

    // MARK: Sidebar — projects and their PRs

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(gitProjects, id: \.id) { project in
                    projectGroup(project)
                }
            }
            .padding(12)
        }
        .frame(width: 300)
        .background(DefaultTheme.background)
    }

    private func projectGroup(_ project: ProjectRecord) -> some View {
        let prs = model.prCache[project.id] ?? []
        let expanded = expandedProjects.contains(project.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if expanded {
                        expandedProjects.remove(project.id)
                    } else {
                        expandedProjects.insert(project.id)
                        Task { await model.ensurePRs(for: project.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                        Text(project.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.8)
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
                if model.prLoading.contains(project.id) {
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
                if prs.isEmpty && !model.prLoading.contains(project.id) {
                    Text("No open PR")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.leading, 2)
                }
                ForEach(prs) { pr in
                    PRSidebarRow(pr: pr,
                                 isSelected: selectedPR?.number == pr.number
                                     && selectedProjectID == project.id,
                                 hasSession: model.reviewSession(forPR: pr.number,
                                                                 in: project.id) != nil,
                                 launching: model.isLaunchingReview(forPR: pr.number,
                                                                    in: project.id),
                                 onSelect: {
                                     selectedProjectID = project.id
                                     selectedPR = pr
                                 },
                                 onStartReview: { startReview(pr, project: project) })
                }
            }
        }
    }

    private func startReview(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        guard !model.isLaunchingReview(forPR: pr.number, in: project.id) else { return }
        selectedProjectID = project.id
        selectedPR = pr
        Task {
            if let id = await model.launchPRReviewSession(pr, in: project.id) {
                // Stay in the PR tab: the session opens in the drawer, and the
                // PR list steps aside to give the diff room.
                paneSessionID = id
                withAnimation(.hover) {
                    paneOpen = true
                    sidebarHidden = true
                }
            }
        }
    }

    // MARK: Detail — toolbar, workspace, session drawer

    @ViewBuilder
    private var detail: some View {
        if let pr = selectedPR,
           let project = gitProjects.first(where: { $0.id == selectedProjectID }) {
            VStack(spacing: 0) {
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
            .onChange(of: pr.number) { syncPane(pr, project: project) }
            .onAppear { syncPane(pr, project: project) }
        } else {
            VStack(spacing: 8) {
                Text("Pick a pull request")
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("Every project's open PRs live in the sidebar — sparkles starts a review session.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.mutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DefaultTheme.contentBackground)
        }
    }

    private func toolbar(_ pr: GitHubService.PullRequest,
                         project: ProjectRecord) -> some View {
        HStack(spacing: 10) {
            HoverIconButton(systemImage: "sidebar.leading",
                            help: sidebarHidden ? "Show the PR list" : "Hide the PR list") {
                withAnimation(.hover) { sidebarHidden.toggle() }
            }
            Text("#\(pr.number)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
            Text(pr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
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
            withAnimation(.hover) { paneOpen.toggle() }
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
    /// The pane follows the SELECTED PR: its session when one exists, hidden
    /// otherwise — diff and conversation always talk about the same PR.
    fileprivate func syncPane(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        if let existing = model.reviewSession(forPR: pr.number, in: project.id),
           model.sessions.contains(where: { $0.id == existing }) {
            paneSessionID = existing
        } else {
            paneOpen = false
            paneSessionID = nil
        }
    }

    /// The shared PR workspace, wired once for both regions. `controlsInset`
    /// is what the drawer covers: the diff may pass under it, its buttons
    /// may not.
    fileprivate func workspace(_ pr: GitHubService.PullRequest,
                               project: ProjectRecord,
                               controlsInset: CGFloat) -> some View {
        PRWorkspaceView(model: model, project: project, pr: pr, pane: pane,
                        controlsInset: controlsInset,
                        onOpenSession: onOpenSession,
                        sendToSession: { message in
                            Task {
                                if let id = await model.sendToPRReviewSession(
                                    message, pr: pr, in: project.id) {
                                    paneSessionID = id
                                    withAnimation(.hover) { paneOpen = true }
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
                        } : nil)
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
    let hasSession: Bool
    let launching: Bool
    let onSelect: () -> Void
    let onStartReview: () -> Void
    @State private var hovered = false

    private func chip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(DefaultTheme.surfaceRaised, in: Capsule())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(pr.checksPassing ? DefaultTheme.groupHeader : DefaultTheme.danger)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
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
            }
            Spacer()
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
            .stroke(isSelected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
