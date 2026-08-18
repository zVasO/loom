import Testing
import LoomGit
import Foundation

// v4 — PR review: gh JSON parsing is the pure seam we contract against;
// the process calls themselves go through the user's authenticated gh.

@Suite("GitHubService — gh JSON parsing")
struct GitHubServiceTests {

    @Test("a PR list row carries number, title, branch, review state and checks")
    func parseList() throws {
        let json = """
        [{"number": 42, "title": "Fix cache invalidation", "author": {"login": "vaso"},
          "headRefName": "fix/cache", "reviewDecision": "REVIEW_REQUIRED",
          "statusCheckRollup": [{"state": "SUCCESS"}, {"state": "FAILURE"}],
          "updatedAt": "2026-08-17T10:00:00Z", "url": "https://github.com/o/r/pull/42",
          "isDraft": false}]
        """
        let prs = try GitHubService.parsePRList(Data(json.utf8))
        #expect(prs.count == 1)
        let pr = try #require(prs.first)
        #expect(pr.number == 42)
        #expect(pr.title == "Fix cache invalidation")
        #expect(pr.author == "vaso")
        #expect(pr.branch == "fix/cache")
        #expect(pr.reviewDecision == "REVIEW_REQUIRED")
        #expect(pr.checksPassing == false, "one FAILURE poisons the rollup")
        #expect(pr.isDraft == false)
    }

    @Test("PR detail: body, comments and review threads")
    func parseDetail() throws {
        let json = """
        {"body": "This PR fixes the cache.", "number": 42,
         "comments": [{"author": {"login": "alice"}, "body": "LGTM but tests?",
                       "createdAt": "2026-08-17T09:00:00Z"}],
         "reviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED",
                      "body": "Missing edge case"}]}
        """
        let detail = try GitHubService.parsePRDetail(Data(json.utf8))
        #expect(detail.body == "This PR fixes the cache.")
        #expect(detail.comments.first?.author == "alice")
        #expect(detail.comments.first?.body == "LGTM but tests?")
        #expect(detail.reviews.first?.state == "CHANGES_REQUESTED")
    }

    @Test("empty checks rollup means passing — no signal is not a failure")
    func emptyChecks() throws {
        let json = """
        [{"number": 1, "title": "t", "author": {"login": "a"}, "headRefName": "b",
          "reviewDecision": "", "statusCheckRollup": [], "updatedAt": "2026-08-17T10:00:00Z",
          "url": "https://x", "isDraft": true}]
        """
        let prs = try GitHubService.parsePRList(Data(json.utf8))
        #expect(prs.first?.checksPassing == true)
        #expect(prs.first?.isDraft == true)
    }
}

