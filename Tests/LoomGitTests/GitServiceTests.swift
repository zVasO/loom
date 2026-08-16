import Testing
import LoomGit
import Foundation

// Seam: GitService's public interface, on REAL git repos in a temporary
// directory — it is the behavior of the user's git binary we contract
// against (ADR-0003), not a mock.

@Suite("GitService — worktrees and status", .serialized)
struct GitServiceTests {

    let service = GitService()

    @Test("a worktree is born on its loom/<slug> branch (GIT-01, GIT-02)")
    func creationDeWorktree() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")

        let worktree = try await service.createWorktree(repo: repo, root: root, slug: "fix-cache")

        #expect(worktree.branch == "loom/fix-cache")
        #expect(FileManager.default.fileExists(atPath: worktree.path.appendingPathComponent("README.md").path),
                "the worktree is a full checkout")
        let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.path)
        #expect(head == "loom/fix-cache", "the worktree's HEAD is on the session branch")
    }

    @Test("branch name collision: the suffix disambiguates (GIT-02)")
    func collisionDeBranche() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")

        let first = try await service.createWorktree(repo: repo, root: root, slug: "same-task")
        let second = try await service.createWorktree(repo: repo, root: root, slug: "same-task")

        #expect(first.branch == "loom/same-task")
        #expect(second.branch == "loom/same-task-2", "never fail on collision: we suffix")
        #expect(first.path != second.path)
    }

    @Test("porcelain v2 status parses: modified and untracked (GIT-03)")
    func statusPorcelain() async throws {
        let repo = try await makeFixtureRepo()
        try "modified content".write(to: repo.appendingPathComponent("README.md"),
                                     atomically: true, encoding: .utf8)
        try "new".write(to: repo.appendingPathComponent("note.txt"),
                        atomically: true, encoding: .utf8)

        let changes = try await service.status(in: repo)

        #expect(changes.contains(FileChange(path: "README.md", kind: .modified)))
        #expect(changes.contains(FileChange(path: "note.txt", kind: .untracked)))
    }

    @Test("the current branch is detected: the project's base (PRJ-01)")
    func brancheCourante() async throws {
        let repo = try await makeFixtureRepo()
        let branch = try await service.currentBranch(in: repo)
        #expect(branch == "main")
    }

    @Test("the unified diff shows the changes, untracked files included (GIT-03)")
    func diffUnifie() async throws {
        let repo = try await makeFixtureRepo()
        try "modified content".write(to: repo.appendingPathComponent("README.md"),
                                     atomically: true, encoding: .utf8)
        try "brand new".write(to: repo.appendingPathComponent("note.txt"),
                              atomically: true, encoding: .utf8)

        let diff = try await service.diff(in: repo)

        #expect(diff.contains("-# Fixture"), "the old line shows up as a deletion")
        #expect(diff.contains("+modified content"), "the new line shows up as an addition")
        #expect(diff.contains("+brand new"), "untracked files are part of the diff (intent-to-add)")
    }

    @Test("safe removal: refuses on uncommitted changes, explicit force (GIT-05)")
    func suppressionSecurisee() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")
        let worktree = try await service.createWorktree(repo: repo, root: root, slug: "to-delete")
        try "work in progress".write(to: worktree.path.appendingPathComponent("wip.txt"),
                                     atomically: true, encoding: .utf8)

        await #expect(throws: GitError.self) {
            try await service.removeWorktree(worktree, repo: repo)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path.path), "nothing was destroyed")

        try await service.removeWorktree(worktree, repo: repo, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path), "explicit force: removed")
    }

    // MARK: - Fixtures

    private func makeFixtureRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-git-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "main"], in: dir)
        try "# Fixture".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: dir)
        _ = try await git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-m", "init"], in: dir)
        return dir
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
