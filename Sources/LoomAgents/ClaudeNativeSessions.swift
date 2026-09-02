import LoomCore
import Foundation

/// Resume (UC-7) only makes sense if claude has persisted a conversation:
/// the native `<uuid>.jsonl` file under `~/.claude/projects/<slug>/`. If it does not
/// exist (session launched but never used), `--resume` would fail — the caller
/// relaunches fresh under the SAME UUID in the same worktree.
public enum ClaudeNativeSessions {

    public static var defaultProjectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    public static func exists(_ id: SessionID,
                              projectsDirectory: URL = defaultProjectsDirectory) -> Bool {
        path(for: id, projectsDirectory: projectsDirectory) != nil
    }

    /// The native `<uuid>.jsonl` on disk, wherever its project slug lives.
    public static func path(for id: SessionID,
                            projectsDirectory: URL = defaultProjectsDirectory) -> URL? {
        let target = id.rawValue.uuidString.lowercased() + ".jsonl"
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: projectsDirectory,
                                                              includingPropertiesForKeys: nil) else {
            return nil
        }
        for project in projects {
            let candidates = (try? manager.contentsOfDirectory(at: project,
                                                               includingPropertiesForKeys: nil)) ?? []
            if let match = candidates.first(where: { $0.lastPathComponent.lowercased() == target }) {
                return match
            }
        }
        return nil
    }

    // MARK: - v3: real token counters, read from claude's own records

    public struct SessionUsage: Equatable, Sendable {
        /// The LAST turn's full input window (input + cache read + cache creation):
        /// what "context" actually means for the next exchange.
        public let contextTokens: Int
        /// Output tokens accumulated across all assistant turns.
        public let outputTokens: Int
    }

    /// Parses claude's native JSONL. Pure — the seam the tests contract against.
    /// Built on `UsageLedger`: duplicates (one line per content block) count once.
    public static func usage(fromJSONL text: String) -> SessionUsage? {
        let turns = UsageLedger.turns(fromJSONL: text)
        guard let last = turns.last else { return nil }
        return SessionUsage(contextTokens: last.contextTokens,
                            outputTokens: turns.reduce(0) { $0 + $1.output })
    }

    /// Disk convenience: locate the native file and parse it. `tailBytes` reads
    /// only the file's tail (the context figure lives in the LAST assistant
    /// entry) — the cumulative output count then covers the tail only.
    public static func usage(for id: SessionID,
                             projectsDirectory: URL = defaultProjectsDirectory,
                             tailBytes: Int? = nil) -> SessionUsage? {
        guard let file = path(for: id, projectsDirectory: projectsDirectory) else { return nil }
        let text: String
        if let tailBytes,
           let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { return nil }
            text = String(decoding: data, as: UTF8.self)
        } else {
            guard let full = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            text = full
        }
        return usage(fromJSONL: text)
    }
}
