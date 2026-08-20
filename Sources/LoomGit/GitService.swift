import LoomCore
import Foundation

/// Git operations by shelling out to the user's binary (ADR-0003):
/// maximum compatibility with their real config (credential helpers, hooks, SSH).
/// All commands are loggable; none is interactive
/// (`GIT_TERMINAL_PROMPT=0`).
public struct GitService: Sendable {

    /// PATH resolution from the login shell: coming with the EnvironmentResolver;
    /// /usr/bin/git is the system shim present on every macOS with the CLT.
    public var gitPath: String
    /// Prefix for session branches (GIT-02), per-project configurable eventually.
    public var branchPrefix: String

    public init(gitPath: String = "/usr/bin/git", branchPrefix: String = "loom") {
        self.gitPath = gitPath
        self.branchPrefix = branchPrefix
    }

    /// GIT-01: creates `<root>/<slug>` on a `<prefix>/<slug>` branch, resolving
    /// branch AND directory collisions with a suffix (GIT-02) — never fails
    /// on collision.
    public func createWorktree(repo: URL, root: URL, slug: String,
                               baseBranch: String? = nil) async throws -> Worktree {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = try await run(["branch", "--list", "--format=%(refname:short)"], in: repo)
        let taken = Set(existing.split(separator: "\n").map(String.init))

        var candidate = "\(branchPrefix)/\(slug)"
        var directory = root.appendingPathComponent(slug)
        var attempt = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: directory.path) {
            candidate = "\(branchPrefix)/\(slug)-\(attempt)"
            directory = root.appendingPathComponent("\(slug)-\(attempt)")
            attempt += 1
        }

        var arguments = ["worktree", "add", directory.path, "-b", candidate]
        if let baseBranch { arguments.append(baseBranch) }
        _ = try await run(arguments, in: repo)
        return Worktree(path: directory, branch: candidate)
    }

    /// GIT-03: changed files via `status --porcelain=v2`, minimal parsing
    /// (changed entries "1", renamed "2", untracked "?").
    public func status(in worktree: URL) async throws -> [FileChange] {
        let output = try await run(["status", "--porcelain=v2", "--untracked-files=all"], in: worktree)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            switch parts.first {
            case "1", "2":
                guard parts.count > 8, let xy = parts.dropFirst().first else { return nil }
                let path = parts[8...].joined(separator: " ")
                let kind: FileChange.Kind = switch xy {
                case let s where s.contains("A"): .added
                case let s where s.contains("D"): .deleted
                case let s where s.contains("R"): .renamed
                default: .modified
                }
                return FileChange(path: String(path), kind: kind)
            case "?":
                guard parts.count >= 2 else { return nil }
                return FileChange(path: parts[1...].joined(separator: " "), kind: .untracked)
            default:
                return nil
            }
        }
    }

    /// PRJ-01: the repo's current branch at the time the project was added.
    public func currentBranch(in repo: URL) async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
    }

    /// GIT-03: read-only unified diff — untracked files are included
    /// too (via `--no-index` against /dev/null, never touching the index).
    public func diff(in worktree: URL) async throws -> String {
        var output = try await run(["diff", "HEAD"], in: worktree)
        let untracked = try await status(in: worktree).filter { $0.kind == .untracked }
        for change in untracked {
            // `--no-index` exits with 1 when there are differences: that is the nominal case.
            if let piece = try? await run(["diff", "--no-index", "--", "/dev/null", change.path],
                                          in: worktree, successCodes: [0, 1]), !piece.isEmpty {
                output += (output.isEmpty ? "" : "\n") + piece
            }
        }
        return output
    }

    /// GIT-05: removal is refused if the worktree carries uncommitted
    /// changes; `force: true` is the ONLY destructive path, always explicit.
    public func removeWorktree(_ worktree: Worktree, repo: URL, force: Bool = false) async throws {
        if !force {
            let changes = try await status(in: worktree.path)
            guard changes.isEmpty else {
                throw GitError.worktreeHasUncommittedChanges(worktree.path, changes.count)
            }
        }
        var arguments = ["worktree", "remove", worktree.path.path]
        if force { arguments.append("--force") }
        _ = try await run(arguments, in: repo)
    }

    // MARK: - Ship (v2): commit and publish straight from a session worktree

    /// Stages EVERYTHING and commits. Throws when there is nothing to commit —
    /// the UI must report the truth, not a phantom commit.
    public func commitAll(in worktree: URL, message: String) async throws {
        _ = try await run(["add", "-A"], in: worktree)
        _ = try await run(["commit", "-m", message], in: worktree)
    }

    /// Publishes the current branch to origin (`-u` so the next pushes are bare).
    /// GIT_TERMINAL_PROMPT=0 (see run): a missing credential fails fast instead
    /// of hanging on an invisible prompt.
    public func push(in worktree: URL) async throws {
        let branch = try await currentBranch(in: worktree)
        _ = try await run(["push", "-u", "origin", branch], in: worktree)
    }

    /// Commits ahead of origin/<branch> — what "Ship" is about to publish.
    /// `nil` when the branch has no upstream yet (never pushed).
    public func aheadCount(in worktree: URL) async throws -> Int? {
        let branch = try await currentBranch(in: worktree)
        guard let output = try? await run(["rev-list", "--count", "origin/\(branch)..HEAD"],
                                          in: worktree) else { return nil }
        return Int(output)
    }

    // MARK: - Execution

    @discardableResult
    private func run(_ arguments: [String], in directory: URL,
                     successCodes: Set<Int32> = [0]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, out, err in
                    let output = String(decoding: out, as: UTF8.self)
                    let errors = String(decoding: err, as: UTF8.self)
                    if successCodes.contains(status) {
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        continuation.resume(throwing: GitError.commandFailed(
                            arguments: arguments, code: status,
                            stderr: errors.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            } catch {
                continuation.resume(throwing: GitError.gitNotRunnable(gitPath, String(describing: error)))
            }
        }
    }
}

public struct Worktree: Sendable, Equatable {
    public let path: URL
    public let branch: String
    public init(path: URL, branch: String) {
        self.path = path
        self.branch = branch
    }
}

public struct FileChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case modified, added, deleted, renamed, untracked
    }
    public let path: String
    public let kind: Kind
    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

public enum GitError: Error, Sendable {
    case commandFailed(arguments: [String], code: Int32, stderr: String)
    case gitNotRunnable(String, String)
    case worktreeHasUncommittedChanges(URL, Int)
}
