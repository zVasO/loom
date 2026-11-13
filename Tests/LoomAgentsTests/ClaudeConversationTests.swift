import Testing
import LoomAgents
import LoomCore
import Foundation

// Seam: the pure parser behind the chat view — claude's native .jsonl in, the
// conversation's entries out. The fixtures reproduce the shape claude writes
// (one line per content block, a tool's result in a later user line); their
// content is invented.

/// Each entry as one line — what it is, then what it says: the tests compare
/// the order and the text without spelling out every field.
private func outline(_ lines: [String]) -> [String] {
    ClaudeConversation.entries(fromJSONL: lines.joined(separator: "\n")).map { entry -> String in
        switch entry.kind {
        case .user(let text): return "user: " + text
        case .assistant(let text): return "assistant: " + text
        case .thinking(let text): return "thinking: " + text
        case .tool(let call): return "tool: " + call.summary
        case .notice(let text): return "notice: " + text
        }
    }
}

private func calls(_ entries: [ConversationEntry]) -> [ConversationEntry.ToolCall] {
    entries.compactMap { entry -> ConversationEntry.ToolCall? in
        if case .tool(let call) = entry.kind { return call }
        return nil
    }
}

/// A Swift string as a JSON string, quotes and escapes included.
private func json(_ text: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}

/// A tool call as claude writes it: an assistant line of one block.
private func toolUse(_ name: String, _ input: String, id: String = "t1", uuid: String = "a-call") -> String {
    #"{"type":"assistant","uuid":"\#(uuid)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
}

/// Its answer: a user line that holds no message.
private func toolResult(_ content: String, id: String = "t1", uuid: String = "u-result", error: Bool = false) -> String {
    #"{"type":"user","uuid":"\#(uuid)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":\#(content),"is_error":\#(error)}]}}"#
}

@Suite("ClaudeConversation — what was said")
struct ClaudeConversationTests {

    @Test("a message and its answer, in order, each with its time; noise is skipped")
    func echange() {
        let entries = ClaudeConversation.entries(fromJSONL: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-03T09:15:02.481Z","message":{"role":"user","content":"Rename the helper."}}"#,
            "not json",
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-03T09:15:07Z","message":{"content":[{"type":"text","text":"\nDone: it is **renamed**.\n"}]}}"#,
        ].joined(separator: "\n"))
        #expect(entries.map(\.kind) == [.user("Rename the helper."), .assistant("Done: it is **renamed**.")])
        #expect(entries.map(\.id) == ["u1#0", "a1#0"])
        #expect(entries.compactMap(\.timestamp).count == 2, "with fractional seconds or without")
    }

    @Test("the blocks of an answer in the order claude wrote them; an empty thinking block is nothing")
    func blocsDansLOrdre() {
        #expect(outline([
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"The helper has two callers.","signature":"s"},{"type":"text","text":"I will rename it."},{"type":"tool_use","id":"t1","name":"Glob","input":{"pattern":"**/*.swift"}}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"thinking","thinking":"","signature":"s"}]}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"text","text":"First."}]}}"#,
            #"{"type":"assistant","uuid":"a4","message":{"content":"Second, as a plain string."}}"#,
        ]) == [
            "thinking: The helper has two callers.",
            "assistant: I will rename it.",
            "tool: Glob **/*.swift",
            "assistant: First.",
            "assistant: Second, as a plain string.",
        ])
    }

    @Test("what claude code slips into a message for claude alone is not the user's text")
    func rappelsRetires() {
        #expect(outline([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"<system-reminder>\nToday is Tuesday.\n</system-reminder>\nShip it.<system-reminder>Be brief.</system-reminder>"}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>Only this.</system-reminder>"}]}}"#,
        ]) == ["user: Ship it."])
    }

    @Test("a slash command and what it printed are notices; one that printed nothing is only the command")
    func commandes() {
        #expect(outline([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>"}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"<local-command-stdout>Set model to \u001b[1mopus\u001b[22m</local-command-stdout>"}}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}"#,
            #"{"type":"user","uuid":"u4","message":{"role":"user","content":"<local-command-stdout></local-command-stdout>"}}"#,
            #"{"type":"user","uuid":"u5","message":{"role":"user","content":"What does <command-name> hold?"}}"#,
        ]) == [
            "notice: /model opus",
            "notice: Set model to opus",
            "notice: /clear",
            "user: What does <command-name> hold?",
        ])
    }

    @Test("what claude code notes for itself and a sub-agent's own exchange are not the conversation")
    func metaEtSousAgents() {
        #expect(outline([
            #"{"type":"user","uuid":"u1","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by local commands."}}"#,
            #"{"type":"user","uuid":"u2","isSidechain":true,"message":{"role":"user","content":"Map the tests."}}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":true,"message":{"content":[{"type":"text","text":"Mapped."}]}}"#,
            #"{"type":"user","uuid":"u3","isSidechain":false,"message":{"role":"user","content":"Go on."}}"#,
        ]) == ["user: Go on."])
    }

    @Test("an interruption is a notice, not something the user said")
    func interruption() {
        #expect(outline([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        ]) == ["notice: Interrupted", "notice: Interrupted"])
    }

    @Test("a compaction is one notice — its boundary and its summary say the same — and the summary is not a message")
    func compaction() {
        let summary = #"{"type":"user","uuid":"u2","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation. The user asked a first question."}}"#
        #expect(outline([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"First question."}}"#,
            #"{"type":"system","uuid":"s1","subtype":"compact_boundary","content":"Conversation compacted"}"#,
            summary,
            #"{"type":"system","uuid":"s2","subtype":"stop_hook_summary","hookCount":1}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":"Second question."}}"#,
        ]) == ["user: First question.", "notice: Conversation compacted", "user: Second question."])
        #expect(outline([summary]) == ["notice: Conversation compacted"], "the summary alone says it too")
    }

    @Test("an image in a message is named, not shown")
    func image() {
        #expect(outline([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"What is wrong here?"}]}}"#,
        ]) == ["user: [image]\nWhat is wrong here?"])
    }

    @Test("a message sent while claude worked is the user's; a background task reporting back is a notice")
    func pendantLeTour() {
        #expect(outline([
            #"{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"Also update the README.","commandMode":"prompt"}}"#,
            #"{"type":"attachment","uuid":"q2","attachment":{"type":"edited_text_file","filename":"/tmp/notes.txt"}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background build finished</summary>\n<result>ok</result>\n</task-notification>"}}"#,
        ]) == ["user: Also update the README.", "notice: Background build finished"])
    }
}

