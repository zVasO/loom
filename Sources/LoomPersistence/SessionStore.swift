import LoomCore
import Foundation
import GRDB

/// Local persistence (ADR-0002: GRDB for controlled migrations, FTS5 to come,
/// concurrent access). Schema extracted from spec §6.5; versioned migrations
/// from v1 onward (DAT-02).
public final class SessionStore: Sendable {

    private let database: DatabaseQueue

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

    /// The user query is wrapped in FTS quotes (prefix allowed):
    /// no special character of the MATCH syntax can cause an error.
    public func searchSessions(matching query: String) throws -> [SessionID] {
        let sanitized = query.replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return [] }
        let match = "\"\(sanitized)\"*"
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID FROM sessionFTS WHERE sessionFTS MATCH ? ORDER BY rank
                """, arguments: [match])
            return rows.compactMap { UUID(uuidString: $0["sessionID"]).map(SessionID.init) }
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
    /// around the match. Same sanitation as `searchSessions` — user input can
    /// never produce a MATCH syntax error.
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
        try database.write { db in try record.insert(db) }
    }

    public func session(id: SessionID) throws -> SessionRecord? {
        try database.read { db in try SessionRecord.fetchOne(db, key: id.rawValue.uuidString) }
    }

    public func allSessions() throws -> [SessionRecord] {
        try database.read { db in
            try SessionRecord.order(Column("createdAt").desc).fetchAll(db)
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

    public init(id: SessionID, title: String, agentID: String, state: SessionState,
                branch: String? = nil, worktreePath: String? = nil, initialPrompt: String? = nil,
                exitCode: Int32? = nil, projectID: ProjectID? = nil,
                createdAt: Date, endedAt: Date? = nil) {
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
