import LoomCore
import Foundation

/// Translates the Loom world to the Claude Code CLI (spec §6.2).
/// Facts verified against the primary source: docs/research/claude-code-hooks.md.
public struct ClaudeCodeAdapter: Sendable {

    /// Wiring of the hooks to the app: helper binary (ADR-0005) and Unix socket.
    /// The token, on the other hand, is PER SESSION — it is passed to `launchCommand`.
    public struct HookWiring: Sendable {
        public var helper: URL
        public var socket: URL
        public init(helper: URL, socket: URL) {
            self.helper = helper
            self.socket = socket
        }
    }

    /// Events we listen to — the subset that carries state detection (STA-01),
    /// verified against the official docs (docs/research/claude-code-hooks.md §1).
    static let hookedEvents = ["SessionStart", "UserPromptSubmit", "Stop",
                               "Notification", "PermissionRequest", "SessionEnd"]

    public var executable: String
    public var hooks: HookWiring?

    public init(executable: String = "claude", hooks: HookWiring? = nil) {
        self.executable = executable
        self.hooks = hooks
    }

    /// The session UUID is IMPOSED on the CLI (`--session-id`): Resume becomes
    /// deterministic, without depending on the SessionStart hook arriving (research §5).
    /// The hooks go out as inline `--settings`: session-scoped, merged with the
    /// user's personal hooks, nothing written to their disk (STA-01).
    public func launchCommand(session: SessionID, initialPrompt: String?,
                              hookToken: String? = nil) -> Command {
        var arguments = ["--session-id", session.rawValue.uuidString]
        if let hooks, let hookToken,
           let settings = Self.hookSettingsJSON(wiring: hooks, token: hookToken) {
            arguments.append(contentsOf: ["--settings", settings])
        }
        if let initialPrompt {
            arguments.append(initialPrompt)
        }
        return Command(executable: executable, arguments: arguments)
    }

    /// Translates a hook payload (JSON stdin of the helper) into a reducer event.
    /// `nil` = nothing to tell the state machine (notification with no state value,
    /// corrupted payload — never a transition on noise).
    public static func interpret(_ payload: Data) -> StateEngine.Event? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let fields = object as? [String: Any],
              let eventName = fields["hook_event_name"] as? String else {
            return nil
        }
        switch eventName {
        case "UserPromptSubmit":
            return .hook(.userPromptSubmit)
        case "Stop":
            let message = fields["last_assistant_message"] as? String ?? ""
            return .hook(.stop(awaitsReply: TurnEndClassifier.awaitsUserReply(message)))
        case "PermissionRequest":
            return .hook(.permissionRequested)
        case "Notification":
            switch fields["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .hook(.permissionRequested)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// UC-7: since the UUID was imposed at launch, Resume is a simple `--resume`.
    public func resumeCommand(session: SessionID, hookToken: String? = nil) -> Command {
        var arguments = ["--resume", session.rawValue.uuidString]
        if let hooks, let hookToken,
           let settings = Self.hookSettingsJSON(wiring: hooks, token: hookToken) {
            arguments.append(contentsOf: ["--settings", settings])
        }
        return Command(executable: executable, arguments: arguments)
    }

    private static func hookSettingsJSON(wiring: HookWiring, token: String) -> String? {
        let helperInvocation = [
            wiring.helper.path, "--socket", wiring.socket.path, "--token", token,
        ].map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")

        let entry: [[String: Any]] = [[
            "hooks": [["type": "command", "command": helperInvocation]],
        ]]
        let settings: [String: Any] = [
            "hooks": Dictionary(uniqueKeysWithValues: hookedEvents.map { ($0, entry) }),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
