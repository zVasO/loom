import Testing
import LoomAgents
import LoomCore
import Foundation

// UIX-06 : le diagnostic guidé « Claude Code est-il installé ? » — recherche dans
// un PATH donné + emplacements connus, pur et testable avec de faux binaires.

@Suite("ClaudeLocator — diagnostic d'installation")
struct ClaudeLocatorTests {

    private func makeFakeClaude() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-locator-\(UUID().uuidString.prefix(8))")
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
            .appendingPathComponent("loom-vide-\(UUID().uuidString.prefix(8))").path
        #expect(ClaudeLocator.locate(searchPath: empty, extraLocations: []) == nil)
        #expect(!ClaudeLocator.wellKnownLocations.isEmpty,
                "le diagnostic doit pouvoir dire OÙ il a cherché")
    }

    @Test("un dossier nommé claude n'est pas un binaire")
    func dossierHomonyme() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-homonyme-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude"),
                                                withIntermediateDirectories: true)
        #expect(ClaudeLocator.locate(searchPath: dir.path, extraLocations: []) == nil)
    }
}

@Suite("ClaudeNativeSessions — la Reprise sait si claude a quelque chose à reprendre")
struct ClaudeNativeSessionsTests {

    @Test("une session native existe si son .jsonl est dans un projet claude")
    func detectionDeSessionNative() throws {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-native-\(UUID().uuidString.prefix(8))")
        let project = projects.appendingPathComponent("-Users-x-repo-worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = SessionID()
        FileManager.default.createFile(
            atPath: project.appendingPathComponent("\(id.rawValue.uuidString).jsonl").path,
            contents: Data("{}".utf8))

        #expect(ClaudeNativeSessions.exists(id, projectsDirectory: projects))
        #expect(!ClaudeNativeSessions.exists(SessionID(), projectsDirectory: projects),
                "un UUID jamais persisté → rien à reprendre → il faut relancer à neuf")
    }

    @Test("la casse de l'UUID ne compte pas")
    func casseIgnoree() throws {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-native-\(UUID().uuidString.prefix(8))")
        let project = projects.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = SessionID()
        FileManager.default.createFile(
            atPath: project.appendingPathComponent("\(id.rawValue.uuidString.lowercased()).jsonl").path,
            contents: Data("{}".utf8))
        #expect(ClaudeNativeSessions.exists(id, projectsDirectory: projects))
    }
}
