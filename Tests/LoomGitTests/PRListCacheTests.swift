import Testing
import Foundation
import LoomCore
@testable import LoomGit

// The PR lists survive a relaunch: the tab paints from disk, and only a list
// older than the TTL — or answering a filter edited since — costs a `gh` call again.
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
                                  url: "https://github.com/acme/repo/pull/\(number)",
                                  reviewers: ["alice"], labels: [.init(name: "bug", colorHex: "d73a4a")],
                                  additions: 3, deletions: 1, headSHA: "abc")
    }

    @Test("a saved list comes back identical, enrichment included")
    func roundTrip() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let project = ProjectID()
        let fetchedAt = Date(timeIntervalSince1970: 1_757_000_000)

        cache.save([project: ["all": .init(fetchedAt: fetchedAt, prs: [pullRequest(1), pullRequest(2)])]])
        let loaded = PRListCache(directory: directory).load()

        #expect(loaded.count == 1)
        let entry = try #require(loaded[project]?["all"])
        #expect(entry.prs.map(\.number) == [1, 2])
        #expect(entry.prs.first?.title == "Title 1")
        #expect(entry.prs.first?.reviewers == ["alice"])
        #expect(entry.prs.first?.labels.first?.colorHex == "d73a4a")
        #expect(entry.prs.first?.headSHA == "abc")
        #expect(entry.fetchedAt.timeIntervalSince1970 == fetchedAt.timeIntervalSince1970)
    }

    @Test("several projects and filters keep their own list")
    func perProjectAndFilter() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let alpha = ProjectID()
        let beta = ProjectID()

        cache.save([alpha: ["all": .init(fetchedAt: Date(), prs: [pullRequest(1)]),
                            "mine": .init(fetchedAt: Date(), prs: [pullRequest(2)], query: "author:@me")],
                    beta: ["all": .init(fetchedAt: Date(), prs: [pullRequest(7), pullRequest(8)])]])
        let loaded = cache.load()

        #expect(loaded[alpha]?["all"]?.prs.map(\.number) == [1])
        #expect(loaded[alpha]?["mine"]?.prs.map(\.number) == [2])
        #expect(loaded[alpha]?["mine"]?.query == "author:@me")
        #expect(loaded[beta]?["all"]?.prs.map(\.number) == [7, 8])
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

    @Test("a list answering an edited filter is stale on the spot")
    func editedFilterIsStale() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let entry = PRListCache.Entry(fetchedAt: now, prs: [], query: "label:bug")
        let same = PRFilter(id: "x", name: "Bugs", query: "label:bug", isBuiltIn: false)
        let edited = PRFilter(id: "x", name: "Bugs", query: "label:bug base:main", isBuiltIn: false)

        #expect(!entry.isStale(for: same, now: now))
        #expect(entry.isStale(for: edited, now: now))
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
            .write(to: directory.appendingPathComponent("pr-cache-v2.json"))

        #expect(PRListCache(directory: directory).load().isEmpty)
    }

    @Test("the previous cache file is simply ignored — it is disposable")
    func previousShapeIgnored() throws {
        let directory = try makeDirectory()
        try Data(#"{"8B4E5A8E-0000-4000-8000-000000000000":{"fetchedAt":0,"prs":[]}}"#.utf8)
            .write(to: directory.appendingPathComponent("pr-cache.json"))

        #expect(PRListCache(directory: directory).load().isEmpty)
    }

    @Test("an entry whose key is not a project id is dropped")
    func unknownKey() throws {
        let directory = try makeDirectory()
        try Data(#"{"not-a-uuid":{"all":{"fetchedAt":0,"prs":[],"query":""}}}"#.utf8)
            .write(to: directory.appendingPathComponent("pr-cache-v2.json"))

        #expect(PRListCache(directory: directory).load().isEmpty)
    }

    @Test("saving twice replaces the file instead of appending to it")
    func overwrite() throws {
        let directory = try makeDirectory()
        let cache = PRListCache(directory: directory)
        let project = ProjectID()

        cache.save([project: ["all": .init(fetchedAt: Date(), prs: [pullRequest(1)])]])
        cache.save([project: ["all": .init(fetchedAt: Date(), prs: [pullRequest(2)])]])

        #expect(cache.load()[project]?["all"]?.prs.map(\.number) == [2])
    }
}