@Suite("ClaudeConversation — tool calls")
struct ClaudeConversationToolTests {

    @Test("a result completes its call, however far back, and is not an entry of its own")
    func resultatApparie() {
        let entries = ClaudeConversation.entries(fromJSONL: [
            toolUse("Bash", #"{"command":"swift build","description":"Build"}"#, id: "t1", uuid: "a1"),
            toolUse("Read", #"{"file_path":"/work/app/Sources/App/Main.swift"}"#, id: "t2", uuid: "a2"),
            #"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"text","text":"Both are running."}]}}"#,
            toolResult(#"[{"type":"text","text":"let x = 1"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]"#, id: "t2", uuid: "u1"),
            toolResult(json("Compiling…\nBuild complete!"), id: "t1", uuid: "u2"),
        ].joined(separator: "\n"))
        #expect(entries.map(\.id) == ["a1#0", "a2#0", "a3#0"])
        let found = calls(entries)
        #expect(found.map { $0.result ?? "running" } == ["Compiling…\nBuild complete!", "let x = 1\n[image]"])
        #expect(found.first?.input == "swift build", "Bash shows the command as typed")
        #expect(found.last?.input.contains("Main.swift") == true, "any other tool, its JSON")
        #expect(found.allSatisfy { !$0.isError })
    }

    @Test("a result that arrives in a later read still finds its call; an error is marked")
    func resultatPlusTard() {
        var reader = ClaudeConversation.Reader()
        let called = reader.consume(toolUse("Bash", #"{"command":"swift test"}"#) + "\n")
        #expect(called)
        #expect(calls(reader.entries).first?.result == nil, "still running")

        let answered = reader.consume(toolResult(json("error: no such module"), error: true) + "\n")
        #expect(answered)
        let call = calls(reader.entries).first
        #expect(call?.result == "error: no such module")
        #expect(call?.isError == true)
        #expect(reader.entries.count == 1)

        let orphan = reader.consume(toolResult(json("late"), id: "unknown", uuid: "u9") + "\n")
        #expect(!orphan, "a result without its call changes nothing")
    }

    @Test("each tool family gets a line a person can read")
    func resumes() {
        #expect(outline([
            toolUse("Read", #"{"file_path":"/work/app/Sources/LoomUI/ThemeStore.swift"}"#, id: "t1", uuid: "a1"),
            toolUse("Edit", #"{"file_path":"notes.md","old_string":"a","new_string":"b"}"#, id: "t2", uuid: "a2"),
            toolUse("Bash", #"{"command":"swift test --filter Usage\necho done","description":"Run the tests"}"#, id: "t3", uuid: "a3"),
            toolUse("Grep", #"{"pattern":"ThemeStore","path":"/work/app/Sources/LoomCore"}"#, id: "t4", uuid: "a4"),
            toolUse("Glob", #"{"pattern":"**/*.swift"}"#, id: "t5", uuid: "a5"),
            toolUse("Task", #"{"description":"Map the tests","prompt":"Read every test file and say what each one covers."}"#, id: "t6", uuid: "a6"),
            toolUse("WebFetch", #"{"url":"https://example.com/docs","prompt":"Summarise"}"#, id: "t7", uuid: "a7"),
            toolUse("WebSearch", #"{"query":"swift testing traits"}"#, id: "t8", uuid: "a8"),
            toolUse("TodoWrite", #"{"todos":[{"content":"a","status":"pending"},{"content":"b","status":"pending"}]}"#, id: "t9", uuid: "a9"),
            toolUse("mcp__loom__browser_open", #"{"url":"https://example.com","background":true}"#, id: "t10", uuid: "a10"),
            toolUse("Skill", #"{"skill":"review"}"#, id: "t11", uuid: "a11"),
            toolUse("ReadNotifications", "{}", id: "t12", uuid: "a12"),
        ]) == [
            "tool: Read Sources/LoomUI/ThemeStore.swift",
            "tool: Edit notes.md",
            "tool: Bash swift test --filter Usage",
            "tool: Grep ThemeStore in app/Sources/LoomCore",
            "tool: Glob **/*.swift",
            "tool: Task Map the tests",
            "tool: WebFetch https://example.com/docs",
            "tool: WebSearch swift testing traits",
            "tool: TodoWrite 2 items",
            "tool: loom · browser_open https://example.com",
            "tool: Skill review",
            "tool: ReadNotifications",
        ])
    }

    @Test("a long input, a long result and a long summary are cut, and the cut is said")
    func plafonds() {
        let command = String(repeating: "x", count: 5_000)
        let output = String(repeating: "y", count: 9_000)
        let entries = ClaudeConversation.entries(fromJSONL: [
            toolUse("Bash", #"{"command":\#(json(command))}"#),
            toolResult(json(output)),
        ].joined(separator: "\n"))
        let call = calls(entries).first
        #expect(call?.input == String(repeating: "x", count: 4_000) + "\n… 1000 more characters")
        #expect(call?.result == String(repeating: "y", count: 8_000) + "\n… 1000 more characters")
        #expect(call?.summary == "Bash " + String(repeating: "x", count: 114) + "…")
    }
}

@Suite("ClaudeConversation.Reader — following a file as it grows")
struct ClaudeConversationReaderTests {

    private static let lines = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-10-03T09:15:02.481Z","message":{"role":"user","content":"Build it."}}"#,
        toolUse("Bash", #"{"command":"swift build"}"#, id: "t1", uuid: "a1"),
        #"{"type":"mode","mode":"default"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Building."}]}}"#,
        toolResult(json("Build complete!"), id: "t1", uuid: "u2"),
        #"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"text","text":"It builds."}]}}"#,
    ]

    @Test("read whole or line by line, a conversation gives the same entries under the same ids")
    func identifiantsStables() {
        let whole = ClaudeConversation.entries(fromJSONL: Self.lines.joined(separator: "\n"))
        var reader = ClaudeConversation.Reader()
        for line in Self.lines { reader.consume(line + "\n") }
        #expect(reader.entries == whole)
        #expect(whole.map(\.id) == ["u1#0", "a1#0", "line-4#1", "a3#0"],
                "the line's uuid and the block's index; the line's number when it has no uuid")
        #expect(calls(whole).first?.result == "Build complete!")
    }

    @Test("a half-written line waits for its end; a file that shrank is read again from the start")
    func suiviDuFichier() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-conversation-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let question = Self.lines[0]
        let answer = Self.lines[5]
        let cut = answer.index(answer.startIndex, offsetBy: 40)
        try Data((question + "\n" + String(answer[..<cut])).utf8).write(to: file)

        var reader = ClaudeConversation.Reader()
        let first = reader.refresh(from: file)
        #expect(first)
        #expect(reader.entries.map(\.id) == ["u1#0"], "the half-written answer is not read yet")
        let idle = reader.refresh(from: file)
        #expect(!idle, "nothing new, nothing changed")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(answer[cut...]) + "\n").utf8))
        try handle.close()
        let grown = reader.refresh(from: file)
        #expect(grown)
        #expect(reader.entries.map(\.id) == ["u1#0", "a3#0"])

        try Data((answer + "\n").utf8).write(to: file)
        let rewritten = reader.refresh(from: file)
        #expect(rewritten)
        #expect(reader.entries.map(\.id) == ["a3#0"], "a shorter file was rewritten: start over")

        let moved = reader.refresh(from: file.appendingPathExtension("absent"))
        #expect(moved, "another file: what was read is dropped")
        #expect(reader.entries.isEmpty)
    }
}
