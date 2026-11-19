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
        /// Set when the call starts a sub-agent (the Task / Agent tool):
        /// what it was asked, and — once claude says it — which one it is.
        public var agent: AgentCall?

        public init(toolUseID: String, name: String, summary: String, input: String,
                    result: String? = nil, isError: Bool = false, agent: AgentCall? = nil) {
            self.toolUseID = toolUseID
            self.name = name
            self.summary = summary
            self.input = input
            self.result = result
            self.isError = isError
            self.agent = agent
        }
    }

    /// A sub-agent started by a tool call: its brief, and what links the
    /// call to the sub-agent's own conversation.
    public struct AgentCall: Equatable, Sendable {
        /// The short name claude gave the task: "Find the flaky test".
        public var description: String
        /// The kind of agent: "Explore", "general-purpose"…
        public var type: String
        /// The brief, as written to the sub-agent.
        public var prompt: String
        /// The sub-agent's id, known once its result is in.
        public var agentID: String?
        /// What the result says of the run, when it does.
        public var toolUses: Int?
        public var durationMs: Int?

        public init(description: String, type: String, prompt: String, agentID: String? = nil,
                    toolUses: Int? = nil, durationMs: Int? = nil) {
            self.description = description
            self.type = type
            self.prompt = prompt
            self.agentID = agentID
            self.toolUses = toolUses
            self.durationMs = durationMs
        }
    }

    /// Stable across re-reads of the same file: a list keyed on it keeps its
    /// rows, and its scroll position, while the conversation grows.
    public let id: String
    public var kind: Kind
    public var timestamp: Date?
    /// The images a user's message carried (PNG, JPEG…), as claude keeps
    /// them: shown with the message.
    public var images: [Data]

    public init(id: String, kind: Kind, timestamp: Date? = nil, images: [Data] = []) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.images = images
    }
}
