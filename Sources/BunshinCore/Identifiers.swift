import Foundation

/// Identité d'une Session Bunshin (distincte de la session native de l'agent — CONTEXT.md).
/// L'UUID est imposé à l'agent quand son CLI le permet (`claude --session-id`), ce qui rend
/// la Reprise déterministe (docs/research/claude-code-hooks.md §5).
public struct SessionID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Identité d'un terminal au sein d'une Session. `.primary` héberge l'agent
/// (Terminal principal) ; les autres sont des Terminaux secondaires (SES-04).
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
    /// Dimensionne le PTY avant qu'une vue existe, pour que l'agent n'écrive
    /// jamais sur un écran 80×24 qu'il faudrait reflow ensuite.
    public static let `default` = TerminalGeometry(cols: 120, rows: 32)
}

/// Ce qu'il faut exécuter — produit par un `AgentAdapter` (§6.2 du cahier des charges).
/// `environment` est un OVERLAY, pas un environnement complet : le runtime construit
/// toujours une base (`TERM`, `LANG`, `HOME`, et un `PATH` explicite — SwiftTerm
/// omet `PATH` de son environnement par défaut) puis fusionne cet overlay par-dessus.
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
