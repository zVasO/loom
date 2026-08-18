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
                sidebar
                Divider().overlay(DefaultTheme.cardBorder)
                detail
            }
            .background(DefaultTheme.background)
        }
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(project.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(DefaultTheme.groupHeader)
                if !prs.isEmpty {
                    Text("\(prs.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                Spacer()
                if model.prLoading.contains(project.id) {
                    ProgressView().controlSize(.mini)
                }
                HoverIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                    Task { await model.refreshPRs(for: project.id) }
                }
            }
            .padding(.horizontal, 2)
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
                             onSelect: {
                                 selectedProjectID = project.id
                                 selectedPR = pr
                             },
                             onStartReview: { startReview(pr, project: project) })
            }
        }
        .task(id: project.id) {
            if model.prCache[project.id] == nil {
                await model.refreshPRs(for: project.id)
            }
        }
    }

    private func startReview(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        selectedProjectID = project.id
        selectedPR = pr
        Task {
            if let id = await model.launchPRReviewSession(pr, in: project.id) {
                onOpenSession(id)
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
                    Spacer()
                    AccentButton(model.reviewSession(forPR: pr.number, in: project.id) != nil
                                 ? "Open review session" : "Start review",
                                 systemImage: "sparkles") {
                        startReview(pr, project: project)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(DefaultTheme.background)
                Divider().overlay(DefaultTheme.cardBorder)
                PRWorkspaceView(model: model, project: project, pr: pr,
                                onBack: nil, onOpenSession: onOpenSession)
            }
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

/// A PR in the global sidebar: CI dot, number, title — sparkles quick action
/// on hover starts (or reopens) its review session.
private struct PRSidebarRow: View {
    let pr: GitHubService.PullRequest
    let isSelected: Bool
    let hasSession: Bool
    let onSelect: () -> Void
    let onStartReview: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pr.checksPassing ? DefaultTheme.groupHeader : DefaultTheme.danger)
                .frame(width: 6, height: 6)
            Text("#\(pr.number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
            Text(pr.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            Spacer()
            if hovered {
                HoverIconButton(systemImage: "sparkles",
                                help: hasSession ? "Open the review session"
                                                 : "Start a review session",
                                action: onStartReview)
            } else if hasSession {
                Circle().fill(AppModel.color(hex: "#A78BFA")).frame(width: 5, height: 5)
                    .help("A review session exists for this PR")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
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
