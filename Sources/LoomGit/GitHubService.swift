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

    public struct PullRequest: Sendable, Equatable, Identifiable {
        public var id: Int { number }
        public let number: Int
        public let title: String
        public let author: String
        public let branch: String
        public let reviewDecision: String
        public let checksPassing: Bool
        public let isDraft: Bool
        public let updatedAt: String
        public let url: String
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

    public enum Verdict: String, Sendable {
        case approve = "--approve"
        case requestChanges = "--request-changes"
        case comment = "--comment"
    }

    // MARK: - Pure parsing (the tested seam)

    public static func parsePRList(_ data: Data) throws -> [PullRequest] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int,
                  let title = row["title"] as? String else { return nil }
            let checks = row["statusCheckRollup"] as? [[String: Any]] ?? []
            let failing = checks.contains { ($0["state"] as? String) == "FAILURE" }
            return PullRequest(
                number: number,
                title: title,
                author: (row["author"] as? [String: Any])?["login"] as? String ?? "—",
                branch: row["headRefName"] as? String ?? "",
                reviewDecision: row["reviewDecision"] as? String ?? "",
                checksPassing: !failing,
                isDraft: row["isDraft"] as? Bool ?? false,
                updatedAt: row["updatedAt"] as? String ?? "",
                url: row["url"] as? String ?? "")
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

    // MARK: - gh execution

    public func listPRs(in repo: URL) async throws -> [PullRequest] {
        let data = try await run(["pr", "list", "--json",
                                  "number,title,author,headRefName,reviewDecision,statusCheckRollup,updatedAt,url,isDraft"],
                                 in: repo)
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

    public func submitReview(_ number: Int, verdict: Verdict, body: String, in repo: URL) async throws {
        var arguments = ["pr", "review", "\(number)", verdict.rawValue]
        if !body.isEmpty { arguments += ["--body", body] }
        _ = try await run(arguments, in: repo)
    }

    public func comment(_ number: Int, body: String, in repo: URL) async throws {
        _ = try await run(["pr", "comment", "\(number)", "--body", body], in: repo)
    }

    /// Checks the PR branch out into a dedicated worktree (`<repo>-worktrees/pr-N`)
    /// so the guide — or the user's session — can inspect real code, never the
    /// user's own checkout.
    public func checkoutPR(_ number: Int, repo: URL) async throws -> URL {
        let root = repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-worktrees")
        let path = root.appendingPathComponent("pr-\(number)")
        if !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try await runGit(["worktree", "add", "--detach", path.path], in: repo)
        }
        _ = try await run(["pr", "checkout", "\(number)"], in: path)
        return path
    }

    public enum GitHubError: Error, Sendable {
        case ghNotInstalled
        case commandFailed(arguments: [String], stderr: String)
    }

    private func run(_ arguments: [String], in directory: URL) async throws -> Data {
        guard let gh = Self.ghPath else { throw GitHubError.ghNotInstalled }
        return try await execute(gh, arguments: arguments, in: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws -> Data {
        try await execute(URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, in: directory)
    }

    private func execute(_ executable: URL, arguments: [String], in directory: URL) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: GitHubError.commandFailed(
                        arguments: arguments,
                        stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch {
                continuation.resume(throwing: GitHubError.commandFailed(
                    arguments: arguments, stderr: String(describing: error)))
            }
        }
    }
}
