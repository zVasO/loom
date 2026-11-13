import Foundation

/// One thing said or done in the conversation of a native session, as the
/// chat view lists it. Read from claude's own `<uuid>.jsonl`, never from the
/// terminal: the terminal draws a screen, the file keeps the exchange.
public struct ConversationEntry: Identifiable, Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// What the user sent, as text.
        case user(String)
        /// What claude said: Markdown.
        case assistant(String)
        /// claude's thinking, when the file holds it in clear.
        case thinking(String)
        /// One tool call, with its result once it has one.
        case tool(ToolCall)
        /// A slash command, a compaction, an interruption: one short line.
        case notice(String)
    }

    /// A tool call and its answer. claude writes the two apart — the call in
    /// an assistant line, the result in a later user line — and the chat view
    /// shows them as one row.
    public struct ToolCall: Equatable, Sendable {
        /// What pairs the call with its result (`tool_use_id`).
        public var toolUseID: String
        /// The tool as claude names it: "Read", "Bash", "mcp__loom__browser_open"…
        public var name: String
        /// One line for the row: "Read Sources/LoomUI/ThemeStore.swift".
        public var summary: String
        /// The input made readable: the command, else the JSON. Capped.
        public var input: String
        /// Nil while the tool runs. Capped.
        public var result: String?
        public var isError: Bool

        public init(toolUseID: String, name: String, summary: String, input: String,
                    result: String? = nil, isError: Bool = false) {
            self.toolUseID = toolUseID
            self.name = name
            self.summary = summary
            self.input = input
            self.result = result
            self.isError = isError
        }
    }

    /// Stable across re-reads of the same file: a list keyed on it keeps its
    /// rows, and its scroll position, while the conversation grows.
    public let id: String
    public var kind: Kind
    public var timestamp: Date?

    public init(id: String, kind: Kind, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}
