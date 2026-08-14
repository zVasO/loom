/// Machine à états des sessions : réducteur pur `(état, événement horodaté) → état`,
/// porté depuis le prototype validé (docs/research/state-engine-prototype.md).
public enum StateEngine {

    /// Un état posé par un hook n'est jamais écrasé par une heuristique dans les 10 s (STA-03).
    public static let hookPriorityWindow: Duration = .seconds(10)
    /// Une proposition heuristique doit être maintenue au moins 2 s avant de s'appliquer (STA-02).
    public static let heuristicHysteresis: Duration = .seconds(2)

    public struct State: Sendable, Equatable {
        public var session: SessionState
        var lastHookAt: ContinuousClock.Instant?
        var candidate: Candidate?
        public init(session: SessionState) {
            self.session = session
        }
    }

    struct Candidate: Sendable, Equatable {
        var guess: HeuristicGuess
        var since: ContinuousClock.Instant
    }

    public enum Event: Sendable, Equatable {
        case hook(AgentSignal)
        case heuristic(HeuristicGuess)
        case process(ProcessEvent)
        case user(UserAction)
    }

    /// Événement du cycle de vie du process de l'agent (waitpid / SessionRuntime).
    public enum ProcessEvent: Sendable, Equatable {
        case exited(code: Int32?)
        /// L'app s'est arrêtée alors que la session vivait : le PTY est mort avec elle
        /// (ADR-0006), la session devient candidate à la Reprise.
        case interrupted
    }

    /// Action explicite de l'utilisateur dans l'app.
    public enum UserAction: Sendable, Equatable {
        case resume
    }

    /// Signal émis par l'agent lui-même via ses hooks — source d'état prioritaire (STA-03).
    public enum AgentSignal: Sendable, Equatable {
        case userPromptSubmit
        /// Hook `Stop` : l'agent a fini de répondre. `awaitsReply` = le tour se conclut en
        /// attendant une réponse de l'utilisateur (question, choix, invitation). La
        /// classification du `last_assistant_message` est faite en amont par l'AgentAdapter ;
        /// le réducteur reçoit un fait, pas un texte (docs/research/claude-code-hooks.md §4).
        case stop(awaitsReply: Bool)
        /// Hooks `PermissionRequest` / `Notification(permission_prompt)` : l'agent est bloqué.
        case permissionRequested
    }

    /// Proposition d'état inférée par observation du PTY — source de repli (STA-02).
    public enum HeuristicGuess: Sendable, Equatable {
        case working
        case idle
        case needsInput
    }

    /// États dont on ne sort plus par signal (seule une action utilisateur — Reprise,
    /// archivage — crée une nouvelle trajectoire).
    private static let terminalStates: Set<SessionState> = [.completed, .failed, .archived]

    public static func reduce(_ state: State, _ event: Event, at instant: ContinuousClock.Instant) -> State {
        guard !terminalStates.contains(state.session) else { return state }
        var next = state
        switch event {
        case .hook(let signal):
            next.session = sessionState(after: signal)
            next.lastHookAt = instant
            next.candidate = nil
        case .process(.exited(let code)):
            next.session = code == 0 ? .completed : .failed
            next.candidate = nil
        case .process(.interrupted):
            next.session = .interrupted
            next.candidate = nil
        case .user(.resume):
            if state.session == .interrupted {
                next.session = .starting
                next.candidate = nil
            }
        case .heuristic(let guess):
            if let lastHookAt = state.lastHookAt, instant - lastHookAt < hookPriorityWindow {
                break
            }
            if let candidate = state.candidate, candidate.guess == guess {
                if instant - candidate.since >= heuristicHysteresis {
                    next.session = sessionState(for: guess)
                    next.candidate = nil
                }
            } else {
                next.candidate = Candidate(guess: guess, since: instant)
            }
        }
        return next
    }

    private static func sessionState(after signal: AgentSignal) -> SessionState {
        switch signal {
        case .userPromptSubmit: .working
        case .stop(awaitsReply: true): .needsInput
        case .stop(awaitsReply: false): .idle
        case .permissionRequested: .needsInput
        }
    }

    private static func sessionState(for guess: HeuristicGuess) -> SessionState {
        switch guess {
        case .working: .working
        case .idle: .idle
        case .needsInput: .needsInput
        }
    }
}
