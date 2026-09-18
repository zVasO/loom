import Testing
import LoomAgents

// The /setup-pr-review command Loom installs in a review worktree: claude's
// slash-command markdown, the PR filled in, the user's text taking over the
// default when they wrote one.
@Suite("PRReviewCommand — the slash command a review starts with")
struct PRReviewCommandTests {

    private let pr = PRReviewCommand.Context(number: 42, title: "Fix the \"cache\" bug",
                                             url: "https://github.com/acme/repo/pull/42",
                                             base: "main", head: "fix/cache")

    @Test("the default is claude slash-command markdown: frontmatter, then the prompt")
    func defaultShape() {
        let markdown = PRReviewCommand.render(template: nil, pr: pr)
        #expect(markdown.hasPrefix("---\ndescription:"))
        #expect(markdown.contains("\n---\n"))
        #expect(markdown.contains("$ARGUMENTS"), "claude's own argument placeholder survives")
        #expect(!markdown.contains("{{"), "every Loom placeholder is filled")
    }

    @Test("the PR is filled in: number, title, url, branches")
    func placeholdersFilled() {
        let markdown = PRReviewCommand.render(template: nil, pr: pr)
        #expect(markdown.contains("pull request #42"))
        #expect(markdown.contains("gh pr diff 42"))
        #expect(markdown.contains("https://github.com/acme/repo/pull/42"))
        #expect(markdown.contains("`fix/cache` into `main`"))
        #expect(markdown.contains("'cache'"), "double quotes in a title cannot break the sentence's quotes")
    }

    @Test("the command reads the PR in depth and stops: gh view, diff, threads, issues, then a brief")
    func readsInDepthThenWaits() {
        let markdown = PRReviewCommand.defaultTemplate
        for expected in ["gh pr view", "gh pr diff", "pulls/{{number}}/comments", "gh issue view",
                         "working memory", "wait for instructions", "never commit or push"] {
            #expect(markdown.contains(expected), "missing: \(expected)")
        }
    }

    @Test("the user's template wins over the default, placeholders included")
    func customTemplate() {
        let markdown = PRReviewCommand.render(template: "Load #{{number}} ({{head}}) then summarize.", pr: pr)
        #expect(markdown == "Load #42 (fix/cache) then summarize.")
        #expect(PRReviewCommand.render(template: "   \n", pr: pr) == PRReviewCommand.render(template: nil, pr: pr),
                "a blank template is no template")
    }

    @Test("the invocation is the slash command with the PR number, at the documented path")
    func invocationAndPath() {
        #expect(PRReviewCommand.invocation(number: 42) == "/setup-pr-review 42")
        #expect(PRReviewCommand.relativePath == ".claude/commands/setup-pr-review.md")
        #expect(PRReviewCommand.placeholders.contains("{{number}}"))
    }
}
