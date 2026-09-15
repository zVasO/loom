import Testing
import LoomGit
import Foundation

// What Loom drops into a review worktree — the /setup-pr-review command, its
// guard hooks — must never show up in that worktree's `git status`, and must
// never touch the repository's shared excludes: the user's own checkout stays
// exactly as it was. Real git, real repos (ADR-0003).
@Suite("GitHubService — files Loom adds to a review worktree", .serialized)
struct ReviewWorktreeTests {

    @Test("an installed command is found by claude, hidden from git, in this worktree only")
    func installedCommandIsExcluded() async throws {
        let repo = try await makeFixtureRepo()
        let worktree = repo.deletingLastPathComponent().appendingPathComponent("pr-7")
        _ = try await git(["worktree", "add", "--detach", worktree.path, "HEAD"], in: repo)

        try await GitHubService().installCommand(named: "setup-pr-review",
                                                 markdown: "---\ndescription: t\n---\nLoad PR 7.",
                                                 in: worktree)

        let file = worktree.appendingPathComponent(".claude/commands/setup-pr-review.md")
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("Load PR 7."),
                "claude discovers .claude/commands at startup")
        #expect(try await git(["status", "--porcelain"], in: worktree) == "",
                "nothing Loom wrote shows as untracked in the review worktree")
        // The shared excludes are untouched: the same file in the user's own
        // checkout would still be reported.
        let commands = repo.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "x".write(to: commands.appendingPathComponent("setup-pr-review.md"),
                      atomically: true, encoding: .utf8)
        #expect(try await git(["status", "--porcelain"], in: repo).contains(".claude/"),
                "the user's checkout is not silenced by the worktree's excludes")
    }

    @Test("reinstalling rewrites the command with the new text")
    func reinstallRewrites() async throws {
        let repo = try await makeFixtureRepo()
        let worktree = repo.deletingLastPathComponent().appendingPathComponent("pr-8")
        _ = try await git(["worktree", "add", "--detach", worktree.path, "HEAD"], in: repo)
        let service = GitHubService()

        try await service.installCommand(named: "setup-pr-review", markdown: "first", in: worktree)
        try await service.installCommand(named: "setup-pr-review", markdown: "second", in: worktree)

        let file = worktree.appendingPathComponent(".claude/commands/setup-pr-review.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "second")
        #expect(try await git(["status", "--porcelain"], in: worktree) == "")
    }

    @Test("the exclude list names every Loom file, commands included")
    func excludeList() {
        let list = GitHubService.loomExcludes(commandNames: ["setup-pr-review"])
        #expect(list.contains("/.loom-review/\n"))
        #expect(list.contains("/.loom-guard-hooks/\n"))
        #expect(list.contains("/.claude/commands/setup-pr-review.md\n"))
    }
}

private func makeFixtureRepo() async throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("loom-review-\(UUID().uuidString.prefix(8))")
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
