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

    @Test("a PR row carries reviewers (users and teams), assignees, labels, verdicts, size, head")
    func parseEnrichedList() throws {
        let json = """
        [{"number": 7, "title": "Enrich", "author": {"login": "vaso"},
          "headRefName": "feat", "baseRefName": "main", "headRefOid": "abc123",
          "reviewDecision": "CHANGES_REQUESTED", "statusCheckRollup": [],
          "updatedAt": "2026-09-01T10:00:00Z", "url": "https://x", "isDraft": false,
          "reviewRequests": [{"__typename": "User", "login": "alice"},
                             {"__typename": "Team", "name": "Core", "slug": "core"}],
          "assignees": [{"login": "bob", "id": "1"}],
          "labels": [{"name": "bug", "color": "d73a4a"}],
          "latestReviews": [{"author": {"login": "carol"}, "state": "APPROVED"},
                            {"author": {"login": "dave"}, "state": "CHANGES_REQUESTED"}],
          "additions": 120, "deletions": 8, "changedFiles": 5, "mergeable": "CONFLICTING"}]
        """
        let pr = try #require(try GitHubService.parsePRList(Data(json.utf8)).first)
        #expect(pr.reviewers == ["alice", "team/core"])
        #expect(pr.assignees == ["bob"])
        #expect(pr.labels == [GitHubService.Label(name: "bug", colorHex: "d73a4a")])
        #expect(pr.latestReviews.map(\.author) == ["carol", "dave"])
        #expect(pr.latestReviews.map(\.state) == ["APPROVED", "CHANGES_REQUESTED"])
        #expect(pr.additions == 120)
        #expect(pr.deletions == 8)
        #expect(pr.changedFiles == 5)
        #expect(pr.isConflicting)
        #expect(pr.headSHA == "abc123")
        #expect(pr.baseBranch == "main")
    }

    @Test("rows without the enrichment fields still parse, with empty defaults")
    func parseListWithoutEnrichment() throws {
        let json = """
        [{"number": 1, "title": "t", "author": {"login": "a"}, "headRefName": "b",
          "reviewDecision": "", "statusCheckRollup": [], "updatedAt": "", "url": "", "isDraft": false}]
        """
        let pr = try #require(try GitHubService.parsePRList(Data(json.utf8)).first)
        #expect(pr.reviewers.isEmpty)
        #expect(pr.labels.isEmpty)
        #expect(pr.latestReviews.isEmpty)
        #expect(pr.additions == 0)
        #expect(pr.mergeable == "")
        #expect(!pr.isConflicting)
    }

    @Test("the list field set names every key the parser reads")
    func listFieldsCoverTheParser() {
        let fields = Set(GitHubService.listFields.split(separator: ",").map(String.init))
        for key in ["number", "title", "author", "headRefName", "baseRefName", "headRefOid",
                    "reviewDecision", "statusCheckRollup", "updatedAt", "url", "isDraft",
                    "reviewRequests", "assignees", "labels", "latestReviews",
                    "additions", "deletions", "changedFiles", "mergeable"] {
            #expect(fields.contains(key), "\(key) is parsed but not requested")
        }
    }

    // GitHub's "Viewed" checkbox on PR files — GraphQL only, paged by 100.
    @Test("a file-views page carries paths, the three states, node id, head and the next cursor")
    func parseFileViewsPage() throws {
        let json = """
        {"data": {"repository": {"pullRequest": {"id": "PR_kwDOA", "headRefOid": "abc123",
          "files": {"pageInfo": {"hasNextPage": true, "endCursor": "Y3Vyc29y"},
                    "nodes": [{"path": "a.swift", "viewerViewedState": "VIEWED"},
                              {"path": "b.swift", "viewerViewedState": "UNVIEWED"},
                              {"path": "c.swift", "viewerViewedState": "DISMISSED"}]}}}}}
        """
        let page = try GitHubService.parseFileViewsPage(Data(json.utf8))
        #expect(page.prNodeID == "PR_kwDOA")
        #expect(page.headSHA == "abc123")
        #expect(page.files.map(\.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(page.files.map(\.state) == [.viewed, .unviewed, .dismissed])
        #expect(page.nextCursor == "Y3Vyc29y")
    }

    @Test("the last page has no cursor, and an unknown state reads as unviewed")
    func lastFileViewsPage() throws {
        let json = """
        {"data": {"repository": {"pullRequest": {"id": "PR_1", "headRefOid": "h",
          "files": {"pageInfo": {"hasNextPage": false, "endCursor": "end"},
                    "nodes": [{"path": "z.swift", "viewerViewedState": "SOMETHING_NEW"}]}}}}}
        """
        let page = try GitHubService.parseFileViewsPage(Data(json.utf8))
        #expect(page.nextCursor == nil)
        #expect(page.files.first?.state == .unviewed)
    }

    @Test("file-views arguments name the PR, and pass the cursor only after the first page")
    func fileViewsArguments() throws {
        let first = GitHubService.fileViewsArguments(number: 42, cursor: nil)
        #expect(first.prefix(2) == ["api", "graphql"])
        #expect(first.contains("number=42"))
        #expect(first.contains("owner={owner}") && first.contains("name={repo}"))
        // gh fills {owner}/{repo} in typed (-F) fields only — a raw -f field
        // would send the braces verbatim and every call would fail.
        for placeholder in ["owner={owner}", "name={repo}"] {
            let index = try #require(first.firstIndex(of: placeholder))
            #expect(first[index - 1] == "-F", "\(placeholder) must ride a typed field")
        }
        #expect(!first.contains { $0.hasPrefix("cursor=") })
        let next = GitHubService.fileViewsArguments(number: 42, cursor: "c2")
        #expect(next.contains("cursor=c2"))
        #expect(next.last?.contains("viewerViewedState") == true)
    }

    @Test("marking a file viewed or unviewed picks the matching mutation")
    func fileViewedArguments() {
        let mark = GitHubService.fileViewedArguments(prNodeID: "PR_1", path: "a.swift", viewed: true)
        #expect(mark.contains("id=PR_1") && mark.contains("path=a.swift"))
        #expect(mark.last?.contains("markFileAsViewed(") == true)
        #expect(mark.last?.contains("unmarkFileAsViewed") == false)
        let unmark = GitHubService.fileViewedArguments(prNodeID: "PR_1", path: "a.swift", viewed: false)
        #expect(unmark.last?.contains("unmarkFileAsViewed(") == true)
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

    // The rollup mixes GitHub Actions check runs and legacy commit statuses:
    // both must colour the dot, and each keeps its name and link.
    @Test("a failing check run turns the PR red — it used to pass for green")
    func checkRunFailure() throws {
        let json = """
        [{"number": 1, "title": "t", "author": {"login": "a"}, "headRefName": "b",
          "reviewDecision": "", "updatedAt": "", "url": "", "isDraft": false,
          "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "build", "status": "COMPLETED",
             "conclusion": "FAILURE", "detailsUrl": "https://ci/1", "workflowName": "CI"},
            {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED",
             "conclusion": "SUCCESS", "detailsUrl": "https://ci/2", "workflowName": "CI"},
            {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS",
             "conclusion": "", "detailsUrl": "https://ci/3", "workflowName": "Nightly"},
            {"__typename": "StatusContext", "context": "codecov", "state": "SUCCESS",
             "targetUrl": "https://cov"}]}]
        """
        let pr = try #require(try GitHubService.parsePRList(Data(json.utf8)).first)
        #expect(pr.checksPassing == false)
        #expect(pr.checksPending)
        #expect(pr.checks.map(\.name) == ["build", "lint", "e2e", "codecov"])
        #expect(pr.checks.map(\.state) == [.failure, .success, .pending, .success])
        #expect(pr.checks[0].link == "https://ci/1")
        #expect(pr.checks[0].workflow == "CI")
        #expect(pr.checks[3].workflow == "")
        #expect(pr.failingChecks == 1 && pr.passingChecks == 2 && pr.pendingChecks == 1)
    }

    @Test("check conclusions and status states fold into one scale")
    func checkStates() {
        let checks = GitHubService.parseChecks([
            ["name": "a", "status": "COMPLETED", "conclusion": "SKIPPED"],
            ["name": "b", "status": "COMPLETED", "conclusion": "CANCELLED"],
            ["name": "c", "status": "COMPLETED", "conclusion": "TIMED_OUT"],
            ["name": "d", "status": "QUEUED", "conclusion": ""],
            ["name": "e", "status": "COMPLETED", "conclusion": "NEUTRAL"],
            ["context": "f", "state": "ERROR"],
            ["context": "g", "state": "PENDING"],
            ["context": "h", "state": "EXPECTED"],
        ])
        #expect(checks.map(\.state) == [.skipped, .cancelled, .failure, .pending, .neutral,
                                         .failure, .pending, .pending])
    }

    @Test("a check without a name still counts — its state is what matters")
    func namelessCheck() {
        let checks = GitHubService.parseChecks([["state": "FAILURE"], ["state": "SUCCESS"], [:]])
        #expect(checks.map(\.state) == [.failure, .success])
    }

    @Test("a cached row without checks decodes to none")
    func checksDecodeDefault() throws {
        let json = """
        {"number": 1, "title": "t", "author": "a", "branch": "b", "baseBranch": "main",
         "reviewDecision": "", "checksPassing": true, "isDraft": false, "updatedAt": "", "url": ""}
        """
        let pr = try JSONDecoder().decode(GitHubService.PullRequest.self, from: Data(json.utf8))
        #expect(pr.checks.isEmpty)
        #expect(!pr.checksPending)
    }

    // The catalog: what `gh repo list` says about an organization's repositories.
    @Test("a repository row carries its name, description, visibility and last push")
    func parseRepoList() throws {
        let json = """
        [{"nameWithOwner": "acme/core", "description": "The API", "isPrivate": true,
          "isArchived": false, "isFork": false, "pushedAt": "2026-09-01T10:00:00Z"},
         {"nameWithOwner": "acme/web", "description": null, "isPrivate": false,
          "isArchived": false, "isFork": true, "pushedAt": "2026-08-01T10:00:00Z"},
         {"description": "no name"}]
        """
        let repos = try GitHubService.parseRepoList(Data(json.utf8))
        #expect(repos.map(\.nameWithOwner) == ["acme/core", "acme/web"])
        #expect(repos[0].description == "The API")
        #expect(repos[0].isPrivate)
        #expect(repos[1].description == "")
        #expect(repos[1].isFork)
        #expect(repos[0].name == "core" && repos[0].owner == "acme")
        #expect(Set(GitHubService.repoFields.split(separator: ",").map(String.init))
                == ["nameWithOwner", "description", "isPrivate", "isArchived", "isFork", "pushedAt"])
    }

    // Cross-repository search: the inbox and the sidebar's GitHub search.
    @Test("a search hit names its repository, number, title, author and labels")
    func parsePRSearch() throws {
        let json = """
        [{"repository": {"name": "core", "nameWithOwner": "acme/core"}, "number": 42,
          "title": "Fix cache", "author": {"login": "vaso"}, "updatedAt": "2026-09-01T10:00:00Z",
          "url": "https://github.com/acme/core/pull/42", "isDraft": true,
          "labels": [{"name": "bug", "color": "d73a4a"}]},
         {"repository": {"nameWithOwner": "acme/web"}, "number": 7, "title": "x"}]
        """
        let hits = try GitHubService.parsePRSearch(Data(json.utf8))
        #expect(hits.map(\.id) == ["acme/core#42", "acme/web#7"])
        #expect(hits[0].author == "vaso")
        #expect(hits[0].isDraft)
        #expect(hits[0].labels == [GitHubService.Label(name: "bug", colorHex: "d73a4a")])
        #expect(hits[1].author == "—")
        #expect(Set(GitHubService.searchFields.split(separator: ",").map(String.init))
                == ["repository", "number", "title", "author", "updatedAt", "url", "isDraft", "labels"])
    }

    @Test("search arguments: text, one --owner per organization, @me as a qualifier")
    func searchArguments() {
        let inbox = GitHubService.searchArguments(text: "", owners: [], reviewRequestedToMe: true, limit: 100)
        #expect(inbox.first == "review-requested:@me")
        #expect(!inbox.contains("--owner"))
        #expect(inbox.contains("--state") && inbox.contains("open"))
        let search = GitHubService.searchArguments(text: " cache ", owners: ["acme", "beta"],
                                                   reviewRequestedToMe: false, limit: 50)
        #expect(search.prefix(5) == ["cache", "--owner", "acme", "--owner", "beta"])
        #expect(search.suffix(4) == ["--limit", "50", "--json", GitHubService.searchFields])
        let bare = GitHubService.searchArguments(text: "", owners: [], reviewRequestedToMe: false, limit: 10)
        #expect(bare.first == "--state", "no text means no positional argument")
    }

    // One review for every drafted comment: the verdict, the summary and
    // the anchored comments travel in a single POST.
    @Test("a review payload carries the event, the head and every comment")
    func reviewPayload() throws {
        let payload = GitHubService.reviewPayload(
            verdict: .requestChanges, body: " Two things. ", sha: "abc",
            comments: [DraftComment(path: "a.swift", firstLine: 3, lastLine: 5, body: "why"),
                       DraftComment(path: "b.swift", firstLine: 9, lastLine: 9, side: "LEFT", body: "gone")])
        #expect(payload["event"] as? String == "REQUEST_CHANGES")
        #expect(payload["commit_id"] as? String == "abc")
        #expect(payload["body"] as? String == "Two things.")
        let comments = try #require(payload["comments"] as? [[String: Any]])
        #expect(comments.count == 2)
        #expect(comments[0]["start_line"] as? Int == 3)
        #expect(comments[0]["line"] as? Int == 5)
        #expect(comments[0]["start_side"] as? String == "RIGHT")
        #expect(comments[1]["start_line"] == nil, "a one-line comment must not span")
        #expect(comments[1]["side"] as? String == "LEFT")
        #expect(comments[1]["body"] as? String == "gone")
    }

    @Test("an empty summary is left out; a verdict maps to its REST event")
    func reviewPayloadWithoutBody() {
        let payload = GitHubService.reviewPayload(verdict: .approve, body: "  ", sha: "h", comments: [])
        #expect(payload["body"] == nil)
        #expect(payload["event"] as? String == "APPROVE")
        #expect(GitHubService.Verdict.comment.event == "COMMENT")
        #expect((payload["comments"] as? [[String: Any]])?.isEmpty == true)
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

