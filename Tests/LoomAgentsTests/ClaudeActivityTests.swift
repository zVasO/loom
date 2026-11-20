@testable import LoomAgents
import Foundation
import LoomCore
import Testing

@Suite("ClaudeActivity — what a session reached for")
struct ClaudeActivityTests {
    private func use(_ id: String, _ name: String, _ input: String = "{}", day: String = "2026-11-19") -> String {
        #"{"type":"assistant","timestamp":"\#(day)T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func result(_ id: String, failed: Bool) -> String {
        #"{"type":"user","timestamp":"2026-11-19T10:00:01.000Z","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"…","is_error":\#(failed)}]}}"#
    }

    @Test("tool calls sort into MCP servers, skills, sub-agents and plain tools; a failed result counts against its call")
    func calls() {
        let text = [
            use("t1", "Bash", #"{"command":"ls"}"#),
            use("t2", "Bash", #"{"command":"false"}"#),
            result("t2", failed: true),
            use("t3", "mcp__github__actions_list"),
            use("t4", "mcp__github__get_job_logs"),
            use("t5", "mcp__github__actions_list"),
            result("t5", failed: true),
            use("t6", "mcp__Google_Drive__search_files"),
            use("t7", "Skill", #"{"skill":"dataviz"}"#),
            use("t8", "Agent", #"{"subagent_type":"Explore","prompt":"…"}"#),
            use("t9", "Task", #"{"prompt":"…"}"#),
            // Written again by a resumed conversation: counted once.
            use("t1", "Bash", #"{"command":"ls"}"#),
        ].joined(separator: "\n")
        let tally = ClaudeActivity.activity(fromJSONL: text).tally()
        #expect(tally.lines(.tool) == [.init(name: "Bash", runs: 2, failures: 1)])
        #expect(tally.total(.mcp) == 4)
        #expect(tally.servers == [
            .init(name: "github", runs: 3, failures: 1, children: [
                .init(name: "actions_list", runs: 2, failures: 1),
                .init(name: "get_job_logs", runs: 1, failures: 0),
            ]),
            .init(name: "Google_Drive", runs: 1, failures: 0, children: [
                .init(name: "search_files", runs: 1, failures: 0),
            ]),
        ])
        #expect(tally.lines(.skill).map(\.name) == ["dataviz"])
        #expect(tally.lines(.agent).map(\.name) == ["Explore", "general-purpose"])
    }

    @Test("a slash command typed is a command; a skill's echo is not counted twice, a skill called by name is")
    func commands() {
        let echo = #"{"type":"user","timestamp":"2026-11-19T10:00:02.000Z","message":{"role":"user","content":"<command-message>dataviz</command-message>\n<command-name>dataviz</command-name>\n<skill-format>true</skill-format>"}}"#
        let typed = #"{"type":"user","timestamp":"2026-11-19T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"<command-name>/review</command-name>\n<command-args>42</command-args>"}]}}"#
        let quoted = #"{"type":"user","timestamp":"2026-11-19T10:00:04.000Z","message":{"role":"user","content":"What does <command-name>/x</command-name> mean?"}}"#
        let text = [use("t1", "Skill", #"{"skill":"dataviz"}"#), echo, echo, typed, quoted].joined(separator: "\n")
        let tally = ClaudeActivity.activity(fromJSONL: text).tally()
        #expect(tally.lines(.skill) == [.init(name: "dataviz", runs: 2, failures: 0)],
                "loaded once by the model, called once by name")
        #expect(tally.lines(.command) == [.init(name: "/review", runs: 1, failures: 0)])
    }

    @Test("hooks: the Stop summary, an attachment, a progress line then its outcome")
    func hooks() {
        let stop = #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-11-19T10:00:05.000Z","toolUseID":"s1","hookCount":1,"hookInfos":[{"command":"scripts/check.sh"}],"hookErrors":["nope"]}"#
        let anonymous = #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-11-19T10:00:06.000Z","toolUseID":"s2","hookCount":1,"hookInfos":[{"command":"command hook"}],"hookErrors":[]}"#
        let started = #"{"type":"progress","timestamp":"2026-11-19T10:00:07.000Z","toolUseID":"p1","data":{"type":"hook_progress","hookEvent":"PostToolUse","hookName":"PostToolUse:Edit","command":"swiftformat"}}"#
        let ended = #"{"type":"attachment","timestamp":"2026-11-19T10:00:08.000Z","attachment":{"type":"hook_non_blocking_error","hookName":"PostToolUse:Edit","toolUseID":"p1","command":"swiftformat"}}"#
        let alone = #"{"type":"attachment","timestamp":"2026-11-19T10:00:09.000Z","attachment":{"type":"hook_success","hookName":"SessionStart:startup","toolUseID":"a1"}}"#
        let tally = ClaudeActivity.activity(fromJSONL: [stop, stop, anonymous, started, ended, alone].joined(separator: "\n")).tally()
        #expect(tally.lines(.hook) == [
            .init(name: "PostToolUse:Edit · swiftformat", runs: 1, failures: 1),
            .init(name: "SessionStart:startup", runs: 1, failures: 0),
            .init(name: "Stop", runs: 1, failures: 0),
            .init(name: "Stop · scripts/check.sh", runs: 1, failures: 1),
        ])
    }

    @Test("what was offered and never called; the days of a window")
    func offeredAndWindow() {
        let skills = #"{"type":"attachment","timestamp":"2026-11-01T09:00:00.000Z","attachment":{"type":"skill_listing","names":["dataviz","pdf"]}}"#
        let tools = #"{"type":"attachment","timestamp":"2026-11-01T09:00:00.000Z","attachment":{"type":"deferred_tools_delta","addedNames":["WebSearch","mcp__github__actions_list","mcp__Linear__list_issues"]}}"#
        let servers = #"{"type":"attachment","timestamp":"2026-11-01T09:00:00.000Z","attachment":{"type":"mcp_instructions_delta","addedNames":["Google_Drive"]}}"#
        let text = [
            skills, tools, servers,
            use("t1", "Skill", #"{"skill":"dataviz"}"#, day: "2026-11-01"),
            use("t2", "mcp__github__actions_list", day: "2026-11-19"),
        ].joined(separator: "\n")
        let activity = ClaudeActivity.activity(fromJSONL: text)
        let all = activity.tally()
        #expect(all.unusedSkills == ["pdf"])
        #expect(all.unusedServers == ["Google_Drive", "Linear"])
        let recent = activity.tally(since: "2026-11-10")
        #expect(recent.total(.skill) == 0 && recent.total(.mcp) == 1)
        #expect(recent.unusedSkills == ["dataviz", "pdf"], "offered last month, not called in the window")
        #expect(activity.tally(since: "2026-12-01").isEmpty)
    }

    @Test("a session's sub-agents count with it, and the overview sums the sessions of the window")
    func files() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-Users-ada-loom")
        let session = project.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        let agents = ClaudeSubagents.folder(forSessionFile: session).appendingPathComponent("workflows/wf_1")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let today = ClaudeActivity.day(Date())
        try (use("t1", "Agent", #"{"subagent_type":"Explore","prompt":"…"}"#, day: today) + "\n")
            .write(to: session, atomically: true, encoding: .utf8)
        try (use("x1", "Grep", day: today) + "\n" + use("x2", "mcp__github__get_commit", day: today) + "\n")
            .write(to: agents.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)
        let other = project.appendingPathComponent("22222222-2222-4222-8222-222222222222.jsonl")
        try (use("o1", "Grep", day: today) + "\n" + use("o2", "Read", day: "2020-01-01") + "\n")
            .write(to: other, atomically: true, encoding: .utf8)

        let id = SessionID(try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")))
        let tally = try #require(ClaudeActivity.tally(for: id, projectsDirectory: root))
        #expect(tally.total(.agent) == 1 && tally.total(.tool) == 1 && tally.total(.mcp) == 1)

        let overview = ClaudeActivity.overview(lastDays: 7, projectsDirectory: root)
        #expect(overview.sessions == 2)
        #expect(overview.tally.lines(.tool) == [.init(name: "Grep", runs: 2, failures: 0)],
                "the Read of 2020 is outside the window")
    }
}
