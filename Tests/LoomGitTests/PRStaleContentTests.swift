import Testing
import Foundation
@testable import LoomGit

// A refetched list used to drop everything loaded for every PR of its
// project — description, diff, comments, the guided tour. Only the PRs that
// moved, and the ones the list no longer holds, have anything stale.
@Suite("GitHubService — what a refetched list makes stale")
struct PRStaleContentTests {

    private func pullRequest(_ number: Int, head: String = "abc",
                             updatedAt: String = "2026-11-10T10:00:00Z",
                             checksPassing: Bool = true) -> GitHubService.PullRequest {
        GitHubService.PullRequest(number: number, title: "Title \(number)", author: "alice",
                                  branch: "feature/\(number)", baseBranch: "main",
                                  reviewDecision: "", checksPassing: checksPassing, isDraft: false,
                                  updatedAt: updatedAt,
                                  url: "https://github.com/acme/repo/pull/\(number)",
                                  headSHA: head)
    }

    private func known(_ prs: [GitHubService.PullRequest]) -> [Int: GitHubService.PullRequest] {
        Dictionary(prs.map { ($0.number, $0) }) { first, _ in first }
    }

    @Test("rows that did not move keep what was loaded for them")
    func unchangedRowsStay() {
        let rows = [pullRequest(1), pullRequest(2)]
        #expect(GitHubService.staleContent(previous: rows, known: known(rows), fresh: rows).isEmpty)
    }

    @Test("a new head or a new update stamp is stale; new checks alone are not")
    func movedRows() {
        let before = [pullRequest(1), pullRequest(2), pullRequest(3)]
        let fresh = [pullRequest(1, head: "def"),
                     pullRequest(2, updatedAt: "2026-11-11T08:00:00Z"),
                     pullRequest(3, checksPassing: false)]
        #expect(GitHubService.staleContent(previous: before, known: known(before), fresh: fresh) == [1, 2])
    }

    @Test("a PR the list no longer holds is stale")
    func goneFromTheList() {
        let before = [pullRequest(1), pullRequest(2)]
        #expect(GitHubService.staleContent(previous: before, known: known(before),
                                           fresh: [pullRequest(1)]) == [2])
    }

    @Test("the row known for a PR wins over the list's previous one")
    func knownRowIsTheReference() {
        // The open tab already took the new head: the poll dropped what was
        // loaded then, and what was loaded since is current.
        let listed = [pullRequest(1)]
        let tab = pullRequest(1, head: "def")
        #expect(GitHubService.staleContent(previous: listed, known: known([tab]), fresh: [tab]).isEmpty)
    }

    @Test("a row nothing was known about is stale — nothing says its content is current")
    func unknownRows() {
        #expect(GitHubService.staleContent(previous: [], known: [:], fresh: [pullRequest(4)]) == [4])
    }
}
