@testable import LoomAgents
import Foundation
import LoomCore
import Testing

@Suite("ClaudeSubagents — a sub-agent's own conversation")
struct ClaudeSubagentsTests {
    private let call = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Find the flaky test","subagent_type":"Explore","prompt":"Look for the test that fails one run in ten."}}]}}"#
    private let result = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"LoginTests."}]},"toolUseResult":{"agentId":"abc","totalToolUseCount":7,"totalDurationMs":61000}}"#

    @Test("a call that starts a sub-agent carries its brief; its result names the sub-agent")
    func agentCall() throws {
        var entries = ClaudeConversation.entries(fromJSONL: call)
        guard case .tool(let running) = try #require(entries.first).kind else {
            Issue.record("not a tool call")
            return
        }
        #expect(running.agent == ConversationEntry.AgentCall(
            description: "Find the flaky test", type: "Explore",
            prompt: "Look for the test that fails one run in ten."))
        entries = ClaudeConversation.entries(fromJSONL: call + "\n" + result)
        guard case .tool(let done) = try #require(entries.first).kind else { return }
        #expect(done.agent?.agentID == "abc" && done.agent?.toolUses == 7 && done.agent?.durationMs == 61_000)
        #expect(done.result == "LoginTests.")
    }

    @Test("an ordinary tool call starts no sub-agent")
    func plainCall() throws {
        let line = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        guard case .tool(let found) = try #require(ClaudeConversation.entries(fromJSONL: line).first).kind else { return }
        #expect(found.agent == nil)
    }

    @Test("the sub-agent's file is found by its id, or by its brief while it runs, and read without the brief")
    func transcript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-subagents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("0000.jsonl")
        let folder = ClaudeSubagents.folder(forSessionFile: session)
        // One beside the session, one a workflow started: a folder deeper.
        let deep = folder.appendingPathComponent("workflows/wf_1")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","isSidechain":true,"agentId":"abc","uuid":"s1","message":{"role":"user","content":"Look for the test that fails one run in ten."}}"#,
            #"{"type":"assistant","isSidechain":true,"agentId":"abc","uuid":"s2","message":{"role":"assistant","content":[{"type":"tool_use","id":"x1","name":"Grep","input":{"pattern":"flaky"}}]}}"#,
            #"{"type":"user","isSidechain":true,"agentId":"abc","uuid":"s3","message":{"role":"user","content":[{"tool_use_id":"x1","type":"tool_result","content":"LoginTests.swift"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"agentId":"abc","uuid":"s4","message":{"role":"assistant","content":[{"type":"text","text":"LoginTests."}]}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: folder.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"Explore","description":"Find the flaky test"}"#
            .write(to: folder.appendingPathComponent("agent-abc.meta.json"), atomically: true, encoding: .utf8)
        try #"{"type":"user","isSidechain":true,"uuid":"w1","message":{"role":"user","content":"Another brief."}}"#
            .write(to: deep.appendingPathComponent("agent-def.jsonl"), atomically: true, encoding: .utf8)

        let agents = ClaudeSubagents.list(forSessionFile: session)
        #expect(Set(agents.map(\.id)) == ["abc", "def"])
        let abc = try #require(agents.first { $0.id == "abc" })
        #expect(abc.description == "Find the flaky test" && abc.type == "Explore")
        #expect(abc.prompt == "Look for the test that fails one run in ten.")

        // By its id, once the result is in; by its brief, while it runs.
        var asked = ConversationEntry.AgentCall(description: "", type: "", prompt: "Look for the test that fails one run in ten.")
        #expect(ClaudeSubagents.find(asked, in: agents)?.id == "abc")
        asked.prompt = "Something else"
        #expect(ClaudeSubagents.find(asked, in: agents) == nil)
        asked.agentID = "def"
        #expect(ClaudeSubagents.find(asked, in: agents)?.id == "def")

        let entries = try #require(ClaudeSubagents.transcript(
            of: ConversationEntry.AgentCall(description: "", type: "", prompt: "", agentID: "abc"),
            sessionFile: session))
        #expect(entries.count == 2, "the brief is the call's, not a row of the sub-agent")
        guard case .tool(let grep) = entries[0].kind else {
            Issue.record("the sub-agent's tool call is its first row")
            return
        }
        #expect(grep.result == "LoginTests.swift")
        #expect(entries[1].kind == .assistant("LoginTests."))
    }
}
