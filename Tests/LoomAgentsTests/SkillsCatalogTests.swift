import Testing
import LoomAgents
import Foundation

// SKL-01/02/03 : scan des skills aux deux portées, frontmatter parsé avec repli
// gracieux, le projet masque le global à nom égal.

@Suite("SkillsCatalog — skills projet + globaux")
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

    @Test("le frontmatter donne nom et description")
    func frontmatterParse() throws {
        let global = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: Déploie sur la préproduction\n---\n# Deploy"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: nil)
        #expect(entries == [SkillEntry(name: "deploy",
                                       description: "Déploie sur la préproduction",
                                       scope: .global)])
    }

    @Test("un SKILL.md mal formé apparaît quand même : nom = dossier (SKL-02)")
    func repliGracieux() throws {
        let global = try makeSkillsDir([
            ("casse", "pas de frontmatter ici"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: nil)
        #expect(entries.first?.name == "casse", "jamais d'écran vide silencieux")
        #expect(entries.first?.description == "")
    }

    @Test("le skill projet masque le global à nom égal, et passe devant (SKL-03)")
    func shadowingProjet() throws {
        let global = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: version globale\n---"),
            ("lint", "---\nname: lint\ndescription: global seul\n---"),
        ])
        let project = try makeSkillsDir([
            ("deploy", "---\nname: deploy\ndescription: version projet\n---"),
        ])
        let entries = SkillsCatalog.scan(globalDirectory: global, projectDirectory: project)
        #expect(entries.map(\.name) == ["deploy", "lint"], "projet d'abord")
        #expect(entries.first?.description == "version projet", "le projet prime")
        #expect(entries.first?.scope == .project)
    }
}
