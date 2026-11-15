import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The PRs tab works in two modes that never share the screen: BROWSE, a
/// table to find pull requests in, and REVIEW, the PRs opened from it —
/// one tab each, the diff, the review session in its drawer.
enum PRMode: String {
    case browse
    case review
}

/// What the Browse table lists, picked in its left rail.
enum PRBrowseScope: Hashable {
    /// Every open PR waiting on the user's review, all repositories.
    case inbox
    /// Every project's list, through the selected filter.
    case allProjects
    case project(ProjectID)
    /// GitHub's answer to the text typed then Return.
    case search
    /// The organizations' repositories not added as projects yet.
    case repositories

    /// Lists of projects, seen through the PR filter — the inbox and a
    /// search are GitHub queries of their own.
    var isProjectScope: Bool {
        switch self {
        case .allProjects, .project: return true
        default: return false
        }
    }
}

extension AppModel {

    /// The projects whose lists a scope reads.
    func projectIDs(in scope: PRBrowseScope) -> [ProjectID] {
        switch scope {
        case .allProjects: return projects.map(\.id)
        case .project(let id): return [id]
        case .inbox, .search, .repositories: return []
        }
    }

    /// Where a PR's review session stands, as the Session column sorts it.
    func reviewSessionRank(forPR number: Int, in projectID: ProjectID) -> Int {
        guard let id = reviewSession(forPR: number, in: projectID) else {
            return PRBrowseRow.SessionRank.none
        }
        switch sessions.first(where: { $0.id == id })?.state {
        case .needsInput?: return PRBrowseRow.SessionRank.needsInput
        case .working?, .starting?: return PRBrowseRow.SessionRank.working
        default: return PRBrowseRow.SessionRank.exists
        }
    }

    /// The table's rows for a scope, unsorted and unfiltered.
    func browseRows(in scope: PRBrowseScope) -> [PRBrowseRow] {
        switch scope {
        case .inbox:
            return hitRows(inbox)
        case .search:
            return hitRows(searchResults ?? [])
        case .repositories:
            return []
        case .allProjects, .project:
            let ids = Set(projectIDs(in: scope))
            return projects.filter { ids.contains($0.id) }.flatMap { project in
                let repo = repoName(for: project.id)
                return prs(for: project.id).map { pr in
                    PRBrowseRow(pr: pr, projectID: project.id, projectName: project.name, repo: repo,
                                sessionRank: reviewSessionRank(forPR: pr.number, in: project.id))
                }
            }
        }
    }

    /// A hit whose PR a loaded list holds is shown with that richer row:
    /// checks, review state and size instead of dashes.
    private func hitRows(_ hits: [GitHubService.PRSearchHit]) -> [PRBrowseRow] {
        hits.map { hit in
            guard let project = project(forRepo: hit.repo) else { return PRBrowseRow(hit: hit) }
            let rank = reviewSessionRank(forPR: hit.number, in: project.id)
            if let pr = prs(for: project.id).first(where: { $0.number == hit.number }) {
                return PRBrowseRow(pr: pr, projectID: project.id, projectName: project.name,
                                   repo: hit.repo, sessionRank: rank)
            }
            return PRBrowseRow(hit: hit, projectID: project.id, sessionRank: rank)
        }
    }

    /// Rows picked in the table go to Review, each in a kept tab — the first
    /// one on screen. A hit is fetched first (and its repository cloned, on
    /// the user's word, when no project holds it).
    func openForReview(_ rows: [PRBrowseRow]) {
        guard !rows.isEmpty else { return }
        var first: String?
        var hits: [PRBrowseRow] = []
        for row in rows {
            if let pr = row.pr, let projectID = row.projectID {
                openPRTab(pr, in: projectID)
                if first == nil { first = row.id }
            } else {
                hits.append(row)
            }
        }
        if let first {
            activatePRTab(first)
            prMode = .review
        }
        guard !hits.isEmpty else { return }
        // One after the other: a clone to confirm is a single slot.
        Task {
            for hit in hits where !hit.repo.isEmpty {
                await openPR(repo: hit.repo, number: hit.number, pin: true)
            }
        }
    }

