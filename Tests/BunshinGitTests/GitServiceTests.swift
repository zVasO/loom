import Testing
import BunshinGit
import Foundation

// Seam : l'interface publique de GitService, sur de VRAIS repos git en dossier
// temporaire — c'est le comportement du binaire git de l'utilisateur qu'on
// contractualise (ADR-0003), pas un mock.

@Suite("GitService — worktrees et status", .serialized)
struct GitServiceTests {

    let service = GitService()

    @Test("un worktree naît sur sa branche bunshin/<slug> (GIT-01, GIT-02)")
    func creationDeWorktree() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")

        let worktree = try await service.createWorktree(repo: repo, root: root, slug: "corrige-cache")

        #expect(worktree.branch == "bunshin/corrige-cache")
        #expect(FileManager.default.fileExists(atPath: worktree.path.appendingPathComponent("README.md").path),
                "le worktree est un checkout complet")
        let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.path)
        #expect(head == "bunshin/corrige-cache", "HEAD du worktree est sur la branche de session")
    }

    @Test("collision de nom de branche : le suffixe départage (GIT-02)")
    func collisionDeBranche() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")

        let first = try await service.createWorktree(repo: repo, root: root, slug: "meme-tache")
        let second = try await service.createWorktree(repo: repo, root: root, slug: "meme-tache")

        #expect(first.branch == "bunshin/meme-tache")
        #expect(second.branch == "bunshin/meme-tache-2", "jamais d'échec sur collision : on suffixe")
        #expect(first.path != second.path)
    }

    @Test("le status porcelain v2 se parse : modifié et non-suivi (GIT-03)")
    func statusPorcelain() async throws {
        let repo = try await makeFixtureRepo()
        try "contenu modifié".write(to: repo.appendingPathComponent("README.md"),
                                    atomically: true, encoding: .utf8)
        try "nouveau".write(to: repo.appendingPathComponent("note.txt"),
                            atomically: true, encoding: .utf8)

        let changes = try await service.status(in: repo)

        #expect(changes.contains(FileChange(path: "README.md", kind: .modified)))
        #expect(changes.contains(FileChange(path: "note.txt", kind: .untracked)))
    }

    @Test("suppression sécurisée : refus si modifications non commit, force explicite (GIT-05)")
    func suppressionSecurisee() async throws {
        let repo = try await makeFixtureRepo()
        let root = repo.deletingLastPathComponent().appendingPathComponent("worktrees")
        let worktree = try await service.createWorktree(repo: repo, root: root, slug: "a-supprimer")
        try "travail en cours".write(to: worktree.path.appendingPathComponent("wip.txt"),
                                     atomically: true, encoding: .utf8)

        await #expect(throws: GitError.self) {
            try await service.removeWorktree(worktree, repo: repo)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path.path), "rien n'a été détruit")

        try await service.removeWorktree(worktree, repo: repo, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path), "force explicite : supprimé")
    }

    // MARK: - Fixtures

    private func makeFixtureRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-git-\(UUID().uuidString.prefix(8))")
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
