import Foundation

/// The `/setup-pr-review` slash command Loom installs in a review worktree:
/// claude loads the pull request in depth — body, diff, threads, linked
/// issues, surrounding code — and keeps a brief in working memory before the
/// reviewer points it at lines. English, like every prompt claude reads; the
/// text is the user's to edit in Settings, this is only the default.
public enum PRReviewCommand {
    public static let name = "setup-pr-review"

    /// `<worktree>/.claude/commands/setup-pr-review.md`
    public static let relativePath = ".claude/commands/\(name).md"

    /// What the PR tab types once the session has painted.
    public static func invocation(number: Int) -> String { "/\(name) \(number)" }

    /// Placeholders the template may use; Loom fills them at install time.
    /// `$ARGUMENTS` is claude's own and survives untouched.
    public static let placeholders = ["{{number}}", "{{title}}", "{{url}}", "{{base}}", "{{head}}"]

    public struct Context: Sendable, Equatable {
        public var number: Int
        public var title: String
        public var url: String
        public var base: String
        public var head: String
        public init(number: Int, title: String, url: String, base: String, head: String) {
            self.number = number
            self.title = title
            self.url = url
            self.base = base
            self.head = head
        }
    }

    public static let defaultTemplate = """
    ---
    description: Load a pull request in depth before reviewing it
    ---
    You are about to review pull request #{{number}} — "{{title}}" ({{url}}), merging `{{head}}` into `{{base}}`. The working directory is a checkout of the PR head, kept read-only for review: build, run and test freely, never commit or push. If $ARGUMENTS is not empty and names a different PR number, load that one instead.

    Load the pull request in depth, with `gh` (already authenticated) and the checkout:

    1. `gh pr view {{number}} --json title,body,author,baseRefName,headRefName,labels,reviewRequests,assignees,reviews,comments,files,additions,deletions,changedFiles,mergeable,statusCheckRollup` — the intent, the conversation so far, the CI state.
    2. `gh pr diff {{number}}` — the whole diff. On a large PR read it file by file; do not skim.
    3. `gh api repos/{owner}/{repo}/pulls/{{number}}/comments` — the review comments anchored to code, unresolved threads included.
    4. Linked issues named in the body (`Fixes #…`, `Closes #…`, `Refs #…`): `gh issue view <n>` for each.
    5. The surrounding code: for every touched file, open the callers and callees the diff does not show, so the change is judged in context, not in isolation.

    Then build a brief and keep it in your working memory for the rest of this session:
    - Intent: what the PR claims to do, in two lines, and whether the diff actually matches the claim.
    - Map: the touched files grouped by theme, with the one or two files where the real change lives.
    - Risk areas: behaviour changes, error handling, concurrency, data migrations, public API, security-sensitive code, missing or weakened tests.
    - Open questions: what you could not settle from the code alone.

    Report the brief in at most fifteen lines, then stop and wait for instructions. Do not post anything to GitHub, do not modify files, and do not start a full review yet: the reviewer will point you at lines from the diff.
    """

    /// The template (the user's, or the default) with the PR filled in.
    public static func render(template: String?, pr: Context) -> String {
        let source = template?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? template! : defaultTemplate
        return source
            .replacingOccurrences(of: "{{number}}", with: "\(pr.number)")
            .replacingOccurrences(of: "{{title}}", with: pr.title.replacingOccurrences(of: "\"", with: "'"))
            .replacingOccurrences(of: "{{url}}", with: pr.url)
            .replacingOccurrences(of: "{{base}}", with: pr.base)
            .replacingOccurrences(of: "{{head}}", with: pr.head)
    }
}
