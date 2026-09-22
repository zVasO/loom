import LoomCore
import Foundation
import GRDB

/// Local persistence (ADR-0002: GRDB for controlled migrations, FTS5 to come,
/// concurrent access). Schema extracted from spec §6.5; versioned migrations
/// from v1 onward (DAT-02).
public final class SessionStore: Sendable {

    let database: DatabaseQueue

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-sessions") { db in
            try db.create(table: "session") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("agentID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("branch", .text)
                t.column("worktreePath", .text)
                t.column("initialPrompt", .text)
                t.column("exitCode", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.create(table: "stateTransition") { t in
                t.autoIncrementedPrimaryKey("rowID")
                t.column("sessionID", .text).notNull().indexed()
                    .references("session", onDelete: .cascade)
                t.column("fromState", .text).notNull()
                t.column("toState", .text).notNull()
                t.column("source", .text).notNull()
                t.column("at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-web-history") { db in
            try db.create(table: "webHistory") { t in
                t.autoIncrementedPrimaryKey("rowID")
                t.column("url", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("visitedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v3-fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE sessionFTS USING fts5(
                    sessionID UNINDEXED, title, transcript,
                    tokenize='unicode61 remove_diacritics 2'
                )
                """)
        }
        migrator.registerMigration("v4-projects") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("defaultBranch", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }
            try db.alter(table: "session") { t in
                t.add(column: "projectID", .text).indexed()
            }
        }
        migrator.registerMigration("v5-badge") { db in
            // Badges: a small label + color on a session (PR #42, review, wip…).
            try db.alter(table: "session") { $0.add(column: "badge", .text) }
        }
        migrator.registerMigration("v6-usage") { db in
            // Usage & costs: an incremental index of claude's native .jsonl records.
            // usageFile remembers how far each file has been consumed.
            try db.create(table: "usageFile") { t in
                t.primaryKey("path", .text)
                t.column("bytesConsumed", .integer).notNull()
                t.column("modifiedAt", .double).notNull()
            }
            try db.create(table: "usageTurn") { t in
                t.column("messageID", .text).notNull()
                t.column("requestID", .text).notNull()
                t.column("at", .double).notNull()
                t.column("day", .text).notNull().indexed()
                t.column("model", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("cwd", .text)
                t.column("input", .integer).notNull()
                t.column("cacheWrite5m", .integer).notNull()
                t.column("cacheWrite1h", .integer).notNull()
                t.column("cacheRead", .integer).notNull()
                t.column("output", .integer).notNull()
                t.primaryKey(["messageID", "requestID"])
            }
        }
        migrator.registerMigration("v7-session-badges") { db in
            // Several badges per session (PR #42 + review + urgent): one row per
            // assignment, kept in assignment order. The v5 column carried at
            // most one — its value moves across, then the column goes.
            try db.create(table: "sessionBadge") { t in
                t.column("sessionID", .text).notNull()
                    .references("session", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull()
                // The key doubles as the per-session index: lookups lead with sessionID.
                t.primaryKey(["sessionID", "name"])
            }
            try db.execute(sql: """
                INSERT INTO sessionBadge (sessionID, name, position)
                SELECT id, badge, 0 FROM session WHERE badge IS NOT NULL AND badge <> ''
                """)
            try db.alter(table: "session") { $0.drop(column: "badge") }
        }
        migrator.registerMigration("v8-badge-definitions") { db in
            // The badge catalog (name + color) used to live in UserDefaults —
            // the app alone could read it. Agents (ADR-0010) and the app now
            // share one source. Seeded with the built-in three; the app
            // imports a user's saved catalog on top, once.
            try db.create(table: "badgeDefinition") { t in
                t.primaryKey("name", .text)
                t.column("colorHex", .text).notNull()
                t.column("position", .integer).notNull()
            }
            for (position, definition) in BadgeDefinition.builtIn.enumerated() {
                try db.execute(
                    sql: "INSERT INTO badgeDefinition (name, colorHex, position) VALUES (?, ?, ?)",
                    arguments: [definition.name, definition.colorHex, position])
            }
        }
        try migrator.migrate(database)
    }

    // MARK: - Projects (PRJ-01/03/06)

    public func insertProject(_ record: ProjectRecord) throws {
        try database.write { db in try record.insert(db) }
    }

    public func activeProjects() throws -> [ProjectRecord] {
        try database.read { db in
            try ProjectRecord.filter(Column("archivedAt") == nil)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// PRJ-06: archiving writes ONLY to the database — never to the source folder.
    public func archiveProject(_ id: ProjectID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE project SET archivedAt = ? WHERE id = ?",
                           arguments: [Date(), id.rawValue.uuidString])
        }
    }

    // MARK: - Full-text search (SES-08)

    /// Indexes (or re-indexes) a session: title + cleaned transcript.
    public func indexForSearch(session id: SessionID, title: String, transcript: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM sessionFTS WHERE sessionID = ?",
                           arguments: [id.rawValue.uuidString])
            try db.execute(sql: "INSERT INTO sessionFTS (sessionID, title, transcript) VALUES (?, ?, ?)",
                           arguments: [id.rawValue.uuidString, title, transcript])
        }
    }

    /// A full-text hit: the session plus the transcript excerpt that matched,
    /// with the match highlighted by FTS5's snippet().
    public struct SearchHit: Sendable, Equatable {
        public let id: SessionID
        public let title: String
        public let snippet: String
    }

    /// v2 search: sessions ranked by FTS5 relevance, each with a short excerpt
    /// around the match. The user query is wrapped in FTS quotes (prefix
    /// allowed): no special character of the MATCH syntax can cause an error.
    public func searchTranscripts(matching query: String) throws -> [SearchHit] {
        let sanitized = query.replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return [] }
        let match = "\"\(sanitized)\"*"
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID, title,
                       snippet(sessionFTS, 2, '', '', '…', 12) AS excerpt
                FROM sessionFTS WHERE sessionFTS MATCH ? ORDER BY rank LIMIT 20
                """, arguments: [match])
            return rows.compactMap { row in
                UUID(uuidString: row["sessionID"]).map {
                    SearchHit(id: SessionID($0), title: row["title"], snippet: row["excerpt"])
                }
            }
        }
    }

    // MARK: - Badges

    /// Replaces a session's badges — the whole list, in the given order; an
    /// empty list clears them. Duplicates and blanks never land.
    public func setBadges(session id: SessionID, badges: [String]) throws {
        try database.write { db in try Self.writeBadges(db, session: id, badges: badges) }
    }

    private static func writeBadges(_ db: Database, session id: SessionID,
                                    badges: [String]) throws {
        let key = id.rawValue.uuidString
        try db.execute(sql: "DELETE FROM sessionBadge WHERE sessionID = ?", arguments: [key])
        for (position, name) in SessionRecord.normalizedBadges(badges).enumerated() {
            try db.execute(
                sql: "INSERT INTO sessionBadge (sessionID, name, position) VALUES (?, ?, ?)",
                arguments: [key, name, position])
        }
    }

    /// Badges of every session in one query, keyed by the session's stored id.
    private static func badgesBySession(_ db: Database,
                                        only ids: [String]? = nil) throws -> [String: [String]] {
        let rows: [Row]
        if let ids {
            guard !ids.isEmpty else { return [:] }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            rows = try Row.fetchAll(
                db,
                sql: "SELECT sessionID, name FROM sessionBadge WHERE sessionID IN (\(placeholders)) ORDER BY position",
                arguments: StatementArguments(ids))
        } else {
            rows = try Row.fetchAll(
                db, sql: "SELECT sessionID, name FROM sessionBadge ORDER BY sessionID, position")
        }
        var result: [String: [String]] = [:]
        for row in rows {
            let session: String = row["sessionID"]
            let name: String = row["name"]
            result[session, default: []].append(name)
        }
        return result
    }

    private static func attachBadges(_ db: Database, to records: [SessionRecord],
                                     bulk: Bool) throws -> [SessionRecord] {
        guard !records.isEmpty else { return records }
        let badges = try badgesBySession(db, only: bulk ? nil : records.map(\.id.rawValue.uuidString))
        return records.map { record in
            var copy = record
            copy.badges = badges[record.id.rawValue.uuidString] ?? []
            return copy
        }
    }

    // MARK: - Badge definitions (the catalog, v8)

    /// The catalog, in display order.
    public func badgeDefinitions() throws -> [BadgeDefinition] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT name, colorHex FROM badgeDefinition ORDER BY position")
                .map { BadgeDefinition(name: $0["name"], colorHex: $0["colorHex"]) }
        }
    }

    /// Replaces the whole catalog, in the given order — the Settings page's
    /// gesture. A name appears once; the first occurrence wins.
    public func saveBadgeDefinitions(_ definitions: [BadgeDefinition]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM badgeDefinition")
            for (position, definition) in BadgeDefinition.normalized(definitions).enumerated() {
                try db.execute(
                    sql: "INSERT INTO badgeDefinition (name, colorHex, position) VALUES (?, ?, ?)",
                    arguments: [definition.name, definition.colorHex, position])
            }
        }
    }

