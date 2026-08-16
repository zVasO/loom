/// Machine à états des sessions : réducteur pur `(état, événement horodaté) → état`,
/// porté depuis le prototype validé (docs/research/state-engine-prototype.md).
public enum StateEngine {

    /// Constantes du lissage, injectables (tests en millisecondes, réglages par
    /// agent à terme). Les valeurs standard sont celles du cahier des charges.
    public struct Tuning: Sendable {
        /// Un état posé par un hook n'est jamais écrasé par une heuristique dans cette fenêtre (STA-03).
        public var hookPriorityWindow: Duration
        /// Une proposition heuristique doit être maintenue au moins ce temps avant de s'appliquer (STA-02).
        public var heuristicHysteresis: Duration
        /// Au-delà de cet écart entre deux observations d'une même proposition, elle est
        /// périmée et repart de zéro : l'hystérésis mesure une observation SOUTENUE.
        public var heuristicStaleness: Duration
        public init(hookPriorityWindow: Duration = .seconds(10),
                    heuristicHysteresis: Duration = .seconds(2),
                    heuristicStaleness: Duration = .seconds(4)) {
            self.hookPriorityWindow = hookPriorityWindow
            self.heuristicHysteresis = heuristicHysteresis
            self.heuristicStaleness = heuristicStaleness
        }
        public static let standard = Tuning()
    }

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
        var lastObserved: ContinuousClock.Instant
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

    public static func reduce(_ state: State, _ event: Event, at instant: ContinuousClock.Instant,
                              tuning: Tuning = .standard) -> State {
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
            if let lastHookAt = state.lastHookAt, instant - lastHookAt < tuning.hookPriorityWindow {
                break
            }
            if let candidate = state.candidate, candidate.guess == guess,
               instant - candidate.lastObserved <= tuning.heuristicStaleness {
                if instant - candidate.since >= tuning.heuristicHysteresis {
                    next.session = sessionState(for: guess)
                    next.candidate = nil
                } else {
                    next.candidate?.lastObserved = instant
                }
            } else {
                next.candidate = Candidate(guess: guess, since: instant, lastObserved: instant)
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
