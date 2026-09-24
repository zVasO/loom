import Testing
import LoomAgents
import LoomCore
import Foundation

// Claude tells the context window to its status line only. Loom's relay
// forwards it, then runs the user's own line — resolved here with claude's
// precedence, since Loom's inline one hides every other source.

@Suite("ClaudeStatusLine — the user's line, and what claude reports")
struct ClaudeStatusLineTests {

    /// A project and a config directory in a temp tree, removed afterwards.
    private func withTree(_ body: (_ project: URL, _ config: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-statusline-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try body(project, config)
    }

    private func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    @Test("project local wins over project, which wins over the user's settings")
    func precedence() throws {
        try withTree { project, config in
            try write(#"{"statusLine":{"type":"command","command":"user.sh","padding":1}}"#,
                      to: config.appendingPathComponent("settings.json"))
            #expect(ClaudeStatusLine.user(cwd: project, configDirectory: config)
                    == ClaudeStatusLine.UserCommand(command: "user.sh", padding: 1))

            try write(#"{"statusLine":{"type":"command","command":"project.sh"}}"#,
                      to: project.appendingPathComponent(".claude/settings.json"))
            #expect(ClaudeStatusLine.user(cwd: project, configDirectory: config)?.command == "project.sh")

            try write(#"{"statusLine":{"type":"command","command":"local.sh","refreshInterval":5}}"#,
                      to: project.appendingPathComponent(".claude/settings.local.json"))
            #expect(ClaudeStatusLine.user(cwd: project, configDirectory: config)
                    == ClaudeStatusLine.UserCommand(command: "local.sh", refreshInterval: 5))
        }
    }

    @Test("a source without a status line is skipped; none at all gives nil")
    func sansStatusLine() throws {
        try withTree { project, config in
            #expect(ClaudeStatusLine.user(cwd: project, configDirectory: config) == nil)
            try write(#"{"model":"opus"}"#, to: project.appendingPathComponent(".claude/settings.json"))
            try write(#"{"statusLine":{"type":"command","command":"user.sh"}}"#,
                      to: config.appendingPathComponent("settings.json"))
            #expect(ClaudeStatusLine.user(cwd: project, configDirectory: config)?.command == "user.sh")
        }
    }

    @Test("the forwarded update gives the window claude uses, and the model")
    func rapport() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "LoomStatusLine",
            "model": ["id": "claude-opus-5-5", "display_name": "Opus 5.5"],
            "context_window": ["context_window_size": 1_000_000, "used_percentage": 35],
        ])
        #expect(ClaudeStatusLine.report(from: payload)
                == ClaudeStatusLine.Report(modelID: "claude-opus-5-5", windowTokens: 1_000_000))
    }

    @Test("a hook payload, or an update without a window, is not a report")
    func pasUnRapport() throws {
        let hook = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "context_window": ["context_window_size": 1_000_000],
        ])
        #expect(ClaudeStatusLine.report(from: hook) == nil)
        let bare = try JSONSerialization.data(withJSONObject: ["hook_event_name": "LoomStatusLine"])
        #expect(ClaudeStatusLine.report(from: bare) == nil)
    }
}
