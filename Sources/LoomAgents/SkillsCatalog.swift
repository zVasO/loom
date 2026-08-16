import Foundation

public struct SkillEntry: Equatable, Sendable {
    public enum Scope: Sendable {
        case global, project
    }
    public let name: String
    public let description: String
    public let scope: Scope
    /// The SKILL.md on disk — for opening it in the app.
    public let path: URL?

    public init(name: String, description: String, scope: Scope, path: URL? = nil) {
        self.name = name
        self.description = description
        self.scope = scope
        self.path = path
    }
}

/// SKL-01/02/03: scan of the skills directories (`<dir>/*/SKILL.md`) at both scopes.
/// The filesystem is the source of truth — no cache, every scan re-reads.
/// Minimal frontmatter (name/description) with graceful fallback: a malformed
/// SKILL.md still shows up, name = folder (SKL-02).
public enum SkillsCatalog {

    public static var defaultGlobalDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills")
    }

    /// Project first; on equal names, project shadows global (SKL-03).
    public static func scan(globalDirectory: URL?, projectDirectory: URL?) -> [SkillEntry] {
        let project = projectDirectory.map { entries(in: $0, scope: .project) } ?? []
        let global = globalDirectory.map { entries(in: $0, scope: .global) } ?? []
        let shadowed = Set(project.map(\.name))
        return project + global.filter { !shadowed.contains($0.name) }
    }

    private static func entries(in directory: URL, scope: SkillEntry.Scope) -> [SkillEntry] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folder in
                let skillFile = folder.appendingPathComponent("SKILL.md")
                guard manager.fileExists(atPath: skillFile.path) else { return nil }
                let content = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                let front = frontmatter(of: content)
                return SkillEntry(name: front["name"] ?? folder.lastPathComponent,
                                  description: front["description"] ?? "",
                                  scope: scope,
                                  path: skillFile)
            }
            .sorted { $0.name < $1.name }
    }

    /// Minimal YAML: single-line `key: value` pairs, between the first two `---`.
    private static func frontmatter(of content: String) -> [String: String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}
