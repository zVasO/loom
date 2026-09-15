import Foundation

/// v4 — PR review: everything goes through the user's authenticated `gh` CLI.
/// JSON parsing is pure (the tested seam); process execution mirrors GitService.
public struct GitHubService: Sendable {

    /// GUI apps do not inherit the shell PATH: well-known locations only.
    public static let ghPath: URL? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    public static var isAvailable: Bool { ghPath != nil }

    public init() {}

    // MARK: - Value types

    public struct PullRequest: Sendable, Equatable, Identifiable, Codable {
        public var id: Int { number }
        public let number: Int
        public let title: String
        public let author: String
        public let branch: String
        /// The branch the PR wants to merge INTO (baseRefName).
        public let baseBranch: String
        public let reviewDecision: String
        public let checksPassing: Bool
        public let isDraft: Bool
        public let updatedAt: String
        public let url: String
        /// Requested reviewers: a login, or `team/<slug>` for a team request.
        public let reviewers: [String]
        public let assignees: [String]
        public let labels: [Label]
        /// One entry per reviewer, their LAST review — who approved, who asked
        /// for changes, who only commented.
        public let latestReviews: [ReviewSummary]
        public let additions: Int
        public let deletions: Int
        public let changedFiles: Int
        /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub still computing).
        public let mergeable: String
        /// The head commit (headRefOid) — what a line comment or a file-viewed
        /// mark must be anchored to.
        public let headSHA: String

        public init(number: Int, title: String, author: String, branch: String,
                    baseBranch: String, reviewDecision: String, checksPassing: Bool,
                    isDraft: Bool, updatedAt: String, url: String,
                    reviewers: [String] = [], assignees: [String] = [], labels: [Label] = [],
                    latestReviews: [ReviewSummary] = [], additions: Int = 0, deletions: Int = 0,
                    changedFiles: Int = 0, mergeable: String = "", headSHA: String = "") {
            self.number = number
            self.title = title
            self.author = author
            self.branch = branch
            self.baseBranch = baseBranch
            self.reviewDecision = reviewDecision
            self.checksPassing = checksPassing
            self.isDraft = isDraft
            self.updatedAt = updatedAt
            self.url = url
            self.reviewers = reviewers
            self.assignees = assignees
            self.labels = labels
            self.latestReviews = latestReviews
            self.additions = additions
            self.deletions = deletions
            self.changedFiles = changedFiles
            self.mergeable = mergeable
            self.headSHA = headSHA
        }