    /// Appends one definition to the catalog — the API's `badge.create`.
    /// Returns false, and changes nothing, when the name is already taken.
    @discardableResult
    public func addBadgeDefinition(_ definition: BadgeDefinition) throws -> Bool {
        guard let normalized = BadgeDefinition.normalized([definition]).first else { return false }
        return try database.write { db -> Bool in
            let taken = try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM badgeDefinition WHERE name = ?)",
                arguments: [normalized.name]) ?? false
            guard !taken else { return false }
            let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM badgeDefinition") ?? 0
            try db.execute(
                sql: "INSERT INTO badgeDefinition (name, colorHex, position) VALUES (?, ?, ?)",
                arguments: [normalized.name, normalized.colorHex, next])
            return true
        }
    }

    // MARK: - Browser history (WEB-01)

    public func recordVisit(url: String, title: String, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO webHistory (url, title, visitedAt) VALUES (?, ?, ?)",
                           arguments: [url, title, date])
        }
    }

    public struct VisitSuggestion: Sendable, Equatable {
        public let url: String
        public let title: String
    }

    /// Address bar suggestions: prefix respected, most recent visit first,
    /// one entry per URL.
    public func historySuggestions(prefix: String, limit: Int = 8) throws -> [VisitSuggestion] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT url, title, MAX(visitedAt) AS lastVisit FROM webHistory
                WHERE url LIKE ? GROUP BY url ORDER BY lastVisit DESC LIMIT ?
                """, arguments: [prefix + "%", limit])
            return rows.map { VisitSuggestion(url: $0["url"], title: $0["title"]) }
        }
    }

    // MARK: - Sessions

    public func insert(_ record: SessionRecord) throws {
        try database.write { db in
            try record.insert(db)
            try Self.writeBadges(db, session: record.id, badges: record.badges)
        }
    }

    public func session(id: SessionID) throws -> SessionRecord? {
        try database.read { db in
            guard let record = try SessionRecord.fetchOne(db, key: id.rawValue.uuidString)
            else { return nil }
            return try Self.attachBadges(db, to: [record], bulk: false).first
        }
    }

    public func allSessions() throws -> [SessionRecord] {
        try database.read { db in
            let records = try SessionRecord.order(Column("createdAt").desc).fetchAll(db)
            return try Self.attachBadges(db, to: records, bulk: true)
        }
    }

    public func updateState(session id: SessionID, to state: SessionState,
                            exitCode: Int32? = nil, endedAt: Date? = nil) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE session SET state = ?, exitCode = COALESCE(?, exitCode), endedAt = COALESCE(?, endedAt) WHERE id = ?",
                arguments: [state.rawValue, exitCode, endedAt, id.rawValue.uuidString])
        }
    }

    /// SES-05: renaming.
    public func rename(session id: SessionID, to title: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE session SET title = ? WHERE id = ?",
                           arguments: [title, id.rawValue.uuidString])
        }
    }

    /// NFR-R / UC-7: on relaunch, any session still "live" in the database is in
    /// fact dead along with the app — it becomes a candidate for Resume.
    @discardableResult
    public func markLiveSessionsInterrupted() throws -> Int {
        let live = [SessionState.starting, .working, .needsInput, .idle].map(\.rawValue)
        return try database.write { db in
            try db.execute(
                sql: "UPDATE session SET state = ? WHERE state IN (\(live.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments([SessionState.interrupted.rawValue] + live))
            return db.changesCount
        }
    }

    // MARK: - Transition journal (STA-06, storage side)

    public func recordTransition(session id: SessionID, from: SessionState, to: SessionState,
                                 source: TransitionSource, at instant: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO stateTransition (sessionID, fromState, toState, source, at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id.rawValue.uuidString, from.rawValue, to.rawValue, source.rawValue, instant])
        }
    }

    public func transitions(session id: SessionID) throws -> [TransitionRecord] {
        try database.read { db in
            try TransitionRecord
                .filter(Column("sessionID") == id.rawValue.uuidString)
                .order(Column("at"))
                .fetchAll(db)
        }
    }
}

// MARK: - Records

public struct SessionRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session"

    public var id: SessionID
    public var title: String
    public var agentID: String
    public var state: SessionState
    public var branch: String?
    public var worktreePath: String?
    public var initialPrompt: String?
    public var exitCode: Int32?
    public var projectID: ProjectID?
    public var createdAt: Date
    public var endedAt: Date?
    /// Session badges, in assignment order — each resolved to a color by the
    /// badge definitions. Stored in `sessionBadge`, not in the session row:
    /// the record carries them, the store loads and writes them.
    public var badges: [String] = []

    public init(id: SessionID, title: String, agentID: String, state: SessionState,
                branch: String? = nil, worktreePath: String? = nil, initialPrompt: String? = nil,
                exitCode: Int32? = nil, projectID: ProjectID? = nil,
                createdAt: Date, endedAt: Date? = nil, badges: [String] = []) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.state = state
        self.branch = branch
        self.worktreePath = worktreePath
        self.initialPrompt = initialPrompt
        self.exitCode = exitCode
        self.projectID = projectID
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.badges = Self.normalizedBadges(badges)
    }

    /// The badges a session may wear: trimmed, non-empty, each name once,
    /// first occurrence wins the position.
    public static func normalizedBadges(_ badges: [String]) -> [String] {
        var seen = Set<String>()
        return badges.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, agentID, state, branch, worktreePath, initialPrompt, exitCode, projectID,
             createdAt, endedAt
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.rawValue.uuidString
        container["title"] = title
        container["agentID"] = agentID
        container["state"] = state.rawValue
        container["branch"] = branch
        container["worktreePath"] = worktreePath
        container["initialPrompt"] = initialPrompt
        container["exitCode"] = exitCode
        container["projectID"] = projectID?.rawValue.uuidString
        container["createdAt"] = createdAt
        container["endedAt"] = endedAt
    }

    public init(row: Row) throws {
        guard let uuid = UUID(uuidString: row["id"]) else {
            throw DatabaseError(message: "invalid session id")
        }
        id = SessionID(uuid)
        title = row["title"]
        agentID = row["agentID"]
        state = SessionState(rawValue: row["state"]) ?? .interrupted
        branch = row["branch"]
        worktreePath = row["worktreePath"]
        initialPrompt = row["initialPrompt"]
        exitCode = row["exitCode"]
        projectID = (row["projectID"] as String?).flatMap(UUID.init(uuidString:)).map(ProjectID.init)
        createdAt = row["createdAt"]
        endedAt = row["endedAt"]
    }
}

/// One entry of the badge catalog: a name and the color its chips wear.
/// Global to the app — sessions reference definitions by name.
public struct BadgeDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var colorHex: String

    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }

    /// The catalog a fresh database starts with.
    public static let builtIn = [
        BadgeDefinition(name: "review", colorHex: "#4CC38A"),
        BadgeDefinition(name: "wip", colorHex: "#E5B455"),
        BadgeDefinition(name: "urgent", colorHex: "#E5646C"),
    ]

    /// Trimmed names, none empty, each once — first occurrence wins.
    public static func normalized(_ definitions: [BadgeDefinition]) -> [BadgeDefinition] {
        var seen = Set<String>()
        return definitions.compactMap { definition in
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return BadgeDefinition(name: name, colorHex: definition.colorHex)
        }
    }
}

public struct ProjectRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"

    public var id: ProjectID
    public var name: String
    public var path: String
    public var defaultBranch: String?
    public var createdAt: Date
    public var archivedAt: Date?

    public init(id: ProjectID, name: String, path: String, defaultBranch: String?,
                createdAt: Date, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.rawValue.uuidString
        container["name"] = name
        container["path"] = path
        container["defaultBranch"] = defaultBranch
        container["createdAt"] = createdAt
        container["archivedAt"] = archivedAt
    }

    public init(row: Row) throws {
        guard let uuid = UUID(uuidString: row["id"]) else {
            throw DatabaseError(message: "invalid project id")
        }
        id = ProjectID(uuid)
        name = row["name"]
        path = row["path"]
        defaultBranch = row["defaultBranch"]
        createdAt = row["createdAt"]
        archivedAt = row["archivedAt"]
    }
}

public struct TransitionRecord: Codable, Equatable, Sendable, FetchableRecord, TableRecord {
    public static let databaseTableName = "stateTransition"

    public var sessionID: String
    public var from: SessionState
    public var to: SessionState
    public var source: TransitionSource
    public var at: Date

    public init(row: Row) throws {
        sessionID = row["sessionID"]
        from = SessionState(rawValue: row["fromState"]) ?? .interrupted
        to = SessionState(rawValue: row["toState"]) ?? .interrupted
        source = TransitionSource(rawValue: row["source"]) ?? .user
        at = row["at"]
    }
}
