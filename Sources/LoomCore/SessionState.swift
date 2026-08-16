/// Session lifecycle states — canonical vocabulary defined in CONTEXT.md.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case draft
    case starting
    case working
    case needsInput = "needs_input"
    case idle
    case completed
    case failed
    case interrupted
    case archived
}

/// Origin of a state transition. Every transition is logged with its source;
/// the state machine gives hooks priority over heuristics (STA-03).
public enum TransitionSource: String, Codable, Sendable {
    case hook
    case heuristic
    case process
    case user
}
