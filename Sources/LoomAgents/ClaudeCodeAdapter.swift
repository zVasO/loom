import LoomAPI
import LoomCore
import Foundation

/// Translates the Loom world to the Claude Code CLI (spec §6.2).
/// Facts verified against the primary source: docs/research/claude-code-hooks.md.
public struct ClaudeCodeAdapter: Sendable {

    /// Wiring of the hooks to the app: helper binary (ADR-0005) and Unix socket.
    /// The token, on the other hand, is PER SESSION — it is passed to `launchCommand`.
    /// `cli` is the `loom` binary (ADR-0010): when present, the session gets the
    /// API as MCP tools; absent, it still has the socket and its token.
    public struct HookWiring: Sendable {
        public var helper: URL
        public var socket: URL
        public var cli: URL?
        public init(helper: URL, socket: URL, cli: URL? = nil) {
            self.helper = helper
            self.socket = socket
            self.cli = cli
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
        if let hooks, let hookToken, let mcp = Self.mcpConfigJSON(wiring: hooks, token: hookToken) {
            arguments.append(contentsOf: ["--mcp-config", mcp])
        }
        if let initialPrompt {
            arguments.append(initialPrompt)
        }
        return Command(executable: executable, arguments: arguments,
                       environment: Self.apiEnvironment(wiring: hooks, token: hookToken))
    }

    /// The agents API (ADR-0010) reaches the agent through its environment:
    /// the socket, and the token that scopes it to its own session. Nothing
    /// when the session has no wiring — a bare claude gets a bare environment.
    static func apiEnvironment(wiring: HookWiring?, token: String?) -> [String: String] {
        guard let wiring, let token else { return [:] }
        return [APIProtocol.socketEnvironmentKey: wiring.socket.path,
                APIProtocol.sessionTokenEnvironmentKey: token]
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
        if let hooks, let hookToken, let mcp = Self.mcpConfigJSON(wiring: hooks, token: hookToken) {
            arguments.append(contentsOf: ["--mcp-config", mcp])
        }
        return Command(executable: executable, arguments: arguments,
                       environment: Self.apiEnvironment(wiring: hooks, token: hookToken))
    }

    /// The API as MCP tools (ADR-0010), through inline `--mcp-config` — the CLI
    /// accepts a JSON string as well as a file, so nothing lands on disk. The
    /// server runs `loom mcp` with the session's socket and token in its
    /// environment; nil without a `loom` binary to run.
    static func mcpConfigJSON(wiring: HookWiring, token: String) -> String? {
        guard let cli = wiring.cli else { return nil }
        let config: [String: Any] = [
            "mcpServers": [
                "loom": [
                    "command": cli.path,
                    "args": ["mcp"],
                    "env": apiEnvironment(wiring: wiring, token: token),
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
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
