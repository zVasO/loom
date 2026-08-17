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
    public static func usage(fromJSONL text: String) -> SessionUsage? {
        var lastContext: Int?
        var totalOutput = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            lastContext = input + cacheRead + cacheCreation
            totalOutput += usage["output_tokens"] as? Int ?? 0
        }
        guard let lastContext else { return nil }
        return SessionUsage(contextTokens: lastContext, outputTokens: totalOutput)
    }

    /// Disk convenience: locate the native file and parse it.
    public static func usage(for id: SessionID,
                             projectsDirectory: URL = defaultProjectsDirectory) -> SessionUsage? {
        guard let file = path(for: id, projectsDirectory: projectsDirectory),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return usage(fromJSONL: text)
    }
}
