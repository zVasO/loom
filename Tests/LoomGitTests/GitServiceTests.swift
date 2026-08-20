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

}

fileprivate func makeFixtureRepo() async throws -> URL {
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
fileprivate func git(_ arguments: [String], in dir: URL) async throws -> String {
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

// v2 "Ship": commit and push straight from a session worktree.
@Suite("GitService — ship (v2)", .serialized)
struct GitShipTests {

    let service = GitService()

    @Test("commitAll stages everything and creates the commit")
    func commitAll() async throws {
        let repo = try await makeFixtureRepo()
        try "new work".write(to: repo.appendingPathComponent("feature.txt"),
                             atomically: true, encoding: .utf8)
        try await service.commitAll(in: repo, message: "Ship the feature")
        let subject = try await git(["log", "-1", "--pretty=%s"], in: repo)
        #expect(subject == "Ship the feature")
        let status = try await service.status(in: repo)
        #expect(status.isEmpty, "nothing left uncommitted")
    }

    @Test("commitAll with nothing to commit throws instead of lying")
    func commitAllEmpty() async throws {
        let repo = try await makeFixtureRepo()
        await #expect(throws: (any Error).self) {
            try await service.commitAll(in: repo, message: "empty")
        }
    }

    @Test("push publishes the branch to origin (local bare remote)")
    func pushToBareRemote() async throws {
        let repo = try await makeFixtureRepo()
        let bare = repo.deletingLastPathComponent()
            .appendingPathComponent("remote-\(UUID().uuidString.prefix(6)).git")
        _ = try await git(["init", "--bare", bare.path], in: repo)
        _ = try await git(["remote", "add", "origin", bare.path], in: repo)
        try "pushed work".write(to: repo.appendingPathComponent("pushed.txt"),
                                atomically: true, encoding: .utf8)
        try await service.commitAll(in: repo, message: "To publish")
        try await service.push(in: repo)
        let remoteLog = try await git(["log", "-1", "--pretty=%s", "main"], in: bare)
        #expect(remoteLog == "To publish")
    }
}

// Review worktrees are READ-ONLY: guard hooks block commit and push — a
// review session must never land work on another dev's branch.
@Suite("Read-only review worktrees", .serialized)
struct ReadOnlyWorktreeTests {

    @Test("checkoutPR materializes the PR head in a reusable worktree")
    func checkoutPRWorktree() async throws {
        let repo = try await makeFixtureRepo()
        // A bare origin exposing the PR the way GitHub does: refs/pull/N/head.
        let bare = repo.deletingLastPathComponent()
            .appendingPathComponent("origin-\(UUID().uuidString.prefix(6)).git")
        _ = try await git(["init", "--bare", bare.path], in: repo)
        _ = try await git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await git(["push", "origin", "main"], in: repo)
        try "pr work".write(to: repo.appendingPathComponent("pr.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: repo)
        _ = try await git(["-c", "user.email=t@t", "-c", "user.name=T",
                           "commit", "-m", "pr head"], in: repo)
        let prHead = try await git(["rev-parse", "HEAD"], in: repo)
        _ = try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: repo)
        _ = try await git(["reset", "--hard", "HEAD~1"], in: repo)

        let worktree = try await GitHubService().checkoutPR(7, repo: repo, readOnly: false)

        #expect(try await git(["rev-parse", "HEAD"], in: worktree) == prHead,
                "the worktree sits exactly on the PR head")
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("pr.txt").path),
                "the PR's files are materialized")

        // Reuse: a second checkout of the same PR lands on the same worktree,
        // still on the PR head, without erroring.
        let again = try await GitHubService().checkoutPR(7, repo: repo, readOnly: false)
        #expect(again.standardizedFileURL.path == worktree.standardizedFileURL.path)
        #expect(try await git(["rev-parse", "HEAD"], in: again) == prHead)
    }

    @Test("localDiff rebuilds the PR diff from fetched refs — no API size limit")
    func localDiffFromRefs() async throws {
        let repo = try await makeFixtureRepo()
        let bare = repo.deletingLastPathComponent()
            .appendingPathComponent("origin-\(UUID().uuidString.prefix(6)).git")
        _ = try await git(["init", "--bare", bare.path], in: repo)
        _ = try await git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await git(["push", "origin", "main"], in: repo)
        try "pr work".write(to: repo.appendingPathComponent("pr.txt"),
                            atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: repo)
        _ = try await git(["-c", "user.email=t@t", "-c", "user.name=T",
                           "commit", "-m", "pr head"], in: repo)
        _ = try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: repo)
        _ = try await git(["reset", "--hard", "HEAD~1"], in: repo)

        let diff = try await GitHubService().localDiff(7, baseBranch: "main", in: repo)

        #expect(diff.contains("pr.txt"), "the PR's file is in the diff")
        #expect(diff.contains("+pr work"), "with its added content")
        #expect(!diff.contains("README"), "and nothing outside the PR")
    }

    @Test("a protected worktree refuses commits")
    func commitBlocked() async throws {
        let repo = try await makeFixtureRepo()
        let path = repo.deletingLastPathComponent().appendingPathComponent("review-wt")
        _ = try await git(["worktree", "add", "--detach", path.path], in: repo)

        try await GitHubService().protectWorktree(path, repo: repo)

        try "tampering".write(to: path.appendingPathComponent("evil.txt"),
                              atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: path)
        let output = try await gitWithStatus(["-c", "user.email=t@t", "-c", "user.name=T",
                                              "commit", "-m", "should fail"], in: path)
        #expect(output.status != 0, "the guard hook must reject the commit")
        #expect(output.stderr.contains("READ-ONLY"), "and say why")
    }
}

@discardableResult
fileprivate func gitWithStatus(_ arguments: [String], in dir: URL) async throws
    -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = dir
    let err = Pipe()
    process.standardOutput = Pipe()
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
