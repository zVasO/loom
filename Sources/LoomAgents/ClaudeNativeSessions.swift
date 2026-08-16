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
        let target = id.rawValue.uuidString.lowercased() + ".jsonl"
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: projectsDirectory,
                                                              includingPropertiesForKeys: nil) else {
            return false
        }
        for project in projects {
            let candidates = (try? manager.contentsOfDirectory(at: project,
                                                               includingPropertiesForKeys: nil)) ?? []
            if candidates.contains(where: { $0.lastPathComponent.lowercased() == target }) {
                return true
            }
        }
        return false
    }
}
