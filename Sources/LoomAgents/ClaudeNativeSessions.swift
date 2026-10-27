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

    /// Every conversation on disk in ONE walk: the lowercased UUIDs of the
    /// `<uuid>.jsonl` files under every project slug. A launch with N persisted
    /// sessions asks `exists` N times, each walking every slug on a miss; the
    /// index costs one walk however many sessions ask (audit 2026-09-22, P0-2).
    public static func index(projectsDirectory: URL = defaultProjectsDirectory) -> Set<String> {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: projectsDirectory,
                                                              includingPropertiesForKeys: nil) else {
            return []
        }
        var ids = Set<String>()
        for project in projects {
            let files = (try? manager.contentsOfDirectory(at: project,
                                                          includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                ids.insert(file.deletingPathExtension().lastPathComponent.lowercased())
            }
        }
        return ids
    }

    /// `index()` membership for a session id.
    public static func contains(_ index: Set<String>, _ id: SessionID) -> Bool {
        index.contains(id.rawValue.uuidString.lowercased())
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

    /// Parses claude's native JSONL. Pure — the seam the tests contract against.
    /// Built on `UsageLedger`: duplicates (one line per content block) count once.
    /// The summary's context is the LAST turn's full input window (input +
    /// cache read + cache creation): what "context" means for the next exchange.
    public static func usage(fromJSONL text: String) -> SessionUsageSummary? {
        SessionUsageSummary(turns: UsageLedger.turns(fromJSONL: text))
    }

    /// Disk convenience: locate the native file and parse it. `tailBytes` reads
    /// only the file's tail (the context figure lives in the LAST assistant
    /// entry) — the cumulative output count then covers the tail only. Bounded
    /// by default: these files reach megabytes. Pass nil for the whole file.
    public static func usage(for id: SessionID,
                             projectsDirectory: URL = defaultProjectsDirectory,
                             tailBytes: Int? = 65_536) -> SessionUsageSummary? {
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

    // MARK: - What the agent said (workflow orchestrator, ADR-0018)

    /// The text of the assistant's messages in a JSONL slice, oldest first:
    /// one string per text block, tool calls and thinking left out.
    public static func assistantTexts(fromJSONL text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any] else { return nil }
            if let content = message["content"] as? String { return content }
            let blocks = (message["content"] as? [[String: Any]]) ?? []
            let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
    }

    /// The transcript's size now: a later `assistantTexts(for:after:)` reads
    /// only what was written since.
    public static func size(for id: SessionID, projectsDirectory: URL = defaultProjectsDirectory) -> UInt64 {
        guard let file = path(for: id, projectsDirectory: projectsDirectory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The assistant's messages written after `offset` (bytes), at most
    /// `maxBytes` of the transcript read — the tail when it is longer.
    public static func assistantTexts(for id: SessionID, after offset: UInt64 = 0, maxBytes: Int = 262_144,
                                      projectsDirectory: URL = defaultProjectsDirectory) -> [String] {
        guard let file = path(for: id, projectsDirectory: projectsDirectory),
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return [] }
        let start = max(offset, size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // A tail cut mid-line: its first line is a fragment.
        if start > offset, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return assistantTexts(fromJSONL: text)
    }
}
