import LoomCore
import Foundation

// The parameters and results of every method — the shapes a client types
// against. Session references are optional: a session token means "mine",
// a global token must say which.

/// A session as the API shows it. `state` is the session state's raw value
/// (CONTEXT.md: working, needs_input, idle, …); dates are ISO 8601.
public struct APISession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: String
    public var projectID: String?
    public var branch: String?
    public var worktreePath: String?
    public var badges: [String]
    public var createdAt: String

    public init(id: String, title: String, state: String, projectID: String? = nil,
                branch: String? = nil, worktreePath: String? = nil, badges: [String],
                createdAt: String) {
        self.id = id
        self.title = title
        self.state = state
        self.projectID = projectID
        self.branch = branch
        self.worktreePath = worktreePath
        self.badges = badges
        self.createdAt = createdAt
    }
}

/// `session.get`: which session — omitted under a session token.
public struct APISessionRef: Codable, Equatable, Sendable {
    public var sessionId: String?
    public init(sessionId: String? = nil) { self.sessionId = sessionId }
}

/// `sessions.list`: archived sessions stay out unless asked for.
public struct APISessionsListParams: Codable, Equatable, Sendable {
    public var includeArchived: Bool?
    public init(includeArchived: Bool? = nil) { self.includeArchived = includeArchived }
}

public struct APISessionsListResult: Codable, Equatable, Sendable {
    public var sessions: [APISession]
    public init(sessions: [APISession]) { self.sessions = sessions }
}

/// `session.setTitle`.
public struct APISetTitleParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var title: String
    public init(sessionId: String? = nil, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

/// `session.setBadges`: the whole list, in order; empty clears.
public struct APISetBadgesParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var badges: [String]
    public init(sessionId: String? = nil, badges: [String]) {
        self.sessionId = sessionId
        self.badges = badges
    }
}

/// One entry of the badge catalog.
public struct APIBadge: Codable, Equatable, Sendable {
    public var name: String
    /// `#RRGGBB`.
    public var colorHex: String
    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }

    /// The only color shape the catalog accepts.
    public static func isValidColor(_ hex: String) -> Bool {
        guard hex.count == 7, hex.hasPrefix("#") else { return false }
        return hex.dropFirst().allSatisfy(\.isHexDigit)
    }
}

public struct APIBadgeListResult: Codable, Equatable, Sendable {
    public var badges: [APIBadge]
    public init(badges: [APIBadge]) { self.badges = badges }
}

/// `badge.create`: the color is optional — the catalog's muted default otherwise.
public struct APICreateBadgeParams: Codable, Equatable, Sendable {
    public var name: String
    public var colorHex: String?
    public init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// `loom.version`.
public struct APIVersion: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var app: String
    public init(protocolVersion: Int, app: String) {
        self.protocolVersion = protocolVersion
        self.app = app
    }
}

/// What an agent may write through the API. Loom's own tools run without a
/// permission prompt (pre-approved), so what they write is bounded here: a
/// session title also becomes a system notification's title, and a prompt-
/// injected agent must not be able to turn it into a message of its own.
public enum APILimits {
    public static let titleMaxLength = 80
    public static let badgesPerSession = 8
    public static let badgeNameMaxLength = 24
    /// Badge definitions the API may bring the catalog up to.
    public static let catalogMaxCount = 32

    /// One line, no control characters, at most `titleMaxLength` characters;
    /// empty when nothing printable is left.
    public static func sanitizedTitle(_ raw: String) -> String {
        let printable = raw.unicodeScalars.map { scalar -> String in
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? "" : String(scalar)
        }.joined()
        let collapsed = printable.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(titleMaxLength))
    }

    /// nil when the list is acceptable, the reason otherwise.
    public static func badgeProblem(_ badges: [String]) -> String? {
        if badges.count > badgesPerSession {
            return "at most \(badgesPerSession) badges per session"
        }
        if let long = badges.first(where: { $0.count > badgeNameMaxLength }) {
            return "badge name too long (\(badgeNameMaxLength) characters at most): \(long.prefix(40))"
        }
        return nil
    }
}
