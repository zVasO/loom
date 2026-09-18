import Foundation
import LoomCore

/// The PR lists of every project, one per filter, kept on disk so a relaunch
/// paints the PRs tab without a single `gh` call. Disposable by design: a
/// missing or unreadable file is an empty cache, never an error the user has
/// to read — which is also why a new shape gets a new file name.
public struct PRListCache: Sendable {
    /// Past this age a list is refetched when its project is visited. The
    /// refresh button ignores it — that is what forcing means.
    public static let ttl: TimeInterval = 3 * 3600

    public struct Entry: Codable, Sendable {
        public let fetchedAt: Date
        public let prs: [GitHubService.PullRequest]
        /// The query the list answers. A custom filter edited since is a
        /// different question: its stored answer is stale on the spot.
        public let query: String

        public init(fetchedAt: Date, prs: [GitHubService.PullRequest], query: String = "") {
            self.fetchedAt = fetchedAt
            self.prs = prs
            self.query = query
        }

        public func isStale(now: Date = Date()) -> Bool {
            now.timeIntervalSince(fetchedAt) > PRListCache.ttl
        }

        /// Stale by age, or by the filter having changed under it.
        public func isStale(for filter: PRFilter, now: Date = Date()) -> Bool {
            isStale(now: now) || query != filter.query
        }
    }

    /// Lists keyed by project, then by filter id.
    public typealias Lists = [ProjectID: [String: Entry]]

    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("pr-cache-v2.json")
    }

    public func load() -> Lists {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: [String: Entry]].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, pair in
            guard let uuid = UUID(uuidString: pair.key) else { return }
            result[ProjectID(uuid)] = pair.value
        }
    }

    public func save(_ lists: Lists) {
        // JSON object keys are strings: a dictionary keyed by ProjectID would
        // encode as a flat array of alternating keys and values.
        let stored = Dictionary(uniqueKeysWithValues: lists.map {
            ($0.key.rawValue.uuidString, $0.value)
        })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
