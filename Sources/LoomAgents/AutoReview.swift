import Foundation
import LoomCore

/// The review a scheduled run asks for, once `/setup-pr-review` has loaded
/// the PR: the whole review, written as a report Loom imports — a summary
/// for the verdict bar, line comments for the pending review, a suggested
/// verdict — so the human only reads, edits and submits. English, like every
/// prompt claude reads; the text is the user's to edit in Settings.
public enum AutoReviewPrompt {

    /// Where claude writes the report, relative to the review worktree: in
    /// Loom's own folder there, which git never sees (`GitHubService.loomDirectory`).
    public static let reportRelativePath = ".loom-review/auto-review.json"

    /// Placeholders the template may use, filled at every run.
    public static let placeholders = ["{{number}}", "{{title}}", "{{url}}", "{{base}}", "{{head}}",
                                      "{{report}}"]

    public static let defaultTemplate = """
    Now review pull request #{{number}} — "{{title}}" ({{url}}) — in full, from the brief you just built and the checkout of its head (no brief yet: load the PR first, `gh pr view {{number}}` and `gh pr diff {{number}}`).

    Read every touched file's diff and the code around it; run the build and the tests when the project makes that cheap. Look for correctness bugs, regressions, unhandled errors, security issues, concurrency and data-migration hazards, breaking API changes and missing tests. Leave out style points a linter or formatter would catch. Verify each finding against the code before keeping it.

    Do not post anything to GitHub (no `gh pr review`, no `gh pr comment`, no `gh api` write) and do not commit or push: a human reads your review and submits it.

    As your last step, write the review to `{{report}}` (relative to the working directory; the folder exists) as JSON, and nothing else in that file:

    {"verdict": "approve" | "request_changes" | "comment", "summary": "…", "comments": [{"path": "src/file.ts", "line": 42, "start_line": 40, "side": "RIGHT", "body": "…"}]}

    - verdict: "request_changes" when at least one finding must be fixed before merging, "approve" when nothing blocks, "comment" otherwise.
    - summary: the review body, GitHub markdown — two to six lines on what the PR does and whether it does it right, then the blocking points, if any.
    - comments: one per finding tied to code. path from the repository root; line in the new file with side "RIGHT", or in the old file with side "LEFT" for a deleted line; start_line only for a range. Only lines shown by `gh pr diff {{number}}` can carry a comment — put any other finding in the summary. body: the problem, why it matters, the fix; a ```suggestion block when the fix replaces exactly those lines.

    Then end your turn with a three-line recap.
    """

    /// The template (the user's, or the default) with the PR filled in.
    public static func render(template: String?, pr: PRReviewCommand.Context) -> String {
        let source = template?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? template! : defaultTemplate
        return source
            .replacingOccurrences(of: "{{number}}", with: "\(pr.number)")
            .replacingOccurrences(of: "{{title}}", with: pr.title.replacingOccurrences(of: "\"", with: "'"))
            .replacingOccurrences(of: "{{url}}", with: pr.url)
            .replacingOccurrences(of: "{{base}}", with: pr.base)
            .replacingOccurrences(of: "{{head}}", with: pr.head)
            .replacingOccurrences(of: "{{report}}", with: reportRelativePath)
    }
}

/// What a scheduled review leaves behind: the report claude wrote.
public struct AutoReviewReport: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable {
        case approve
        case requestChanges = "request_changes"
        case comment

        /// What the verdict bar says it suggests.
        public var label: String {
            switch self {
            case .approve: "Approve"
            case .requestChanges: "Request changes"
            case .comment: "Comment"
            }
        }
    }

    public struct Comment: Equatable, Sendable {
        public let path: String
        public let firstLine: Int
        public let lastLine: Int
        /// RIGHT (new code) or LEFT (deleted lines).
        public let side: String
        public let body: String

        public init(path: String, firstLine: Int, lastLine: Int, side: String = "RIGHT", body: String) {
            self.path = path
            self.firstLine = min(firstLine, lastLine)
            self.lastLine = max(firstLine, lastLine)
            self.side = side
            self.body = body
        }
    }

    public let verdict: Verdict
    public let summary: String
    public let comments: [Comment]

    public init(verdict: Verdict, summary: String, comments: [Comment]) {
        self.verdict = verdict
        self.summary = summary
        self.comments = comments
    }

    /// Reads the report as claude wrote it: bare JSON, fenced, or with prose
    /// around the object. An unknown verdict reads as "comment" — the human
    /// decides anyway; a comment missing its path, line or body is dropped.
    /// nil when there is no object, or neither a summary nor a comment.
    public static func parse(_ text: String) -> AutoReviewReport? {
        guard let object = LenientJSON.object(in: text) else { return nil }
        let rawVerdict = (object["verdict"] as? String ?? "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let verdict = Verdict(rawValue: rawVerdict) ?? .comment
        let summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let comments = (object["comments"] as? [[String: Any]] ?? []).compactMap { row -> Comment? in
            guard let path = (row["path"] as? String)?.trimmingCharacters(in: .whitespaces), !path.isEmpty,
                  let line = integer(row["line"]),
                  let body = (row["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return nil }
            let start = integer(row["start_line"]) ?? integer(row["startLine"]) ?? line
            let side = (row["side"] as? String)?.uppercased() == "LEFT" ? "LEFT" : "RIGHT"
            return Comment(path: path.hasPrefix("./") ? String(path.dropFirst(2)) : path,
                           firstLine: start, lastLine: line, side: side, body: body)
        }
        guard !summary.isEmpty || !comments.isEmpty else { return nil }
        return AutoReviewReport(verdict: verdict, summary: summary, comments: comments)
    }

    /// JSON numbers arrive as Int or Double; a quoted number is taken too.
    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// The summary with the findings GitHub could not hang on a diff line
    /// appended — nothing claude found is lost because of where it pointed.
    public static func summary(_ summary: String, unanchored: [Comment]) -> String {
        guard !unanchored.isEmpty else { return summary }
        let findings = unanchored.map { comment -> String in
            let lines = comment.firstLine == comment.lastLine
                ? "\(comment.firstLine)" : "\(comment.firstLine)-\(comment.lastLine)"
            return "- `\(comment.path):\(lines)` — " + comment.body
        }
        let head = summary.isEmpty ? "" : summary + "\n\n"
        return head + "Other findings:\n" + findings.joined(separator: "\n")
    }
}