    /// The one-click review: the PR's tab kept and shown in Review, its
    /// drawer opened and its session started (or reattached). `fresh`: a new
    /// session takes over the PR instead of the one it has.
    func startPRReview(_ pr: GitHubService.PullRequest, in projectID: ProjectID,
                       fresh: Bool = false) {
        let tabID = PRTab.key(projectID, pr.number)
        // The drawer BEFORE the work, not after it: a fresh review is a
        // network fetch and a checkout away from its session, a reattach a
        // fetch away from a terminal that already exists. The click answers
        // at once; the session takes its place in the drawer when it is there.
        let drawerWasOpen = prTabs.tab(tabID)?.drawerOpen ?? false
        // The animated write before any other to the tabs: the first one of
        // a pass decides how it is drawn, and the drawer slides in.
        if prTabs.contains(tabID) {
            withAnimation(.hover) { setPRTabDrawer(open: true, for: tabID) }
        }
        openPRTab(pr, in: projectID)
        prMode = .review
        // A PR that had no tab until now: its drawer opens with it.
        setPRTabDrawer(open: true, for: tabID)
        guard !isLaunchingReview(forPR: pr.number, in: projectID) else { return }
        // Started here, not in the task below: the PR is "launching" before
        // this function returns, so the drawer has something to say.
        let launch = reviewLaunchTask(pr, in: projectID, fresh: fresh)
        Task {
            // No session came of it (the error is on screen): a drawer this
            // click opened has nothing to show.
            if await launch.value == nil, !drawerWasOpen {
                setPRTabDrawer(open: false, for: tabID)
            }
        }
    }

    /// Starts — or reattaches — the review of the pull request a reference
    /// names (a github.com pull URL, `owner/repo#12`; `#12` or `12` against
    /// the selected project), as "Start review" does for a row of the PRs
    /// tab: the tab, its review mode and the session drawer show at once,
    /// the row and the checkout load behind them. What goes wrong (no such
    /// PR, gh missing, a repository that is not a project) shows in the PRs
    /// tab, where such failures already show. Returns at once.
    func startPRReview(reference: PRReference) {
        guard let repo = reference.repo else {
            // A bare number means the selected project, as for `openPR(reference:)`.
            guard let projectID = selectedProject ?? projects.first?.id else {
                startupError = "Add a project first — a bare PR number needs a repository."
                return
            }
            startPRReview(number: reference.number, in: projectID,
                          repo: repoName(for: projectID), asked: reference)
            return
        }
        if let project = project(forRepo: repo) {
            startPRReview(number: reference.number, in: project.id, repo: repo, asked: reference)
            return
        }
        // No project clones it — or, just after launch, the project that
        // does has not had its remote read yet. Asked twice: once is enough.
        guard !prReviewsOpening.contains(reference) else { return }
        prReviewsOpening.append(reference)
        Task {
            let project = await resolvedProject(forRepo: repo)
            prReviewsOpening.removeAll { $0 == reference }
            if let project {
                startPRReview(number: reference.number, in: project.id, repo: repo, asked: reference)
            } else {
                // Not a project: the clone dialog, with the intent to review
                // carried through it — `confirmClone` starts the review.
                pendingClone = PendingClone(repo: repo, number: reference.number,
                                            pin: true, startsReview: true)
            }
        }
    }

    /// The Review mode's badge: how many tabs, and whether a review waits
    /// on the user.
    var reviewNeedsInput: Bool {
        prTabs.tabs.contains { tab in
            reviewSessionRank(forPR: tab.pr.number, in: tab.projectID)
                == PRBrowseRow.SessionRank.needsInput
        }
    }
}
