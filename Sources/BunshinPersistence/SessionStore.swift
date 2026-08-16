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

    // MARK: - Projets (PRJ-01/03/06)

    public func insertProject(_ record: ProjectRecord) throws {
        try database.write { db in try record.insert(db) }
    }

    public func activeProjects() throws -> [ProjectRecord] {
        try database.read { db in
            try ProjectRecord.filter(Column("archivedAt") == nil)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// PRJ-06 : l'archivage n'écrit QUE dans la base — jamais dans le dossier source.
    public func archiveProject(_ id: ProjectID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE project SET archivedAt = ? WHERE id = ?",
                           arguments: [Date(), id.rawValue.uuidString])
        }
    }

    // MARK: - Recherche plein texte (SES-08)

    /// Indexe (ou ré-indexe) une session : titre + transcript nettoyé.
    public func indexForSearch(session id: SessionID, title: String, transcript: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM sessionFTS WHERE sessionID = ?",
                           arguments: [id.rawValue.uuidString])
            try db.execute(sql: "INSERT INTO sessionFTS (sessionID, title, transcript) VALUES (?, ?, ?)",
                           arguments: [id.rawValue.uuidString, title, transcript])
        }
    }

    /// La requête utilisateur est mise entre guillemets FTS (préfixe autorisé) :
    /// aucun caractère spécial de la syntaxe MATCH ne peut faire d'erreur.
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

    // MARK: - Historique navigateur (WEB-01)

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

    /// Suggestions de la barre d'adresse : préfixe respecté, dernière visite d'abord,
    /// une entrée par URL.
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
            throw DatabaseError(message: "id de projet invalide")
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
