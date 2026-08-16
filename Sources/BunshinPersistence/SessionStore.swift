import BunshinCore
import Foundation
import GRDB

/// Persistance locale (ADR-0002 : GRDB pour les migrations contrôlées, FTS5 à venir,
/// accès concurrents). Schéma extrait du §6.5 du cahier des charges ; migrations
/// versionnées dès la v1 (DAT-02).
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
        try migrator.migrate(database)
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

    /// NFR-R / UC-7 : au relancement, toute session encore « vivante » en base est en
    /// réalité morte avec l'app — elle devient candidate à la Reprise.
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

    // MARK: - Journal des transitions (STA-06, côté stockage)

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

// MARK: - Enregistrements

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
    public var createdAt: Date
    public var endedAt: Date?

    public init(id: SessionID, title: String, agentID: String, state: SessionState,
                branch: String? = nil, worktreePath: String? = nil, initialPrompt: String? = nil,
                exitCode: Int32? = nil, createdAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.state = state
        self.branch = branch
        self.worktreePath = worktreePath
        self.initialPrompt = initialPrompt
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.endedAt = endedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, agentID, state, branch, worktreePath, initialPrompt, exitCode, createdAt, endedAt
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
        container["createdAt"] = createdAt
        container["endedAt"] = endedAt
    }

    public init(row: Row) throws {
        guard let uuid = UUID(uuidString: row["id"]) else {
            throw DatabaseError(message: "id de session invalide")
        }
        id = SessionID(uuid)
        title = row["title"]
        agentID = row["agentID"]
        state = SessionState(rawValue: row["state"]) ?? .interrupted
        branch = row["branch"]
        worktreePath = row["worktreePath"]
        initialPrompt = row["initialPrompt"]
        exitCode = row["exitCode"]
        createdAt = row["createdAt"]
        endedAt = row["endedAt"]
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
