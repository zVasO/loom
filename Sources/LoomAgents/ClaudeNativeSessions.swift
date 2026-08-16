import LoomCore
import Foundation

/// La Reprise (UC-7) n'a de sens que si claude a persisté une conversation :
/// le fichier natif `<uuid>.jsonl` sous `~/.claude/projects/<slug>/`. S'il n'existe
/// pas (session lancée mais jamais utilisée), `--resume` échouerait — l'appelant
/// relance à neuf sous le MÊME UUID dans le même worktree.
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
