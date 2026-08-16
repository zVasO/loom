/// Session state machine: pure reducer `(state, timestamped event) → state`,
/// ported from the validated prototype (docs/research/state-engine-prototype.md).
public enum StateEngine {

    /// Smoothing constants, injectable (millisecond values in tests, per-agent
    /// tuning eventually). The standard values are the ones from the spec.
    public struct Tuning: Sendable {
        /// A state set by a hook is never overwritten by a heuristic within this window (STA-03).
        public var hookPriorityWindow: Duration
        /// A heuristic proposal must be sustained at least this long before it applies (STA-02).
        public var heuristicHysteresis: Duration
        /// Beyond this gap between two observations of the same proposal, it is
        /// stale and starts over from zero: the hysteresis measures a SUSTAINED observation.
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

    /// Lifecycle event of the agent's process (waitpid / SessionRuntime).
    public enum ProcessEvent: Sendable, Equatable {
        case exited(code: Int32?)
        /// The app stopped while the session was alive: the PTY died with it
        /// (ADR-0006), and the session becomes a candidate for Resume.
        case interrupted
    }

    /// Explicit user action in the app.
    public enum UserAction: Sendable, Equatable {
        case resume
        case archive
    }

    /// Signal emitted by the agent itself via its hooks — highest-priority state source (STA-03).
    public enum AgentSignal: Sendable, Equatable {
        case userPromptSubmit
        /// `Stop` hook: the agent finished responding. `awaitsReply` = the turn ends
        /// waiting for a reply from the user (question, choice, invitation). The
        /// classification of the `last_assistant_message` is done upstream by the AgentAdapter;
        /// the reducer receives a fact, not a text (docs/research/claude-code-hooks.md §4).
        case stop(awaitsReply: Bool)
        /// `PermissionRequest` / `Notification(permission_prompt)` hooks: the agent is blocked.
        case permissionRequested
    }

    /// State proposal inferred from observing the PTY — fallback source (STA-02).
    public enum HeuristicGuess: Sendable, Equatable {
        case working
        case idle
        case needsInput
    }

    /// States no signal can leave (only a user action — Resume, archiving —
    /// creates a new trajectory).
    private static let terminalStates: Set<SessionState> = [.completed, .failed, .archived]

    public static func reduce(_ state: State, _ event: Event, at instant: ContinuousClock.Instant,
                              tuning: Tuning = .standard) -> State {
        // SES-07: archiving is the only action that crosses a terminal state —
        // its nominal case is precisely the completed session.
        if event == .user(.archive) {
            var next = state
            next.session = .archived
            next.candidate = nil
            return next
        }
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
        case .user(.archive):
            break   // handled before the switch (crosses terminal states)
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
