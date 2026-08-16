import Testing
import LoomAgents
import LoomCore
import Foundation

// UIX-06: the guided "is Claude Code installed?" diagnostic — searches a given
// PATH + well-known locations, pure and testable with fake binaries.

@Suite("ClaudeLocator — install diagnostic")
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

    @Test("found in the provided PATH")
    func trouveDansLePath() throws {
        let binary = try makeFakeClaude()
        let path = binary.deletingLastPathComponent().path + ":/usr/bin"
        #expect(ClaudeLocator.locate(searchPath: path) == binary)
    }

    @Test("absent: nil, with the searched locations for the guided diagnostic")
    func absent() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-empty-\(UUID().uuidString.prefix(8))").path
        #expect(ClaudeLocator.locate(searchPath: empty, extraLocations: []) == nil)
        #expect(!ClaudeLocator.wellKnownLocations.isEmpty,
                "the diagnostic must be able to say WHERE it looked")
    }

    @Test("a directory named claude is not a binary")
    func dossierHomonyme() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-namesake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude"),
                                                withIntermediateDirectories: true)
        #expect(ClaudeLocator.locate(searchPath: dir.path, extraLocations: []) == nil)
    }
}

@Suite("ClaudeNativeSessions — Resume knows whether claude has anything to resume")
struct ClaudeNativeSessionsTests {

    @Test("a native session exists if its .jsonl is in a claude project")
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
                "a never-persisted UUID → nothing to resume → must relaunch fresh")
    }

    @Test("UUID case does not matter")
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
