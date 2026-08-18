import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import SwiftUI

/// The global PRs tab: every project's open pull requests in one sidebar,
/// the shared PR workspace in the middle, and (phase 3) the review session
/// embedded on the right. "Start review" is the one-click quick action —
/// one claude session per PR, badged, reattached when it already exists.
struct GlobalPRsView: View {
    let model: AppModel
    /// Opens the session in the Sessions tab (used until the pane is embedded).
    let onOpenSession: (SessionID) -> Void

    @State private var selectedProjectID: ProjectID?
    @State private var selectedPR: GitHubService.PullRequest?
    /// The embedded review session (phase 3): shown on the right, so the user
    /// switches diff ↔ session without leaving the tab.
    @State private var paneSessionID: SessionID?
    @State private var paneOpen = false
    /// Collapsed by default: gh is only queried when a project is EXPANDED —
    /// opening the tab with many projects fires zero requests.
    @State private var expandedProjects: Set<ProjectID> = []
    /// The PR list steps aside when a review starts — toggle to bring it back.
    @State private var sidebarHidden = false

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
        if model.prCache[pending.projectID] == nil {
            Task { await model.refreshPRs(for: pending.projectID) }
        }
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
                        if model.prCache[project.id] == nil {
                            Task { await model.refreshPRs(for: project.id) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                        Text(project.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.8)
                        if let cached = model.prCache[project.id], !cached.isEmpty {
                            Text("\(cached.count)")
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
                    HoverIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
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
                // Stay in the PR tab: the session opens in the embedded pane,
                // and the PR list steps aside to give the diff room.
                paneSessionID = id
                paneOpen = true
                withAnimation(.hover) { sidebarHidden = true }
            }
        }
    }

    // MARK: Detail — the shared workspace

    @ViewBuilder
    private var detail: some View {
        if let pr = selectedPR,
           let project = gitProjects.first(where: { $0.id == selectedProjectID }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HoverIconButton(systemImage: "sidebar.leading",
                                    help: sidebarHidden ? "Show the PR list" : "Hide the PR list") {
                        withAnimation(.hover) { sidebarHidden.toggle() }
                    }
                    Spacer()
                    if paneOpen {
                        GhostButton("Hide session", systemImage: "sidebar.trailing") {
                            paneOpen = false
                        }
                    } else if let existing = model.reviewSession(forPR: pr.number, in: project.id) {
                        GhostButton("Show session", systemImage: "sidebar.trailing") {
                            Task {
                                _ = await model.launchPRReviewSession(pr, in: project.id)
                                paneSessionID = existing
                                paneOpen = true
                            }
                        }
                    }
                    if model.isLaunchingReview(forPR: pr.number, in: project.id) {
                        // The checkout fetches from the network: without this
                        // the click felt like a frozen app.
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
                Divider().overlay(DefaultTheme.cardBorder)
                HSplitView {
                    PRWorkspaceView(model: model, project: project, pr: pr,
                                    onBack: nil, onOpenSession: onOpenSession,
                                    sendToSession: { message in
                                        Task {
                                            if let id = await model.sendToPRReviewSession(
                                                message, pr: pr, in: project.id) {
                                                paneSessionID = id
                                                paneOpen = true
                                            }
                                        }
                                    },
                                    transcribeToSession: paneOpen ? { snippet in
                                        guard let id = paneSessionID else { return }
                                        Task {
                                            await model.typeIntoSession("""
                                            \(snippet.file) L\(snippet.firstLine)–L\(snippet.lastLine):
                                            ```diff
                                            \(snippet.code)
                                            ```

                                            """, id: id)
                                        }
                                    } : nil)
                        .frame(minWidth: 420)
                    if paneOpen, let sessionID = paneSessionID {
                        embeddedSession(sessionID)
                            .frame(minWidth: 380)
                    }
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
