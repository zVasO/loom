import LoomCore
import LoomAgents
import Foundation
import GRDB

/// Incremental index of claude's native per-turn records, on loom.sqlite.
///
/// Each .jsonl is consumed once: `usageFile` remembers the byte offset already
/// parsed, so a refresh only reads what claude appended since. The offset stops
/// at the last newline — a line still being written is never parsed halfway.
public final class UsageIndex: Sendable {

    public struct RefreshSummary: Equatable, Sendable {
        public let filesScanned: Int
        public let turnsAdded: Int
    }

    private let database: DatabaseQueue

    public init(store: SessionStore) {
        database = store.database
    }

    public func refresh(projectsDirectory: URL, calendar: Calendar = .current) throws -> RefreshSummary {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: projectsDirectory,
                                                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else {
            return RefreshSummary(filesScanned: 0, turnsAdded: 0)
        }
        var scanned = 0
        var added = 0
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            scanned += 1
            added += try consume(file: file, size: UInt64(size),
                                 modifiedAt: modified.timeIntervalSince1970, calendar: calendar)
        }
        return RefreshSummary(filesScanned: scanned, turnsAdded: added)
    }

    private func consume(file: URL, size: UInt64, modifiedAt: Double, calendar: Calendar) throws -> Int {
        let path = file.path
        let known: (bytes: UInt64, modifiedAt: Double)? = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT bytesConsumed, modifiedAt FROM usageFile WHERE path = ?",
                             arguments: [path]).map { (UInt64($0["bytesConsumed"] as Int64), $0["modifiedAt"] as Double) }
        }
        if let known, known.bytes == size, known.modifiedAt == modifiedAt { return 0 }
        // A file that shrank was rewritten: start over (the primary key absorbs re-reads).
        let offset: UInt64 = (known.map { $0.bytes <= size ? $0.bytes : 0 }) ?? 0

        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            try remember(path: path, bytes: offset, modifiedAt: modifiedAt)
            return 0
        }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        let turns = UsageLedger.turns(fromJSONL: text)
        let consumed = offset + UInt64(complete.count)

        return try database.write { db in
            var inserted = 0
            for turn in turns {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO usageTurn
                    (messageID, requestID, at, day, model, sessionID, cwd,
                     input, cacheWrite5m, cacheWrite1h, cacheRead, output)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        turn.messageID, turn.requestID, turn.timestamp.timeIntervalSince1970,
                        UsageDay.key(for: turn.timestamp, calendar: calendar), turn.model,
                        turn.sessionID, turn.cwd, turn.input, turn.cacheWrite5m,
                        turn.cacheWrite1h, turn.cacheRead, turn.output,
                    ])
                inserted += db.changesCount
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO usageFile (path, bytesConsumed, modifiedAt) VALUES (?, ?, ?)
                """, arguments: [path, Int64(consumed), modifiedAt])
            return inserted
        }
    }

    private func remember(path: String, bytes: UInt64, modifiedAt: Double) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO usageFile (path, bytesConsumed, modifiedAt) VALUES (?, ?, ?)",
                           arguments: [path, Int64(bytes), modifiedAt])
        }
    }

    /// Per (day, model) sums from `fromDay` (inclusive, `yyyy-MM-dd`) onward, oldest first.
    public func dailyTotals(fromDay: String) throws -> [DailyModelTotals] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, model, SUM(input) AS input, SUM(cacheWrite5m) AS cacheWrite5m,
                       SUM(cacheWrite1h) AS cacheWrite1h, SUM(cacheRead) AS cacheRead, SUM(output) AS output
                FROM usageTurn WHERE day >= ? GROUP BY day, model ORDER BY day, model
                """, arguments: [fromDay]).map { row in
                DailyModelTotals(day: row["day"], model: row["model"], input: row["input"],
                                 cacheWrite5m: row["cacheWrite5m"], cacheWrite1h: row["cacheWrite1h"],
                                 cacheRead: row["cacheRead"], output: row["output"])
            }
        }
    }
}
