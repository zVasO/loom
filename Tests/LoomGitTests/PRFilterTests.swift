import Testing
import Foundation
@testable import LoomGit

// A filter is a GitHub search query handed to `gh pr list --search`. The
// arguments it builds are the contract: gh scopes to open PRs on its own, so
// a query naming a state has to lift that scope.
@Suite("PRFilter — PR lists as GitHub search queries")
struct PRFilterTests {

    @Test("built-in ids are unique and stable — they key the cache on disk")
    func builtInIdentities() {
        let ids = PRFilter.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "all")
        #expect(PRFilter.builtIns.allSatisfy(\.isBuiltIn))
        #expect(PRFilter.reviewRequested.query == "review-requested:@me",
                "direct AND team requests — the wide net")
        #expect(PRFilter.reviewRequestedDirectly.query == "user-review-requested:@me")
    }

    @Test("'All open' adds no --search, only the limit")
    func allOpenArguments() {
        #expect(PRFilter.all.ghArguments() == ["--limit", "50"])
        #expect(PRFilter.all.ghArguments(limit: 10) == ["--limit", "10"])
    }

    @Test("a query travels through --search, untouched")
    func searchArguments() {
        #expect(PRFilter.mine.ghArguments() == ["--limit", "50", "--search", "author:@me"])
        #expect(PRFilter.needsReview.ghArguments()
                == ["--limit", "50", "--search", "review:none draft:false"])
    }

    @Test("a query that names a state lifts gh's open-only scope")
    func stateLiftsScope() {
        let merged = PRFilter.custom(name: "Merged", query: "is:merged author:@me")
        #expect(merged.ghArguments() == ["--limit", "50", "--search", "is:merged author:@me",
                                         "--state", "all"])
        let closed = PRFilter.custom(name: "Closed", query: "state:closed")
        #expect(closed.ghArguments().suffix(2) == ["--state", "all"])
        let open = PRFilter.custom(name: "Team", query: "team-review-requested:acme/core")
        #expect(!open.ghArguments().contains("--state"))
    }

    @Test("validation refuses what gh would silently break on")
    func validation() {
        #expect(PRFilter.validate(name: "", query: "author:@me") != nil)
        #expect(PRFilter.validate(name: "x", query: "   ") != nil)
        #expect(PRFilter.validate(name: "x", query: "a:b\nc:d") != nil)
        #expect(PRFilter.validate(name: "x", query: "repo:acme/repo author:@me") != nil)
        #expect(PRFilter.validate(name: "x", query: "is:pr author:@me") != nil)
        #expect(PRFilter.validate(name: "x", query: "label:bug base:main") == nil)
    }

    @Test("a custom filter gets a fresh id, trimmed fields, and is never built-in")
    func customFilter() {
        let filter = PRFilter.custom(name: "  Hotfix ", query: " label:hotfix ")
        #expect(!filter.isBuiltIn)
        #expect(filter.name == "Hotfix")
        #expect(filter.query == "label:hotfix")
        #expect(UUID(uuidString: filter.id) != nil)
        #expect(PRFilter.custom(name: "a", query: "b").id != filter.id)
    }
}

@Suite("PRFilterStore — custom filters that survive a relaunch")
struct PRFilterStoreTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-pr-filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("saved filters come back identical, built-ins are never written")
    func roundTrip() throws {
        let directory = try makeDirectory()
        let store = PRFilterStore(directory: directory)
        let custom = PRFilter.custom(name: "Team", query: "team-review-requested:acme/core")

        store.save([PRFilter.all, custom])
        let loaded = PRFilterStore(directory: directory).load()

        #expect(loaded == [custom])
    }

    @Test("a missing or corrupt file is an empty list, not a failure")
    func missingAndCorrupt() throws {
        let directory = try makeDirectory()
        #expect(PRFilterStore(directory: directory).load().isEmpty)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("pr-filters.json"))
        #expect(PRFilterStore(directory: directory).load().isEmpty)
    }
}
