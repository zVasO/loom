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
