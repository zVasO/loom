import Testing
import Foundation
import LoomAgents

// What a scheduled review asks claude, and how the report it writes is read:
// leniently — fences, prose, odd spellings — but never at the cost of a
// comment body's own ```suggestion fences.
@Suite("AutoReview — the full-review prompt and its report")
struct AutoReviewTests {

    private let pr = PRReviewCommand.Context(number: 42, title: "Fix the \"cache\" bug",
                                             url: "https://github.com/acme/repo/pull/42",
                                             base: "main", head: "fix/cache")

    @Test("the default prompt names the PR and where the report goes, every placeholder filled")
    func render() {
        let prompt = AutoReviewPrompt.render(template: nil, pr: pr)
        #expect(prompt.contains("pull request #42"))
        #expect(prompt.contains("'cache'"))
        #expect(prompt.contains(AutoReviewPrompt.reportRelativePath))
        #expect(prompt.contains("gh pr diff 42"))
        #expect(!prompt.contains("{{"))
        #expect(AutoReviewPrompt.render(template: "  \n", pr: pr) == prompt, "a blank template is the default")
        #expect(AutoReviewPrompt.render(template: "Review #{{number}} into {{report}}", pr: pr)
                == "Review #42 into .loom-review/auto-review.json")
    }

    @Test("a report as asked: verdict, summary, comments with ranges and sides")
    func parseReport() throws {
        let report = try #require(AutoReviewReport.parse("""
        {"verdict": "request_changes", "summary": "Fixes the cache.\\n\\nBlocking: the TTL.",
         "comments": [
           {"path": "src/cache.ts", "line": 12, "start_line": 10, "side": "RIGHT", "body": "TTL ignored."},
           {"path": "./src/old.ts", "line": 3, "side": "left", "body": "Still used.\\n\\n```suggestion\\nkeep()\\n```"},
           {"path": "src/x.ts", "body": "no line"},
           {"path": "src/y.ts", "line": 4, "body": "  "}
         ]}
        """))
        #expect(report.verdict == .requestChanges)
        #expect(report.summary == "Fixes the cache.\n\nBlocking: the TTL.")
        #expect(report.comments.count == 2, "a comment without a line or a body is dropped")
        #expect(report.comments[0] == AutoReviewReport.Comment(path: "src/cache.ts", firstLine: 10,
                                                               lastLine: 12, side: "RIGHT", body: "TTL ignored."))
        #expect(report.comments[1].path == "src/old.ts", "a leading ./ is dropped")
        #expect(report.comments[1].side == "LEFT")
        #expect(report.comments[1].firstLine == 3)
        #expect(report.comments[1].body.contains("```suggestion"))
    }

    @Test("fenced, with prose around, or with odd spellings, the report still reads")
    func lenient() throws {
        let fenced = try #require(AutoReviewReport.parse("""
        ```json
        {"verdict": "Approve", "summary": "LGTM", "comments": []}
        ```
        """))
        #expect(fenced.verdict == .approve)
        let prose = try #require(AutoReviewReport.parse("""
        Here is the review: {"verdict": "request-changes", "summary": "No.", "comments": [{"path": "a", "line": "7", "startLine": 5, "body": "b"}]} — done.
        """))
        #expect(prose.verdict == .requestChanges)
        #expect(prose.comments.first?.firstLine == 5)
        #expect(prose.comments.first?.lastLine == 7)
        let unknown = try #require(AutoReviewReport.parse(#"{"verdict": "ship it", "summary": "ok"}"#))
        #expect(unknown.verdict == .comment, "the human decides anyway")
    }

    @Test("a comment's own suggestion fence is not mistaken for a wrapping one")
    func suggestionFenceInBody() throws {
        let report = try #require(AutoReviewReport.parse(#"""
        {"verdict": "comment", "summary": "s", "comments": [{"path": "a.swift", "line": 1, "body": "```suggestion\nlet x = 1\n```"}]}
        """#))
        #expect(report.comments.count == 1)
        #expect(report.comments[0].body == "```suggestion\nlet x = 1\n```")
    }

    @Test("nothing to import is no report")
    func empty() {
        #expect(AutoReviewReport.parse("") == nil)
        #expect(AutoReviewReport.parse("I could not finish the review.") == nil)
        #expect(AutoReviewReport.parse(#"{"verdict": "approve", "summary": "", "comments": []}"#) == nil)
    }

    @Test("findings no diff line can carry are folded into the summary")
    func foldedFindings() {
        let outside = [AutoReviewReport.Comment(path: "README.md", firstLine: 3, lastLine: 3, body: "Typo."),
                       AutoReviewReport.Comment(path: "src/a.ts", firstLine: 8, lastLine: 9, body: "Leak.")]
        #expect(AutoReviewReport.summary("Looks right.", unanchored: [])  == "Looks right.")
        #expect(AutoReviewReport.summary("Looks right.", unanchored: outside) == """
        Looks right.

        Other findings:
        - `README.md:3` — Typo.
        - `src/a.ts:8-9` — Leak.
        """)
        #expect(AutoReviewReport.summary("", unanchored: [outside[0]]) == "Other findings:\n- `README.md:3` — Typo.")
    }
}
