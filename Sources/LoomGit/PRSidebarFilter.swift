import Foundation

/// The instant filter of the PRs sidebar: what is typed narrows every list
/// already on screen — PR rows, inbox hits, catalog repositories — without
/// a network call. Every token must match somewhere (AND), case ignored.
public enum PRSidebarFilter {
    /// The words of a query; empty means "no filter".
    public static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(_ pr: GitHubService.PullRequest, query: String) -> Bool {
        matches(query, in: ["#\(pr.number)", pr.title, pr.author, pr.branch, pr.baseBranch]
                + pr.labels.map(\.name) + pr.reviewers)
    }

    public static func matches(_ repo: GitHubService.Repository, query: String) -> Bool {
        matches(query, in: [repo.nameWithOwner, repo.description])
    }

    public static func matches(_ hit: GitHubService.PRSearchHit, query: String) -> Bool {
        matches(query, in: ["#\(hit.number)", hit.repo, hit.title, hit.author]
                + hit.labels.map(\.name))
    }

    /// A project row matches on its name or the repository it clones.
    public static func matches(projectName: String, repo: String?, query: String) -> Bool {
        matches(query, in: [projectName, repo ?? ""])
    }

    static func matches(_ query: String, in fields: [String]) -> Bool {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return true }
        let haystack = fields.joined(separator: "\n").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
