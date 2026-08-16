import Testing
import BunshinAgents
import Foundation

// UIX-06 : le diagnostic guidé « Claude Code est-il installé ? » — recherche dans
// un PATH donné + emplacements connus, pur et testable avec de faux binaires.

@Suite("ClaudeLocator — diagnostic d'installation")
struct ClaudeLocatorTests {

    private func makeFakeClaude() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-locator-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho ok".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    @Test("trouvé dans le PATH fourni")
    func trouveDansLePath() throws {
        let binary = try makeFakeClaude()
        let path = binary.deletingLastPathComponent().path + ":/usr/bin"
        #expect(ClaudeLocator.locate(searchPath: path) == binary)
    }

    @Test("absent : nil, avec les emplacements cherchés pour le diagnostic guidé")
    func absent() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-vide-\(UUID().uuidString.prefix(8))").path
        #expect(ClaudeLocator.locate(searchPath: empty, extraLocations: []) == nil)
        #expect(!ClaudeLocator.wellKnownLocations.isEmpty,
                "le diagnostic doit pouvoir dire OÙ il a cherché")
    }

    @Test("un dossier nommé claude n'est pas un binaire")
    func dossierHomonyme() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-homonyme-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude"),
                                                withIntermediateDirectories: true)
        #expect(ClaudeLocator.locate(searchPath: dir.path, extraLocations: []) == nil)
    }
}