        /// Cached lists predate the enrichment: missing keys are defaults, not
        /// a decoding failure that would drop the whole cache.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            number = try container.decode(Int.self, forKey: .number)
            title = try container.decode(String.self, forKey: .title)
            author = try container.decode(String.self, forKey: .author)
            branch = try container.decode(String.self, forKey: .branch)
            baseBranch = try container.decode(String.self, forKey: .baseBranch)
            reviewDecision = try container.decode(String.self, forKey: .reviewDecision)
            checksPassing = try container.decode(Bool.self, forKey: .checksPassing)
            isDraft = try container.decode(Bool.self, forKey: .isDraft)
            updatedAt = try container.decode(String.self, forKey: .updatedAt)
            url = try container.decode(String.self, forKey: .url)
            reviewers = try container.decodeIfPresent([String].self, forKey: .reviewers) ?? []
            assignees = try container.decodeIfPresent([String].self, forKey: .assignees) ?? []
            labels = try container.decodeIfPresent([Label].self, forKey: .labels) ?? []
            latestReviews = try container.decodeIfPresent([ReviewSummary].self,
                                                          forKey: .latestReviews) ?? []
            additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
            deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
            changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
            mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable) ?? ""
            headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA) ?? ""
        }

        public var isConflicting: Bool { mergeable == "CONFLICTING" }
    }

    public struct Label: Sendable, Equatable, Codable, Hashable {
        public let name: String
        /// Six hex digits, no `#` — the way GitHub stores it.
        public let colorHex: String
        public init(name: String, colorHex: String) {
            self.name = name
            self.colorHex = colorHex
        }
    }

    public struct ReviewSummary: Sendable, Equatable, Codable, Hashable {
        public let author: String
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, PENDING, DISMISSED.
        public let state: String
        public init(author: String, state: String) {
            self.author = author
            self.state = state
        }
    }

    /// GitHub's own "Viewed" checkbox on a PR file. DISMISSED is what GitHub
    /// sets when the file changed after you viewed it — the head-moved reset
    /// comes for free, force-pushes included.
    public enum FileViewedState: String, Sendable, Codable, Equatable {
        case viewed = "VIEWED"
        case unviewed = "UNVIEWED"
        case dismissed = "DISMISSED"
    }

    public struct FileView: Sendable, Equatable {
        public let path: String
        public let state: FileViewedState
        public init(path: String, state: FileViewedState) {
            self.path = path
            self.state = state
        }
    }

    /// One page of the PR's files with their viewed state.
    public struct FileViewsPage: Sendable, Equatable {
        /// The PR's GraphQL node id — what the mark/unmark mutations take.
        public let prNodeID: String
        public let headSHA: String
        public let files: [FileView]
        public let nextCursor: String?
        public init(prNodeID: String, headSHA: String, files: [FileView], nextCursor: String?) {
            self.prNodeID = prNodeID
            self.headSHA = headSHA
            self.files = files
            self.nextCursor = nextCursor
        }
    }

    public struct FileViews: Sendable, Equatable {
        public let prNodeID: String
        public let headSHA: String
        public let files: [FileView]
        public init(prNodeID: String, headSHA: String, files: [FileView]) {
            self.prNodeID = prNodeID
            self.headSHA = headSHA
            self.files = files
        }

        /// The same list with one file's state replaced.
        public func setting(_ path: String, to state: FileViewedState) -> FileViews {
            var files = self.files
            if let index = files.firstIndex(where: { $0.path == path }) {
                files[index] = FileView(path: path, state: state)
            } else {
                files.append(FileView(path: path, state: state))
            }
            return FileViews(prNodeID: prNodeID, headSHA: headSHA, files: files)
        }
    }

    public struct Comment: Sendable, Equatable {
        public let author: String
        public let body: String
        public let createdAt: String
    }

    public struct Review: Sendable, Equatable {
        public let author: String
        public let state: String
        public let body: String
    }

    public struct PRDetail: Sendable, Equatable {
        public let body: String
        public let comments: [Comment]
        public let reviews: [Review]
    }

    /// A review comment anchored to code — shown inside the diff, under the
    /// line it talks about.
    public struct ReviewComment: Sendable, Equatable, Identifiable {
        public let id: Int
        public let path: String
        /// The line it sits on in the CURRENT diff (or the original line when
        /// the code moved and GitHub marked it outdated).
        public let line: Int
        /// Multi-line comments span startLine…line; nil when single-line.
        public let startLine: Int?
        public let side: String
        public let author: String
        public let body: String
        public let createdAt: String
        /// Set on replies: they belong to their parent's thread.
        public let replyToID: Int?
        /// The lines it referred to no longer exist in the diff.
        public let isOutdated: Bool
        /// A comment on the file itself (subject_type file): no line anchor,
        /// shown under the file header.
        public let isFileLevel: Bool
    }

    public enum Verdict: String, Sendable {
        case approve = "--approve"
        case requestChanges = "--request-changes"
        case comment = "--comment"
    }

    // MARK: - Pure parsing (the tested seam)

    /// The `--json` fields of a list row. One place: the parser reads exactly these.
    public static let listFields = [
        "number", "title", "author", "headRefName", "baseRefName", "headRefOid",
        "reviewDecision", "statusCheckRollup", "updatedAt", "url", "isDraft",
        "reviewRequests", "assignees", "labels", "latestReviews",
        "additions", "deletions", "changedFiles", "mergeable",
    ].joined(separator: ",")

    public static func parsePRList(_ data: Data) throws -> [PullRequest] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int,
                  let title = row["title"] as? String else { return nil }
            let checks = row["statusCheckRollup"] as? [[String: Any]] ?? []
            let failing = checks.contains { ($0["state"] as? String) == "FAILURE" }
            // A review request is a user ({login}) or a team ({slug}, {name}).
            let reviewers = (row["reviewRequests"] as? [[String: Any]] ?? []).compactMap { request -> String? in
                if let login = request["login"] as? String { return login }
                if let slug = request["slug"] as? String { return "team/" + slug }
                if let name = request["name"] as? String { return "team/" + name }
                return nil
            }
            let assignees = (row["assignees"] as? [[String: Any]] ?? [])
                .compactMap { $0["login"] as? String }
            let labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { label -> Label? in
                guard let name = label["name"] as? String else { return nil }
                return Label(name: name, colorHex: label["color"] as? String ?? "")
            }
            let latestReviews = (row["latestReviews"] as? [[String: Any]] ?? []).compactMap { review -> ReviewSummary? in
                guard let author = (review["author"] as? [String: Any])?["login"] as? String
                else { return nil }
                return ReviewSummary(author: author, state: review["state"] as? String ?? "")
            }
            return PullRequest(
                number: number,
                title: title,
                author: (row["author"] as? [String: Any])?["login"] as? String ?? "—",
                branch: row["headRefName"] as? String ?? "",
                baseBranch: row["baseRefName"] as? String ?? "",
                reviewDecision: row["reviewDecision"] as? String ?? "",
                checksPassing: !failing,
                isDraft: row["isDraft"] as? Bool ?? false,
                updatedAt: row["updatedAt"] as? String ?? "",
                url: row["url"] as? String ?? "",
                reviewers: reviewers,
                assignees: assignees,
                labels: labels,
                latestReviews: latestReviews,
                additions: row["additions"] as? Int ?? 0,
                deletions: row["deletions"] as? Int ?? 0,
                changedFiles: row["changedFiles"] as? Int ?? 0,
                mergeable: row["mergeable"] as? String ?? "",
                headSHA: row["headRefOid"] as? String ?? "")
        }
    }

    public static func parsePRDetail(_ data: Data) throws -> PRDetail {
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let comments = (object["comments"] as? [[String: Any]] ?? []).map { row in
            Comment(author: (row["author"] as? [String: Any])?["login"] as? String ?? "—",
                    body: row["body"] as? String ?? "",
                    createdAt: row["createdAt"] as? String ?? "")
        }
        let reviews = (object["reviews"] as? [[String: Any]] ?? []).map { row in
            Review(author: (row["author"] as? [String: Any])?["login"] as? String ?? "—",
                   state: row["state"] as? String ?? "",
                   body: row["body"] as? String ?? "")
        }
        return PRDetail(body: object["body"] as? String ?? "",
                        comments: comments, reviews: reviews)
    }

    public static func parseReviewComments(_ data: Data) throws -> [ReviewComment] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let path = row["path"] as? String else { return nil }
            // Three shapes: line comments carry `line`; outdated ones only
            // `original_line`; file-level ones (subject_type file) neither —
            // each is kept, the view anchors them differently.
            let isFileLevel = row["subject_type"] as? String == "file"
            let live = row["line"] as? Int
            let anchor = live ?? (row["original_line"] as? Int)
            guard let line = anchor ?? (isFileLevel ? 0 : nil) else { return nil }
            return ReviewComment(
                id: id,
                path: path,
                line: line,
                startLine: row["start_line"] as? Int ?? row["original_start_line"] as? Int,
                side: row["side"] as? String ?? "RIGHT",
                author: (row["user"] as? [String: Any])?["login"] as? String ?? "—",
                body: row["body"] as? String ?? "",
                createdAt: row["created_at"] as? String ?? "",
                replyToID: row["in_reply_to_id"] as? Int,
                isOutdated: !isFileLevel && live == nil,
                isFileLevel: isFileLevel)
        }
    }

    // MARK: File viewed state (GraphQL)

    /// One page of `files { path viewerViewedState }` — the only way GitHub
    /// exposes its "Viewed" checkbox. `{owner}`/`{repo}` are gh placeholders,
    /// filled from the current repository like in REST endpoints.
    public static func fileViewsArguments(number: Int, cursor: String?) -> [String] {
        var arguments = ["api", "graphql",
                         "-f", "owner={owner}", "-f", "name={repo}", "-F", "number=\(number)"]
        if let cursor { arguments += ["-f", "cursor=\(cursor)"] }
        arguments += ["-f", "query=" + fileViewsQuery]
        return arguments
    }

    static let fileViewsQuery = """
    query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id headRefOid
          files(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes { path viewerViewedState }
          }
        }
      }
    }
    """

    /// `markFileAsViewed` / `unmarkFileAsViewed` on the PR node.
    public static func fileViewedArguments(prNodeID: String, path: String, viewed: Bool) -> [String] {
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        return ["api", "graphql", "-f", "id=\(prNodeID)", "-f", "path=\(path)",
                "-f", "query=mutation($id: ID!, $path: String!) { \(mutation)(input: {pullRequestId: $id, path: $path}) { clientMutationId } }"]
    }

    public static func parseFileViewsPage(_ data: Data) throws -> FileViewsPage {
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let pr = ((object["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"]
            as? [String: Any] ?? [:]
        let files = pr["files"] as? [String: Any] ?? [:]
        let nodes = (files["nodes"] as? [[String: Any]] ?? []).compactMap { node -> FileView? in
            guard let path = node["path"] as? String else { return nil }
            let state = FileViewedState(rawValue: node["viewerViewedState"] as? String ?? "") ?? .unviewed
            return FileView(path: path, state: state)
        }
        let pageInfo = files["pageInfo"] as? [String: Any] ?? [:]
        let hasNext = pageInfo["hasNextPage"] as? Bool ?? false
        return FileViewsPage(prNodeID: pr["id"] as? String ?? "",
                             headSHA: pr["headRefOid"] as? String ?? "",
                             files: nodes,
                             nextCursor: hasNext ? pageInfo["endCursor"] as? String : nil)
    }

    /// A review comment's body. GitHub turns a ```suggestion fence into a
    /// one-click "Apply suggestion" — the note, when present, sits above it.
    public static func lineCommentBody(_ note: String, suggestion: String?) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suggestion else { return trimmedNote }
        let fence = "```suggestion\n"
            + suggestion.trimmingCharacters(in: .newlines) + "\n```"
        return trimmedNote.isEmpty ? fence : trimmedNote + "\n\n" + fence
    }

    /// The `pulls/{n}/comments` payload. A single-line comment must NOT carry
    /// start_line (GitHub rejects a one-line span).
    public static func lineCommentPayload(path: String, firstLine: Int, lastLine: Int,
                                          sha: String, body: String,
                                          side: String = "RIGHT") -> [String: Any] {
        var payload: [String: Any] = ["path": path, "line": lastLine, "side": side,
                                      "commit_id": sha, "body": body]
        if firstLine < lastLine {
            payload["start_line"] = firstLine
            payload["start_side"] = side
        }
        return payload
    }

    // MARK: - gh execution

    /// The PRs of the repo a project folder belongs to, narrowed by a filter
    /// (GitHub search syntax through `--search`; gh adds `repo:` and `is:pr`
    /// itself). `gh search prs` was the alternative and lost: it returns
    /// neither the branch, nor the review decision, nor the checks.
    public func listPRs(in repo: URL, filter: PRFilter = .all,
                        limit: Int = PRFilter.defaultLimit) async throws -> [PullRequest] {
        let data = try await run(["pr", "list"] + filter.ghArguments(limit: limit)
                                 + ["--json", Self.listFields], in: repo)
        return try Self.parsePRList(data)
    }

    public func prDetail(_ number: Int, in repo: URL) async throws -> PRDetail {
        let data = try await run(["pr", "view", "\(number)", "--json", "body,number,comments,reviews"],
                                 in: repo)
        return try Self.parsePRDetail(data)
    }

    public func prDiff(_ number: Int, in repo: URL) async throws -> String {
        let data = try await run(["pr", "diff", "\(number)"], in: repo)
        return String(decoding: data, as: UTF8.self)
    }

    /// The PR's diff rebuilt locally from fetched refs — the API refuses
    /// oversized diffs (HTTP 406), git itself has no such limit. Three-dot
    /// (merge-base) semantics, same as GitHub's own view.
    public func localDiff(_ number: Int, baseBranch: String, in repo: URL) async throws -> String {
        _ = try await runGit(["fetch", "origin", "pull/\(number)/head"], in: repo)
        let head = try await revParse("FETCH_HEAD", in: repo)
        _ = try await runGit(["fetch", "origin", baseBranch], in: repo)
        let base = try await revParse("FETCH_HEAD", in: repo)
        let data = try await runGit(["diff", "\(base)...\(head)"], in: repo)
        return String(decoding: data, as: UTF8.self)
    }

    public func submitReview(_ number: Int, verdict: Verdict, body: String, in repo: URL) async throws {
        var arguments = ["pr", "review", "\(number)", verdict.rawValue]
        if !body.isEmpty { arguments += ["--body", body] }
        _ = try await run(arguments, in: repo)
    }

    public func comment(_ number: Int, body: String, in repo: URL) async throws {
        _ = try await run(["pr", "comment", "\(number)", "--body", body], in: repo)
    }

    /// Every review comment on the PR (the ones anchored to code).
    public func reviewComments(_ number: Int, in repo: URL) async throws -> [ReviewComment] {
        let data = try await run(["api", "--paginate",
                                  "repos/{owner}/{repo}/pulls/\(number)/comments"], in: repo)
        return try Self.parseReviewComments(data)
    }

    /// Every file of the PR with GitHub's own viewed state, all pages. Bounded:
    /// a PR is never more than a few hundred files, and a page is 100.
    public func fileViews(_ number: Int, in repo: URL) async throws -> FileViews {
        var cursor: String?
        var files: [FileView] = []
        var prNodeID = "", headSHA = ""
        for _ in 0..<50 {
            let data = try await run(Self.fileViewsArguments(number: number, cursor: cursor), in: repo)
            let page = try Self.parseFileViewsPage(data)
            prNodeID = page.prNodeID
            headSHA = page.headSHA
            files += page.files
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return FileViews(prNodeID: prNodeID, headSHA: headSHA, files: files)
    }

    /// GitHub's "Viewed" checkbox, checked or unchecked — shared with the web.
    public func setFileViewed(prNodeID: String, path: String, viewed: Bool,
                              in repo: URL) async throws {
        _ = try await run(Self.fileViewedArguments(prNodeID: prNodeID, path: path, viewed: viewed),
                          in: repo)
    }

    /// Replies inside an existing thread (GitHub's own "reply" on a comment).
    public func replyToComment(_ number: Int, commentID: Int, body: String,
                               in repo: URL) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["body": body])
        _ = try await run(["api", "--method", "POST",
                           "repos/{owner}/{repo}/pulls/\(number)/comments/\(commentID)/replies",
                           "--input", "-"], in: repo, stdin: json)
    }

    /// The payload for a comment on the FILE itself (GitHub's "comment on
    /// this file"): subject_type file, no line anchor.
    public static func fileCommentPayload(path: String, sha: String,
                                          body: String) -> [String: Any] {
        ["path": path, "commit_id": sha, "body": body, "subject_type": "file"]
    }

    /// Posts a review comment on a whole file — used when a selection spans
    /// several hunks and no single line range can carry it.
    public func commentOnFile(_ number: Int, path: String, note: String,
                              in repo: URL) async throws {
        let head = try await run(["pr", "view", "\(number)", "--json", "headRefOid",
                                  "--jq", ".headRefOid"], in: repo)
        let sha = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.data(
            withJSONObject: Self.fileCommentPayload(path: path, sha: sha, body: note))
        _ = try await run(["api", "--method", "POST",
                           "repos/{owner}/{repo}/pulls/\(number)/comments",
                           "--input", "-"], in: repo, stdin: json)
    }

    /// Posts a review comment anchored to real diff lines (what GitHub's own
    /// "comment on this line" does) — `suggestion` makes it appliable.
    public func commentOnLines(_ number: Int, path: String, firstLine: Int, lastLine: Int,
                               note: String, suggestion: String?, side: String = "RIGHT",
                               in repo: URL) async throws {
        let head = try await run(["pr", "view", "\(number)", "--json", "headRefOid",
                                  "--jq", ".headRefOid"], in: repo)
        let sha = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = Self.lineCommentPayload(
            path: path, firstLine: firstLine, lastLine: lastLine, sha: sha,
            body: Self.lineCommentBody(note, suggestion: suggestion), side: side)
        let json = try JSONSerialization.data(withJSONObject: payload)
        // --input - : the body travels as JSON on stdin, so newlines and
        // backticks survive intact.
        _ = try await run(["api", "--method", "POST",
                           "repos/{owner}/{repo}/pulls/\(number)/comments",
                           "--input", "-"], in: repo, stdin: json)
    }

    /// Checks the PR branch out into a dedicated worktree (`<repo>-worktrees/pr-N`)
    /// so the guide — or the user's session — can inspect real code, never the
    /// user's own checkout.
    public func checkoutPR(_ number: Int, repo: URL, readOnly: Bool = true) async throws -> URL {
        let root = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-worktrees")
        let path = root.appendingPathComponent("pr-\(number)")
        // Detached fetch of the PR head: never fights over branch names —
        // `gh pr checkout` refuses when the branch is checked out elsewhere
        // (reviewing your OWN pr from the same repo, the common case).
        if !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Fetch FIRST, then materialize the worktree directly on the PR
            // head: one working-tree write instead of checkout-then-rewrite,
            // which doubled the cost on large repos.
            _ = try await runGit(["fetch", "origin", "pull/\(number)/head"], in: repo)
            _ = try await runGit(["worktree", "add", "--detach", path.path, "FETCH_HEAD"], in: repo)
        } else {
            _ = try await runGit(["fetch", "origin", "pull/\(number)/head"], in: path)
            let head = try await revParse("HEAD", in: path)
            // Only rewrite the tree when the PR actually moved.
            if head != (try await revParse("FETCH_HEAD", in: path)) {
                _ = try await runGit(["checkout", "--detach", "FETCH_HEAD"], in: path)
            }
        }
        // Read-only is a user setting: protect or UNprotect — the worktree is
        // reused across checkouts, so a change of mind must apply to it.
        if readOnly {
            try await protectWorktree(path, repo: repo)
        } else {
            try await unprotectWorktree(path)
        }
        return path
    }

    /// Files Loom drops into a review worktree, kept out of `git status` for
    /// THIS worktree only: an excludes file of our own, wired through the
    /// worktree-scoped config (`core.excludesFile`), never the repository's
    /// shared `info/exclude` and never the user's own checkout.
    public static let loomDirectory = ".loom-review"

    /// Installs a slash command in the worktree (`.claude/commands/<name>.md`)
    /// so claude finds it at startup. Rewritten on every install: the text
    /// follows what the user set in Settings.
    public func installCommand(named name: String, markdown: String, in worktree: URL) async throws {
        let commands = worktree.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try markdown.write(to: commands.appendingPathComponent("\(name).md"),
                           atomically: true, encoding: .utf8)
        try await excludeLoomFiles(in: worktree)
    }

    /// The exclude list a review worktree carries — everything Loom writes there.
    static func loomExcludes(commandNames: [String]) -> String {
        (["/\(loomDirectory)/", "/.loom-guard-hooks/"]
         + commandNames.map { "/.claude/commands/\($0).md" })
            .joined(separator: "\n") + "\n"
    }

    private func excludeLoomFiles(in worktree: URL) async throws {
        let directory = worktree.appendingPathComponent(Self.loomDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let commandsDirectory = worktree.appendingPathComponent(".claude/commands")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: commandsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
        let excludes = directory.appendingPathComponent("exclude")
        try Self.loomExcludes(commandNames: names).write(to: excludes, atomically: true, encoding: .utf8)
        // Worktree-scoped config needs the extension on the repository — the
        // guard hooks already rely on it; this is the same switch.
        _ = try await runGit(["config", "extensions.worktreeConfig", "true"], in: worktree)
        _ = try await runGit(["config", "--worktree", "core.excludesFile", excludes.path], in: worktree)
    }

    /// Reverses `protectWorktree` (setting turned off on a reused worktree).
    public func unprotectWorktree(_ path: URL) async throws {
        _ = try? await runGit(["config", "--worktree", "--unset", "core.hooksPath"], in: path)
        try? FileManager.default.removeItem(at: path.appendingPathComponent(".loom-guard-hooks"))
    }

    /// Makes a review worktree commit-proof: guard hooks (pre-commit,
    /// pre-push, pre-rebase) scoped to THIS worktree via core.hooksPath —
    /// a review session can build and test, but never lands work on another
    /// dev's branch by accident. (A determined `--no-verify` still bypasses;
    /// the guard is against accidents, not adversaries.)
    public func protectWorktree(_ path: URL, repo: URL) async throws {
        _ = try await runGit(["config", "extensions.worktreeConfig", "true"], in: repo)
        let hooksDir = path.appendingPathComponent(".loom-guard-hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        echo "This is a READ-ONLY Loom review worktree - commits and pushes are blocked." >&2
        exit 1
        """
        for hook in ["pre-commit", "pre-push", "pre-rebase"] {
            let file = hooksDir.appendingPathComponent(hook)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: file.path)
        }
        _ = try await runGit(["config", "--worktree", "core.hooksPath", hooksDir.path], in: path)
    }

    public enum GitHubError: Error, Sendable {
        case ghNotInstalled
        case commandFailed(arguments: [String], stderr: String)
    }

    private func run(_ arguments: [String], in directory: URL,
                     stdin: Data? = nil) async throws -> Data {
        guard let gh = Self.ghPath else { throw GitHubError.ghNotInstalled }
        return try await execute(gh, arguments: arguments, in: directory, stdin: stdin)
    }

    private func revParse(_ ref: String, in directory: URL) async throws -> String {
        String(decoding: try await runGit(["rev-parse", ref], in: directory), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws -> Data {
        try await execute(URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, in: directory)
    }

    private func execute(_ executable: URL, arguments: [String], in directory: URL,
                         stdin: Data? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, out, err in
                    if status == 0 {
                        continuation.resume(returning: out)
                    } else {
                        continuation.resume(throwing: GitHubError.commandFailed(
                            arguments: arguments,
                            stderr: String(decoding: err, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            } catch {
                continuation.resume(throwing: GitHubError.commandFailed(
                    arguments: arguments, stderr: String(describing: error)))
            }
        }
    }
}
