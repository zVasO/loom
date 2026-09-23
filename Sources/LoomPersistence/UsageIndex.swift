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

    private let database: any DatabaseWriter

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
        // What is already consumed, read ONCE: a refresh walks thousands of
        // files, and each used to cost a read transaction of its own before
        // being skipped as unchanged.
        let consumedFiles: [String: (bytes: UInt64, modifiedAt: Double)] = try database.read { db in
            var map: [String: (bytes: UInt64, modifiedAt: Double)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path, bytesConsumed, modifiedAt FROM usageFile") {
                map[row["path"]] = (UInt64(row["bytesConsumed"] as Int64), row["modifiedAt"] as Double)
            }
            return map
        }
        var scanned = 0
        var added = 0
        var pending: [PendingFile] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            scanned += 1
            guard let parsed = try consume(file: file, size: UInt64(size),
                                           modifiedAt: modified.timeIntervalSince1970,
                                           known: consumedFiles[file.path]) else { continue }
            pending.append(parsed)
            if pending.count >= Self.batchSize {
                added += try flush(pending, calendar: calendar)
                pending.removeAll(keepingCapacity: true)
            }
        }
        added += try flush(pending, calendar: calendar)
        return RefreshSummary(filesScanned: scanned, turnsAdded: added)
    }

    /// What a changed file leaves to write: its new turns and the offset the
    /// next refresh resumes from. Written in batches — a first refresh on a
    /// machine with thousands of .jsonl files used to commit one transaction
    /// per file, each an fsync on the shared database.
    private struct PendingFile {
        let path: String
        let consumed: UInt64
        let modifiedAt: Double
        let turns: [UsageTurn]
    }
    private static let batchSize = 64

    /// Reads what `file` gained since it was last consumed; nil when nothing
    /// changed. Pure: no database access.
    private func consume(file: URL, size: UInt64, modifiedAt: Double,
                         known: (bytes: UInt64, modifiedAt: Double)?) throws -> PendingFile? {
        let path = file.path
        if let known, known.bytes == size, known.modifiedAt == modifiedAt { return nil }
        // A file that shrank was rewritten: start over (the primary key absorbs re-reads).
        let offset: UInt64 = (known.map { $0.bytes <= size ? $0.bytes : 0 }) ?? 0

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // No complete line yet: remember the file as seen, nothing consumed.
            return PendingFile(path: path, consumed: offset, modifiedAt: modifiedAt, turns: [])
        }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        return PendingFile(path: path, consumed: offset + UInt64(complete.count),
                           modifiedAt: modifiedAt, turns: UsageLedger.turns(fromJSONL: text))
    }

    /// One transaction for a batch of files: their turns, then their offsets
    /// — in the same transaction, so an interrupted batch re-reads its files
    /// and the primary key absorbs the duplicates.
    private func flush(_ files: [PendingFile], calendar: Calendar) throws -> Int {
        guard !files.isEmpty else { return 0 }
        return try database.write { db in
            var inserted = 0
            for file in files {
                for turn in file.turns {
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
                    """, arguments: [file.path, Int64(file.consumed), file.modifiedAt])
            }
            return inserted
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
