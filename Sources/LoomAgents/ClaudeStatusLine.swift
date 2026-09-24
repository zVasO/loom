import Foundation

/// Claude Code tells the size of its context window to ONE program: the
/// status line command, fed a JSON object on stdin at each update
/// (`context_window.context_window_size`, `model.id`…). The transcript and
/// the hooks never carry it — the transcript writes `claude-opus-5-5` bare
/// whether the 1M window is on or not.
///
/// So Loom installs its own status line — `loom-hook --statusline` — which
/// forwards that JSON to the app, then runs the user's own status line and
/// prints its output unchanged. A `statusLine` passed with `--settings`
/// overrides the user's (a scalar setting: highest source wins), hence the
/// relay: the user's line is resolved here, at launch, and chained.
public enum ClaudeStatusLine {

    /// The event name `loom-hook --statusline` stamps on the forwarded JSON,
    /// so the app tells it from a hook payload.
    public static let eventName = "LoomStatusLine"

    /// The user's own status line, as their settings define it.
    public struct UserCommand: Equatable, Sendable {
        public let command: String
        public let padding: Int?
        public let refreshInterval: Int?

        public init(command: String, padding: Int? = nil, refreshInterval: Int? = nil) {
            self.command = command
            self.padding = padding
            self.refreshInterval = refreshInterval
        }
    }

    /// What a status line update says about the session.
    public struct Report: Equatable, Sendable {
        public let modelID: String?
        public let windowTokens: Int

        public init(modelID: String?, windowTokens: Int) {
            self.modelID = modelID
            self.windowTokens = windowTokens
        }
    }

    /// The user's status line for a session working in `cwd`, in claude's
    /// own precedence: project local, then project, then user settings. The
    /// first source that defines a `statusLine` wins, as it would in claude;
    /// only the `command` type exists today, anything else is ignored.
    public static func user(cwd: URL, configDirectory: URL = defaultConfigDirectory) -> UserCommand? {
        let sources = [
            cwd.appendingPathComponent(".claude/settings.local.json"),
            cwd.appendingPathComponent(".claude/settings.json"),
            configDirectory.appendingPathComponent("settings.json"),
        ]
        for source in sources {
            guard let data = try? Data(contentsOf: source),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let statusLine = settings["statusLine"] as? [String: Any] else { continue }
            guard statusLine["type"] as? String == "command",
                  let command = statusLine["command"] as? String,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return UserCommand(command: command,
                               padding: statusLine["padding"] as? Int,
                               refreshInterval: statusLine["refreshInterval"] as? Int)
        }
        return nil
    }

    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude` — where claude reads the user settings.
    public static var defaultConfigDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// `nil` unless the payload is a forwarded status line update carrying
    /// a window size.
    public static func report(from payload: Data) -> Report? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let fields = object as? [String: Any],
              fields["hook_event_name"] as? String == eventName,
              let window = fields["context_window"] as? [String: Any],
              let size = (window["context_window_size"] as? NSNumber)?.intValue,
              size > 0 else {
            return nil
        }
        let model = (fields["model"] as? [String: Any])?["id"] as? String
        return Report(modelID: model, windowTokens: size)
    }
}
