import Testing
import LoomAgents
import Foundation

// SKL-01/02/03: skills scanned at both scopes, frontmatter parsed with graceful
// fallback, project shadows global on equal names.

@Suite("SkillsCatalog — project + global skills")
struct SkillsCatalogTests {

    private func makeSkillsDir(_ skills: [(folder: String, content: String?)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-skills-\(UUID().uuidString.prefix(8))")
        for skill in skills {
            let folder = dir.appendingPathComponent(skill.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let content = skill.content {
                try content.write(to: folder.appendingPathComponent("SKILL.md"),
                                  atomically: true, encoding: .utf8)
            }
        }
        return dir
    }

    @Test("frontmatter yields name and description")
    func frontmatterParse() throws {
        let global = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: Deploys to staging\n---\n# Deploy"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "deploy")
        #expect(entries.first?.description == "Deploys to staging")
        #expect(entries.first?.scope == .global)
        // The SKILL.md path is exposed: the app opens it in its reader.
        #expect(entries.first?.path?.lastPathComponent == "SKILL.md")
    }

    @Test("a malformed SKILL.md still shows up: name = folder (SKL-02)")
    func repliGracieux() throws {
        let global = try makeSkillsDir([
            ("broken", "no frontmatter here"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: nil)
        #expect(entries.first?.name == "broken", "never a silently empty screen")
        #expect(entries.first?.description == "")
    }

    @Test("the project skill shadows the global one on equal names, and sorts first (SKL-03)")
    func shadowingProjet() throws {
        let global = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: global version\n---"),
            ("lint", "---\nname: lint\ndescription: global only\n---"),
        ])
        let project = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: project version\n---"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: project)
        #expect(entries.map(\.name) == ["deploy", "lint"], "project first")
        #expect(entries.first?.description == "project version", "the project wins")
        #expect(entries.first?.scope == .project)
    }
}
