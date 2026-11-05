import Foundation
import LoomCore

/// One line of the PRs tab's Browse table. Two sources feed it: a project's
/// list (the full row — checks, reviews, size) and a GitHub search or the
/// inbox (a hit — no branch, no checks). A hit whose PR is in a loaded
/// project list is shown with that richer row instead.
public struct PRBrowseRow: Identifiable, Equatable, Sendable {
    /// `<project uuid>#n` — the PR tab's key — when a project holds the PR;
    /// `owner/name#n` for a hit no project clones yet. Two projects cloning
    /// one repository give two rows, never one id twice.
    public let id: String
    public let projectID: ProjectID?
    /// `owner/name` — empty when the project is no known GitHub clone.
    public let repo: String
    /// What the Repository column shows: `owner/name`, else the project's name.
    public let place: String
    public let number: Int
    public let title: String
    public let author: String
    /// GitHub's ISO-8601 timestamp: sorts chronologically as a string.
    public let updatedAt: String
    public let url: String
    public let isDraft: Bool
    public let labels: [GitHubService.Label]
    /// The full row — nil for a hit, which knows neither checks nor reviews.
    public let pr: GitHubService.PullRequest?
    /// Where the PR's review session stands — see `SessionRank`. Decided by
    /// the app, which knows the sessions; a plain value so the column sorts.
    public let sessionRank: Int

    /// The session column's order: the one that waits on the user first.
    public enum SessionRank {
        public static let needsInput = 0
        public static let working = 1
        public static let exists = 2
        public static let none = 3
    }

    /// A row of a project's list.
    public init(pr: GitHubService.PullRequest, projectID: ProjectID, projectName: String,
                repo: String?, sessionRank: Int = SessionRank.none) {
        id = PRTab.key(projectID, pr.number)
        self.projectID = projectID
        if let repo, !repo.isEmpty {
            self.repo = repo
            place = repo
        } else {
            self.repo = ""
            place = projectName
        }
        number = pr.number
        title = pr.title
        author = pr.author
        updatedAt = pr.updatedAt
        url = pr.url
        isDraft = pr.isDraft
        labels = pr.labels
        self.pr = pr
        self.sessionRank = sessionRank
    }

    /// A hit of the inbox or a search, in no loaded list. `projectID` is the
    /// project cloning its repository, when there is one.
    public init(hit: GitHubService.PRSearchHit, projectID: ProjectID? = nil,
                sessionRank: Int = SessionRank.none) {
        id = projectID.map { PRTab.key($0, hit.number) } ?? hit.id
        self.projectID = projectID
        repo = hit.repo
        place = hit.repo
        number = hit.number
        title = hit.title
        author = hit.author
        updatedAt = hit.updatedAt
        url = hit.url
        isDraft = hit.isDraft
        labels = hit.labels
        pr = nil
        self.sessionRank = sessionRank
    }

    // MARK: Sort keys — what the sortable columns compare

    /// Failing first, then running, then green; unknown (a hit) last.
    public var ciRank: Int {
        guard let pr else { return 3 }
        if !pr.checksPassing { return 0 }
        if pr.checksPending { return 1 }
        return 2
    }

    /// Changes requested first, then waiting on a review, nothing asked,
    /// approved; unknown (a hit) last.
    public var reviewRank: Int {
        guard let pr else { return 4 }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED": return 0
        case "REVIEW_REQUIRED": return 1
        case "APPROVED": return 3
        default: return 2
        }
    }

    /// Lines touched; -1 when unknown, so a hit sorts below an empty PR.
    public var size: Int {
        guard let pr else { return -1 }
        return pr.additions + pr.deletions
    }

    /// Every token of the typed text must match somewhere — the same rule
    /// as the rest of the PRs tab.
    public func matches(query: String) -> Bool {
        var fields = ["#\(number)", title, author, repo, place] + labels.map(\.name)
        if let pr {
            fields += [pr.branch, pr.baseBranch] + pr.reviewers
        }
        return PRSidebarFilter.matches(query, in: fields)
    }
}
