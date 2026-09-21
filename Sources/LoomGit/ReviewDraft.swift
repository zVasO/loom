import Foundation

/// A line comment written but not sent: it waits, with the others, for the
/// verdict — then they leave GitHub-side as ONE review, the way "Start a
/// review" works on github.com.
public struct DraftComment: Sendable, Equatable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let path: String
    public let firstLine: Int
    public let lastLine: Int
    /// RIGHT (new code) or LEFT (deleted lines).
    public let side: String
    /// The full body, suggestion fence included when it is one.
    public let body: String
    public let createdAt: Date

    public init(id: UUID = UUID(), path: String, firstLine: Int, lastLine: Int,
                side: String = "RIGHT", body: String, createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.firstLine = firstLine
        self.lastLine = max(firstLine, lastLine)
        self.side = side
        self.body = body
        self.createdAt = createdAt
    }

    public var isSuggestion: Bool { body.contains("```suggestion") }
}

/// Every pending comment of one PR, remembered against the head it was
/// written on: a head that moved since is worth a warning, not a loss.
public struct ReviewDraft: Sendable, Equatable, Codable {
    public var headSHA: String
    public var comments: [DraftComment]

    public init(headSHA: String, comments: [DraftComment] = []) {
        self.headSHA = headSHA
        self.comments = comments
    }

    public var isEmpty: Bool { comments.isEmpty }

    public func adding(_ comment: DraftComment) -> ReviewDraft {
        ReviewDraft(headSHA: headSHA, comments: comments + [comment])
    }

    public func removing(_ id: UUID) -> ReviewDraft {
        ReviewDraft(headSHA: headSHA, comments: comments.filter { $0.id != id })
    }

    /// The comments anchored to one diff line (the last line of their range,
    /// where GitHub hangs a multi-line comment).
    public func comments(path: String, line: Int, side: String) -> [DraftComment] {
        comments.filter { $0.path == path && $0.lastLine == line && $0.side == side }
    }
}

/// Drafts on disk, keyed by `<project>#<number>`, next to the PR cache: a
/// review started before lunch survives a relaunch. Disposable file —
/// unreadable means no draft, never an error.
public struct ReviewDraftStore: Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("pr-review-drafts.json")
    }

    public func load() -> [String: ReviewDraft] {
        guard let data = try? Data(contentsOf: url),
              let drafts = try? Self.decoder.decode([String: ReviewDraft].self, from: data)
        else { return [:] }
        return drafts.filter { !$0.value.isEmpty }
    }

    public func save(_ drafts: [String: ReviewDraft]) {
        let kept = drafts.filter { !$0.value.isEmpty }
        guard let data = try? Self.encoder.encode(kept) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
