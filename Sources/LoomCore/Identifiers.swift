import Foundation

/// Identity of a Loom Session (distinct from the agent's native session — CONTEXT.md).
/// The UUID is imposed on the agent when its CLI allows it (`claude --session-id`), which makes
/// Resume deterministic (docs/research/claude-code-hooks.md §5).
public struct SessionID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identity of a Project (a local folder that sessions attach to — CONTEXT.md).
public struct ProjectID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identity of a terminal within a Session. `.primary` hosts the agent
/// (primary terminal); the others are secondary terminals (SES-04).
public struct TerminalID: Hashable, Sendable, Codable {
    public static let primary = TerminalID(rawValue: 0)
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public struct TerminalGeometry: Sendable, Equatable, Codable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
    /// Sizes the PTY before any view exists, so the agent never writes
    /// to an 80×24 screen that would have to be reflowed later.
    public static let `default` = TerminalGeometry(cols: 120, rows: 32)
}

/// What to execute — produced by an `AgentAdapter` (spec §6.2).
/// `environment` is an OVERLAY, not a complete environment: the runtime always
/// builds a base (`TERM`, `LANG`, `HOME`, and an explicit `PATH` — SwiftTerm
/// omits `PATH` from its default environment) then merges this overlay on top.
public struct Command: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}
