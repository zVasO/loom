import LoomCore
import Foundation

/// Opérations Git par shell-out vers le binaire de l'utilisateur (ADR-0003) :
/// compatibilité maximale avec sa config réelle (credentials helpers, hooks, SSH).
/// Toutes les commandes sont journalisables ; aucune n'est interactive
/// (`GIT_TERMINAL_PROMPT=0`).
public struct GitService: Sendable {

    /// Résolution PATH depuis le shell de login : à venir avec l'EnvironmentResolver ;
    /// /usr/bin/git est le shim système présent sur tout macOS avec les CLT.
    public var gitPath: String
    /// Préfixe des branches de session (GIT-02), configurable par projet à terme.
    public var branchPrefix: String

    public init(gitPath: String = "/usr/bin/git", branchPrefix: String = "loom") {
        self.gitPath = gitPath
        self.branchPrefix = branchPrefix
    }

    /// GIT-01 : crée `<root>/<slug>` sur une branche `<prefix>/<slug>`, en résolvant
    /// les collisions de branche ET de dossier par suffixe (GIT-02) — jamais d'échec
    /// sur collision.
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

    /// GIT-03 : fichiers modifiés via `status --porcelain=v2`, parsing minimal
    /// (entrées changées « 1 », renommées « 2 », non suivies « ? »).
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

    /// PRJ-01 : la branche courante du repo au moment de l'ajout du projet.
    public func currentBranch(in repo: URL) async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
    }

    /// GIT-03 : diff unifié en lecture seule — les fichiers non suivis y figurent
    /// aussi (via `--no-index` contre /dev/null, sans jamais toucher l'index).
    public func diff(in worktree: URL) async throws -> String {
        var output = try await run(["diff", "HEAD"], in: worktree)
        let untracked = try await status(in: worktree).filter { $0.kind == .untracked }
        for change in untracked {
            // `--no-index` sort en 1 quand il y a des différences : c'est le cas nominal.
            if let piece = try? await run(["diff", "--no-index", "--", "/dev/null", change.path],
                                          in: worktree, successCodes: [0, 1]), !piece.isEmpty {
                output += (output.isEmpty ? "" : "\n") + piece
            }
        }
        return output
    }

    /// GIT-05 : suppression refusée si le worktree porte des modifications non
    /// commitées ; `force: true` est le SEUL chemin destructif, toujours explicite.
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

    // MARK: - Exécution

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
            process.terminationHandler = { finished in
                let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if successCodes.contains(finished.terminationStatus) {
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: GitError.commandFailed(
                        arguments: arguments, code: finished.terminationStatus,
                        stderr: errors.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
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
