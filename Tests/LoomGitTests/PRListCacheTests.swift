import Testing
import Foundation
import LoomCore
@testable import LoomGit

// The PR lists survive a relaunch: the tab paints from disk, and only a list
// older than the TTL costs a `gh` call again.
@Suite("PRListCache — PR lists that survive a relaunch")
struct PRListCacheTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-pr-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pullRequest(_ number: Int) -> GitHubService.PullRequest {
        GitHubService.PullRequest(number: number, title: "Title \(number)", author: "dyger",
                                  branch: "feature/\(number)", baseBranch: "main",
                                  reviewDecision: "", checksPassing: true, isDraft: false,
                                  updatedAt: "2026-09-07T10:00:00Z",
                                  url: "https://github.com/acme/repo/pull/\(number)")
    }

    @Test("a saved list comes back identical")
    func roundTrip() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let project = ProjectID()
        let fetchedAt = Date(timeIntervalSince1970: 1_757_000_000)

        cache.save([project: .init(fetchedAt: fetchedAt, prs: [pullRequest(1), pullRequest(2)])])
        let loaded = PRListCache(directory: directory).load()

        #expect(loaded.count == 1)
        #expect(loaded[project]?.prs.map(\.number) == [1, 2])
        #expect(loaded[project]?.prs.first?.title == "Title 1")
        #expect(loaded[project]?.fetchedAt.timeIntervalSince1970 == fetchedAt.timeIntervalSince1970)
    }

    @Test("several projects keep their own list")
    func perProject() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let alpha = ProjectID()
        let beta = ProjectID()

        cache.save([alpha: .init(fetchedAt: Date(), prs: [pullRequest(1)]),
                    beta: .init(fetchedAt: Date(), prs: [pullRequest(7), pullRequest(8)])])
        let loaded = cache.load()

        #expect(loaded[alpha]?.prs.map(\.number) == [1])
        #expect(loaded[beta]?.prs.map(\.number) == [7, 8])
    }

    @Test("the TTL turns three hours old, not two")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let fresh = PRListCache.Entry(fetchedAt: now.addingTimeInterval(-2 * 3600), prs: [])
        let stale = PRListCache.Entry(fetchedAt: now.addingTimeInterval(-3 * 3600 - 1), prs: [])
        let exactly = PRListCache.Entry(fetchedAt: now.addingTimeInterval(-3 * 3600), prs: [])

        #expect(!fresh.isStale(now: now))
        #expect(stale.isStale(now: now))
        #expect(!exactly.isStale(now: now))
    }

    @Test("a missing file is an empty cache, not a failure")
    func missingFile() throws {
        let loaded = PRListCache(directory: try makeDirectory()).load()
        #expect(loaded.isEmpty)
    }

    @Test("a corrupt file is an empty cache, not a crash")
    func corruptFile() throws {
        let directory = try makeDirectory()
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("pr-cache.json"))

        #expect(PRListCache(directory: directory).load().isEmpty)
    }

    @Test("an entry whose key is not a project id is dropped")
    func unknownKey() throws {
        let directory = try makeDirectory()
        try Data(#"{"not-a-uuid":{"fetchedAt":0,"prs":[]}}"#.utf8)
            .write(to: directory.appendingPathComponent("pr-cache.json"))

        #expect(PRListCache(directory: directory).load().isEmpty)
    }

    @Test("saving twice replaces the file instead of appending to it")
    func overwrite() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let project = ProjectID()

        cache.save([project: .init(fetchedAt: Date(), prs: [pullRequest(1)])])
        cache.save([project: .init(fetchedAt: Date(), prs: [pullRequest(2)])])

        #expect(cache.load()[project]?.prs.map(\.number) == [2])
    }
}
