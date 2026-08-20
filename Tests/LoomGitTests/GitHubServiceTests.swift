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

    // Line-anchored review comments: GitHub renders a ```suggestion block as
    // a one-click "Apply", so the body must be built exactly.
    @Test("a plain line comment keeps the author's text untouched")
    func plainLineComment() {
        #expect(GitHubService.lineCommentBody("Rename this for clarity.",
                                              suggestion: nil) == "Rename this for clarity.")
    }

    @Test("a suggestion is wrapped in a ```suggestion fence")
    func suggestionBody() {
        let body = GitHubService.lineCommentBody("", suggestion: "let total = a + b")
        #expect(body == "```suggestion\nlet total = a + b\n```")
    }

    @Test("a suggestion with a note keeps the note above the fence")
    func suggestionWithNote() {
        let body = GitHubService.lineCommentBody("Simpler:", suggestion: "a + b")
        #expect(body == "Simpler:\n\n```suggestion\na + b\n```")
    }

    @Test("a multi-line selection asks GitHub for a spanning comment")
    func spanningRange() {
        let payload = GitHubService.lineCommentPayload(path: "src/a.swift", firstLine: 10,
                                                       lastLine: 14, sha: "abc", body: "x")
        #expect(payload["start_line"] as? Int == 10)
        #expect(payload["line"] as? Int == 14)
        #expect(payload["side"] as? String == "RIGHT")
        #expect(payload["commit_id"] as? String == "abc")
    }

    @Test("a single-line selection omits start_line — GitHub rejects a 1-line span")
    func singleLine() {
        let payload = GitHubService.lineCommentPayload(path: "src/a.swift", firstLine: 7,
                                                       lastLine: 7, sha: "abc", body: "x")
        #expect(payload["start_line"] == nil)
        #expect(payload["line"] as? Int == 7)
    }

    @Test("a pure-deletion comment anchors to the LEFT side")
    func leftSidePayload() {
        let payload = GitHubService.lineCommentPayload(path: "src/a.swift", firstLine: 6,
                                                       lastLine: 7, sha: "abc", body: "x",
                                                       side: "LEFT")
        #expect(payload["side"] as? String == "LEFT")
        #expect(payload["start_side"] as? String == "LEFT")
    }

    @Test("a file-level comment targets the whole file, not a line")
    func fileCommentPayload() {
        let payload = GitHubService.fileCommentPayload(path: "src/a.swift",
                                                       sha: "abc", body: "Split this file.")
        #expect(payload["subject_type"] as? String == "file")
        #expect(payload["path"] as? String == "src/a.swift")
        #expect(payload["commit_id"] as? String == "abc")
        #expect(payload["body"] as? String == "Split this file.")
        #expect(payload["line"] == nil, "a file comment must not carry a line")
    }

    // Review comments anchored to code: shown INSIDE the diff, under the line
    // they talk about (what GitHub's own file view does).
    @Test("review comments carry their file, line span, author and body")
    func reviewComments() throws {
        let json = """
        [{"id": 1, "path": "src/a.swift", "line": 14, "start_line": 10, "side": "RIGHT",
          "body": "Rename this.", "user": {"login": "zVasO"},
          "created_at": "2026-08-18T10:00:00Z", "in_reply_to_id": null},
         {"id": 2, "path": "src/a.swift", "line": 14, "start_line": null, "side": "RIGHT",
          "body": "Agreed.", "user": {"login": "other"},
          "created_at": "2026-08-18T11:00:00Z", "in_reply_to_id": 1}]
        """
        let comments = try GitHubService.parseReviewComments(Data(json.utf8))
        #expect(comments.count == 2)
        #expect(comments[0].path == "src/a.swift")
        #expect(comments[0].line == 14)
        #expect(comments[0].startLine == 10)
        #expect(comments[0].author == "zVasO")
        #expect(comments[0].body == "Rename this.")
        #expect(comments[1].replyToID == 1, "replies stay attached to their thread")
    }

    @Test("a file-level comment (no line at all) is kept and flagged as such")
    func fileLevelComment() throws {
        let json = """
        [{"id": 4, "path": "src/c.swift", "line": null, "original_line": null,
          "subject_type": "file", "side": "RIGHT", "body": "Split this file.",
          "user": {"login": "a"}, "created_at": "2026-08-20T10:00:00Z"}]
        """
        let comments = try GitHubService.parseReviewComments(Data(json.utf8))
        #expect(comments.count == 1, "no line is not a reason to drop it")
        #expect(comments.first?.isFileLevel == true)
        #expect(comments.first?.isOutdated == false, "file comments are never outdated")
    }

    @Test("an outdated comment (its line vanished from the diff) is kept, flagged")
    func outdatedComment() throws {
        let json = """
        [{"id": 3, "path": "src/b.swift", "line": null, "original_line": 22, "side": "RIGHT",
          "body": "Stale.", "user": {"login": "a"}, "created_at": "2026-08-18T10:00:00Z"}]
        """
        let comments = try GitHubService.parseReviewComments(Data(json.utf8))
        #expect(comments.first?.line == 22, "falls back to the original line")
        #expect(comments.first?.isOutdated == true)
    }
}

