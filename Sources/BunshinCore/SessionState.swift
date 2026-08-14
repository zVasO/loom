/// États du cycle de vie d'une session — vocabulaire canonique défini dans CONTEXT.md.
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

/// Origine d'une transition d'état. Toute transition est journalisée avec sa source ;
/// la machine à états donne priorité aux hooks sur les heuristiques (STA-03).
public enum TransitionSource: String, Codable, Sendable {
    case hook
    case heuristic
    case process
    case user
}
