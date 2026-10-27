import Testing
import LoomAgents
import LoomCore
import Foundation

// The native conversations on disk, indexed in one walk: what a cold launch
// consults once instead of walking every project slug per persisted session.

@Suite("ClaudeNativeSessions — index")
struct ClaudeNativeSessionsIndexTests {

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

// What a visible step said, read back for its workflow's orchestrator (ADR-0018).
@Suite("ClaudeNativeSessions — what the assistant said")
struct ClaudeNativeSessionsAssistantTests {

    private static let lines = [
        #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"First answer."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
        "not json",
        #"{"type":"assistant","message":{"content":"Plain string."}}"#,
    ]

    @Test("only the assistant's text, in order: no thinking, no tool call, no noise")
    func textes() {
        #expect(ClaudeNativeSessions.assistantTexts(fromJSONL: Self.lines.joined(separator: "\n"))
                == ["First answer.", "Plain string."])
    }

    @Test("after an offset: only what was written since")
    func depuis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = SessionID()
        let dir = root.appendingPathComponent("-Users-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(id.rawValue.uuidString.lowercased() + ".jsonl")
        try (Self.lines[1] + "\n").write(to: file, atomically: true, encoding: .utf8)
        let offset = ClaudeNativeSessions.size(for: id, projectsDirectory: root)
        #expect(offset > 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.lines[4] + "\n").utf8))
        try handle.close()
        #expect(ClaudeNativeSessions.assistantTexts(for: id, after: offset, projectsDirectory: root) == ["Plain string."])
        #expect(ClaudeNativeSessions.assistantTexts(for: id, projectsDirectory: root).count == 2)
        #expect(ClaudeNativeSessions.assistantTexts(for: SessionID(), projectsDirectory: root).isEmpty)
    }
}
