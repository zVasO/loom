import Testing
import LoomAgents
import LoomCore
import Foundation

// Seam: the adapter's public interface. Expectations come from the official CLI
// documentation (docs/research/claude-code-hooks.md), not from the code.

@Suite("ClaudeCodeAdapter — translation to the CLI")
struct ClaudeCodeAdapterTests {

    @Test("launch imposes the session UUID: Resume is deterministic")
    func lancementImposeLUuid() {
        let id = SessionID()
        let adapter = ClaudeCodeAdapter()
        let command = adapter.launchCommand(session: id, initialPrompt: "fix the cache bug")

        #expect(command.executable == "claude")
        #expect(command.arguments.contains("--session-id"))
        #expect(command.arguments.contains(id.rawValue.uuidString),
                "the ID is imposed at launch — no more crash window before SessionStart (research §5)")
        #expect(command.arguments.last == "fix the cache bug", "the initial prompt is passed as an argument")
    }

    @Test("hooks are injected via inline --settings, never into global settings (STA-01)")
    func hooksInjectesParSettings() throws {
        let wiring = ClaudeCodeAdapter.HookWiring(
            helper: URL(fileURLWithPath: "/Library/Application Support/Loom/loom-hook"),
            socket: URL(fileURLWithPath: "/tmp/loom.sock"))
        let adapter = ClaudeCodeAdapter(hooks: wiring)
        let command = adapter.launchCommand(session: SessionID(), initialPrompt: nil,
                                            hookToken: "secret-token-42")

        guard let flagIndex = command.arguments.firstIndex(of: "--settings"),
              command.arguments.indices.contains(flagIndex + 1) else {
            Issue.record("--settings missing from the command")
            return
        }
        let json = try #require(command.arguments[flagIndex + 1].data(using: .utf8))
        let settings = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])

        for event in ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"] {
            let entries = try #require(hooks[event] as? [[String: Any]], "hook \(event) missing")
            let hookList = try #require(entries.first?["hooks"] as? [[String: Any]])
            let commandLine = try #require(hookList.first?["command"] as? String)
            #expect(commandLine.contains("loom-hook"), "the \(event) command calls the helper binary")
            #expect(commandLine.contains("secret-token-42"), "the session token travels with \(event)")
            #expect(commandLine.contains("/tmp/loom.sock"), "the \(event) helper knows the socket")
        }
    }

    @Test("Resume relaunches the native session by its UUID (UC-7)")
    func repriseParUuid() {
        let id = SessionID()
        let command = ClaudeCodeAdapter().resumeCommand(session: id)
        #expect(command.executable == "claude")
        #expect(command.arguments == ["--resume", id.rawValue.uuidString])
    }

    @Test("Resume re-injects the hooks: the resumed session stays observed")
    func repriseAvecHooks() {
        let adapter = ClaudeCodeAdapter(hooks: .init(
            helper: URL(fileURLWithPath: "/tmp/loom-hook"),
            socket: URL(fileURLWithPath: "/tmp/loom.sock")))
        let command = adapter.resumeCommand(session: SessionID(), hookToken: "resume-token")
        #expect(command.arguments.contains("--settings"),
                "without re-injected hooks, the resumed session would be blind to state detection")
    }

    @Test("hook payloads become reducer events (STA-01)")
    func payloadsDeviennentDesEvenements() throws {
        func payload(_ fields: [String: Any]) -> Data {
            var base: [String: Any] = ["session_id": "abc", "cwd": "/tmp"]
            base.merge(fields) { _, new in new }
            return try! JSONSerialization.data(withJSONObject: base)
        }

        #expect(ClaudeCodeAdapter.interpret(payload(["hook_event_name": "UserPromptSubmit"]))
                == .hook(.userPromptSubmit))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Stop",
            "last_assistant_message": "We have two options here. Which one do you prefer?",
        ])) == .hook(.stop(awaitsReply: true)), "Stop + question = needs_input, via the classifier")
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Stop",
            "last_assistant_message": "Fix applied, tests green.",
        ])) == .hook(.stop(awaitsReply: false)))
        #expect(ClaudeCodeAdapter.interpret(payload(["hook_event_name": "PermissionRequest"]))
                == .hook(.permissionRequested))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Notification", "notification_type": "permission_prompt",
        ])) == .hook(.permissionRequested))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Notification", "notification_type": "auth_success",
        ])) == nil, "a notification with no state value is ignored")
        #expect(ClaudeCodeAdapter.interpret(Data("not json".utf8)) == nil,
                "a corrupted payload never produces a transition")
    }
}
