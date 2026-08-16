import BunshinCore
import Foundation

/// Traduit le monde Bunshin vers le CLI Claude Code (§6.2 du cahier des charges).
/// Faits vérifiés en source primaire : docs/research/claude-code-hooks.md.
public struct ClaudeCodeAdapter: Sendable {

    /// Câblage des hooks vers l'app : binaire helper (ADR-0005) et socket Unix.
    /// Le token, lui, est PAR SESSION — il se passe à `launchCommand`.
    public struct HookWiring: Sendable {
        public var helper: URL
        public var socket: URL
        public init(helper: URL, socket: URL) {
            self.helper = helper
            self.socket = socket
        }
    }

    /// Événements écoutés — le sous-ensemble qui porte la détection d'état (STA-01),
    /// vérifié contre la doc officielle (docs/research/claude-code-hooks.md §1).
    static let hookedEvents = ["SessionStart", "UserPromptSubmit", "Stop",
                               "Notification", "PermissionRequest", "SessionEnd"]

    public var executable: String
    public var hooks: HookWiring?

    public init(executable: String = "claude", hooks: HookWiring? = nil) {
        self.executable = executable
        self.hooks = hooks
    }

    /// L'UUID de session est IMPOSÉ au CLI (`--session-id`) : la Reprise devient
    /// déterministe, sans dépendre de l'arrivée du hook SessionStart (recherche §5).
    /// Les hooks partent en `--settings` inline : portée session, fusionnés avec les
    /// hooks personnels de l'utilisateur, rien d'écrit sur son disque (STA-01).
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

    /// Traduit un payload de hook (JSON stdin du helper) en événement du réducteur.
    /// `nil` = rien à dire à la machine à états (notification sans valeur d'état,
    /// payload corrompu — jamais de transition sur du bruit).
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

    /// UC-7 : l'UUID ayant été imposé au lancement, la Reprise est un simple `--resume`.
    public func resumeCommand(session: SessionID) -> Command {
        Command(executable: executable, arguments: ["--resume", session.rawValue.uuidString])
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
