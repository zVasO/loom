import Testing
@testable import LoomGit

// Typing in the sidebar narrows what is already on screen: every word must
// match somewhere in the row, case ignored.
@Suite("PRSidebarFilter — the instant filter of the sidebar")
struct PRSidebarFilterTests {

    private let pr = GitHubService.PullRequest(
        number: 42, title: "Fix Cache invalidation", author: "vaso", branch: "fix/cache",
        baseBranch: "main", reviewDecision: "", checksPassing: true, isDraft: false,
        updatedAt: "", url: "", reviewers: ["alice"],
        labels: [.init(name: "bug", colorHex: "")])

    @Test("an empty query matches everything")
    func emptyQuery() {
        #expect(PRSidebarFilter.matches(pr, query: ""))
        #expect(PRSidebarFilter.matches(pr, query: "   "))
    }

    @Test("a PR matches on number, title, author, branch, label or reviewer, case ignored")
    func prFields() {
        for query in ["42", "#42", "cache", "CACHE inval", "vaso", "fix/", "bug", "alice", "main"] {
            #expect(PRSidebarFilter.matches(pr, query: query), Comment(rawValue: query))
        }
        #expect(!PRSidebarFilter.matches(pr, query: "cache bob"), "every word must match")
        #expect(!PRSidebarFilter.matches(pr, query: "43"))
    }

    @Test("a repository matches on its name or description; a hit on repo, title, author")
    func repoAndHit() {
        let repo = GitHubService.Repository(nameWithOwner: "acme/core", description: "The API")
        #expect(PRSidebarFilter.matches(repo, query: "core"))
        #expect(PRSidebarFilter.matches(repo, query: "api"))
        #expect(!PRSidebarFilter.matches(repo, query: "web"))
        let hit = GitHubService.PRSearchHit(repo: "acme/web", number: 7, title: "Dark mode",
                                            author: "bob")
        #expect(PRSidebarFilter.matches(hit, query: "web dark"))
        #expect(PRSidebarFilter.matches(hit, query: "#7"))
        #expect(!PRSidebarFilter.matches(hit, query: "alice"))
        #expect(PRSidebarFilter.matches(projectName: "loom", repo: "dyger/loom", query: "dyger"))
        #expect(!PRSidebarFilter.matches(projectName: "loom", repo: nil, query: "dyger"))
    }
}
