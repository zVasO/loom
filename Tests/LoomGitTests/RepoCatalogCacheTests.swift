import Testing
import Foundation
@testable import LoomGit

// The organizations' repositories survive a relaunch; a day later they are
// fetched again.
@Suite("RepoCatalogCache — the organizations' repositories on disk")
struct RepoCatalogCacheTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-repo-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repo(_ name: String, private isPrivate: Bool = false) -> GitHubService.Repository {
        GitHubService.Repository(nameWithOwner: name, description: "d", isPrivate: isPrivate,
                                 pushedAt: "2026-09-01T00:00:00Z")
    }

    @Test("a saved catalog comes back identical")
    func roundTrip() throws {
        let directory = try makeDirectory()
        let fetchedAt = Date(timeIntervalSince1970: 1_757_000_000)
        RepoCatalogCache(directory: directory).save(.init(
            fetchedAt: fetchedAt, viewer: "dyger",
            owners: ["acme": [repo("acme/core", private: true), repo("acme/web")],
                     "dyger": [repo("dyger/loom")]]))
        let loaded = try #require(RepoCatalogCache(directory: directory).load())
        #expect(loaded.viewer == "dyger")
        #expect(loaded.owners["acme"]?.map(\.nameWithOwner) == ["acme/core", "acme/web"])
        #expect(loaded.owners["acme"]?.first?.isPrivate == true)
        #expect(loaded.fetchedAt.timeIntervalSince1970 == fetchedAt.timeIntervalSince1970)
    }

    @Test("organizations come first, alphabetically; the viewer closes the list")
    func ownerOrder() {
        let entry = RepoCatalogCache.Entry(
            fetchedAt: Date(), viewer: "dyger",
            owners: ["zeta": [], "dyger": [], "Acme": []])
        #expect(entry.orderedOwners == ["Acme", "zeta", "dyger"])
        #expect(entry.repository(named: "x/y") == nil)
    }

    @Test("the TTL is one day")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let fresh = RepoCatalogCache.Entry(fetchedAt: now.addingTimeInterval(-23 * 3600),
                                           viewer: "v", owners: [:])
        let stale = RepoCatalogCache.Entry(fetchedAt: now.addingTimeInterval(-25 * 3600),
                                           viewer: "v", owners: [:])
        #expect(!fresh.isStale(now: now))
        #expect(stale.isStale(now: now))
    }

    @Test("a missing or corrupt file is no catalog, not a failure")
    func disposable() throws {
        let directory = try makeDirectory()
        #expect(RepoCatalogCache(directory: directory).load() == nil)
        try Data("{".utf8).write(to: directory.appendingPathComponent("repo-catalog.json"))
        #expect(RepoCatalogCache(directory: directory).load() == nil)
    }
}
