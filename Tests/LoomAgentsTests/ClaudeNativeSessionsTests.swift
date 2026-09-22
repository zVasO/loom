import Testing
import LoomAgents
import LoomCore
import Foundation

// The native conversations on disk, indexed in one walk: what a cold launch
// consults once instead of walking every project slug per persisted session.

@Suite("ClaudeNativeSessions — index")
struct ClaudeNativeSessionsTests {

    private func makeTree() throws -> (root: URL, present: SessionID, absent: SessionID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-native-\(UUID().uuidString)")
        let present = SessionID()
        let absent = SessionID()
        for slug in ["-Users-x-a", "-Users-x-b", "-Users-x-c"] {
            let dir = root.appendingPathComponent(slug)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"),
                           atomically: true, encoding: .utf8)
            try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        }
        // Stored UPPERCASE on purpose: the index must not care.
        try "{}".write(to: root.appendingPathComponent("-Users-x-b")
                           .appendingPathComponent("\(present.rawValue.uuidString.uppercased()).JSONL"),
                       atomically: true, encoding: .utf8)
        return (root, present, absent)
    }

    @Test("the index lists every .jsonl under every slug, case-insensitively, and nothing else")
    func indexListeToutesLesConversations() throws {
        let (root, present, absent) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ClaudeNativeSessions.index(projectsDirectory: root)
        #expect(index.count == 4, "three random conversations plus the one we look for")
        #expect(ClaudeNativeSessions.contains(index, present))
        #expect(!ClaudeNativeSessions.contains(index, absent))
        #expect(!index.contains("notes"), "only conversations, whatever else a slug holds")
        #expect(ClaudeNativeSessions.exists(present, projectsDirectory: root),
                "the index and the per-session lookup agree")
    }

    @Test("a missing projects directory is an empty index, not an error")
    func repertoireAbsent() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nowhere-\(UUID().uuidString)")
        #expect(ClaudeNativeSessions.index(projectsDirectory: missing).isEmpty)
    }
}
