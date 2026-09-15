import Foundation
import LoomCore

/// The open-PR list of every project, kept on disk so a relaunch paints the
/// PRs tab without a single `gh` call. Disposable by design: a missing or
/// unreadable file is an empty cache, never an error the user has to read.
public struct PRListCache: Sendable {
    /// Past this age a list is refetched when its project is visited. The
    /// refresh button ignores it — that is what forcing means.
    public static let ttl: TimeInterval = 3 * 3600

    public struct Entry: Codable, Sendable {
        public let fetchedAt: Date
        public let prs: [GitHubService.PullRequest]

        public init(fetchedAt: Date, prs: [GitHubService.PullRequest]) {
            self.fetchedAt = fetchedAt
            self.prs = prs
        }

        public func isStale(now: Date = Date()) -> Bool {
            now.timeIntervalSince(fetchedAt) > PRListCache.ttl
        }
    }

    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("pr-cache.json")
    }

    public func load() -> [ProjectID: Entry] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, pair in
            guard let uuid = UUID(uuidString: pair.key) else { return }
            result[ProjectID(uuid)] = pair.value
        }
    }

    public func save(_ entries: [ProjectID: Entry]) {
        // JSON object keys are strings: a dictionary keyed by ProjectID would
        // encode as a flat array of alternating keys and values.
        let stored = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.key.rawValue.uuidString, $0.value)
        })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
