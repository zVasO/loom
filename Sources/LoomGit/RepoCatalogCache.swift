import Foundation

/// The repositories of every organization the gh account belongs to, kept
/// on disk so the PRs tab paints its catalog without a `gh` call per launch.
/// A day old, it is refetched on the next visit; the refresh button ignores
/// the age. Disposable: unreadable means empty, never an error.
public struct RepoCatalogCache: Sendable {
    public static let ttl: TimeInterval = 24 * 3600

    public struct Entry: Codable, Sendable, Equatable {
        public let fetchedAt: Date
        /// The gh account's login — its own repositories are listed too.
        public let viewer: String
        /// Repositories by owner (organizations, then the viewer).
        public let owners: [String: [GitHubService.Repository]]

        public init(fetchedAt: Date, viewer: String,
                    owners: [String: [GitHubService.Repository]]) {
            self.fetchedAt = fetchedAt
            self.viewer = viewer
            self.owners = owners
        }

        public func isStale(now: Date = Date()) -> Bool {
            now.timeIntervalSince(fetchedAt) > RepoCatalogCache.ttl
        }

        /// The organizations first, alphabetically, the viewer last.
        public var orderedOwners: [String] {
            owners.keys.filter { $0 != viewer }.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            } + (owners[viewer] != nil ? [viewer] : [])
        }

        public func repository(named nameWithOwner: String) -> GitHubService.Repository? {
            owners.values.lazy.joined().first { $0.nameWithOwner == nameWithOwner }
        }
    }

    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("repo-catalog.json")
    }

    public func load() -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    public func save(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
