import Foundation

/// A view over a project's pull requests: a name and a GitHub search query
/// (`review-requested:@me draft:false`…), the same syntax github.com takes in
/// its search box. Built-ins cover the daily questions; anything else is a
/// custom filter the user writes once and keeps.
public struct PRFilter: Identifiable, Codable, Hashable, Sendable {
    /// Stable for built-ins (`"mine"`), a UUID string for custom filters.
    public let id: String
    public var name: String
    /// Search qualifiers, one line. Empty = every open PR, no `--search`.
    public var query: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, query: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.query = query
        self.isBuiltIn = isBuiltIn
    }

    // MARK: Built-ins

    public static let all = PRFilter(id: "all", name: "All open", query: "", isBuiltIn: true)
    public static let mine = PRFilter(id: "mine", name: "Mine", query: "author:@me", isBuiltIn: true)
    /// `review-requested:@me` matches a request to you directly OR to a team
    /// you belong to — GitHub added `user-review-requested` precisely as the
    /// narrower, direct-only variant.
    public static let reviewRequested = PRFilter(id: "review-requested",
                                                 name: "Review requested (me or my teams)",
                                                 query: "review-requested:@me", isBuiltIn: true)
    public static let reviewRequestedDirectly = PRFilter(id: "review-requested-directly",
                                                         name: "Requested from me directly",
                                                         query: "user-review-requested:@me",
                                                         isBuiltIn: true)
    public static let assigned = PRFilter(id: "assigned", name: "Assigned to me",
                                          query: "assignee:@me", isBuiltIn: true)
    /// `review:required` depends on branch protection; "nobody reviewed yet"
    /// is `review:none`, and drafts are not waiting for anyone.
    public static let needsReview = PRFilter(id: "needs-review", name: "Needs review",
                                             query: "review:none draft:false", isBuiltIn: true)
    public static let approved = PRFilter(id: "approved", name: "Approved",
                                          query: "review:approved", isBuiltIn: true)
    public static let changesRequested = PRFilter(id: "changes-requested", name: "Changes requested",
                                                  query: "review:changes_requested", isBuiltIn: true)
    public static let drafts = PRFilter(id: "drafts", name: "Drafts", query: "draft:true",
                                        isBuiltIn: true)

    public static let builtIns: [PRFilter] = [
        .all, .mine, .reviewRequested, .reviewRequestedDirectly, .assigned,
        .needsReview, .approved, .changesRequested, .drafts,
    ]

    /// Enough for a busy repo, cheap enough for the enriched row (labels,
    /// reviewers, latest reviews all cost GraphQL points).
    public static let defaultLimit = 50

    // MARK: gh

    /// The arguments after `gh pr list`: never `--json`, the service owns that.
    /// gh scopes to open PRs unless told otherwise, so a query that names a
    /// state must lift that scope or it silently matches nothing.
    public func ghArguments(limit: Int = PRFilter.defaultLimit) -> [String] {
        var arguments = ["--limit", "\(limit)"]
        let trimmed = Self.normalizedQuery(query)
        guard !trimmed.isEmpty else { return arguments }
        arguments += ["--search", trimmed]
        if Self.namesAState(trimmed) { arguments += ["--state", "all"] }
        return arguments
    }

    static func namesAState(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).contains { token in
            let lowered = token.lowercased()
            return lowered.hasPrefix("state:")
                || lowered == "is:open" || lowered == "is:closed" || lowered == "is:merged"
                || lowered == "is:unmerged"
        }
    }

    // MARK: Custom filters

    /// The query as gh will run it: trimmed, and without `is:pr` / `type:pr`.
    /// Those are redundant under `gh pr list` — and exactly what github.com's
    /// own search box starts with, so a query pasted from it must be taken
    /// as is, not refused. Other tokens, and their order, are untouched.
    public static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace)
            .filter { token in
                let lowered = token.lowercased()
                return lowered != "is:pr" && lowered != "type:pr"
            }
            .joined(separator: " ")
    }

    /// Why a custom filter cannot be saved as typed, or nil when it can.
    public static func validate(name: String, query: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the filter a name." }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") {
            return "One line: qualifiers separated by spaces."
        }
        let query = normalizedQuery(query)
        if query.isEmpty { return "Write a search query — GitHub's search syntax." }
        let tokens = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        // repo: would fight gh's own scope — the project's repository.
        if tokens.contains(where: { $0.hasPrefix("repo:") }) {
            return "Leave out repo: — the filter already runs in the project's repository."
        }
        return nil
    }

    public static func custom(name: String, query: String) -> PRFilter {
        PRFilter(id: UUID().uuidString,
                 name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                 query: normalizedQuery(query),
                 isBuiltIn: false)
    }
}

/// The user's custom filters, on disk next to the PR cache. Disposable file:
/// unreadable means none, never an error; built-ins are never written.
public struct PRFilterStore: Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("pr-filters.json")
    }

    public func load() -> [PRFilter] {
        guard let data = try? Data(contentsOf: url),
              let filters = try? JSONDecoder().decode([PRFilter].self, from: data)
        else { return [] }
        return filters.filter { !$0.isBuiltIn }
    }

    public func save(_ filters: [PRFilter]) {
        let custom = filters.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
