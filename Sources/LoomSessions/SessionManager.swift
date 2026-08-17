import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomTerminal
import Foundation

/// System notifications (STA-04): a seam with two adapters — UserNotifications in
/// prod (app layer), a spy in tests.
public protocol SessionNotifier: Sendable {
    func sessionNeedsInput(_ session: SessionID, title: String)
}

/// The central actor (spec §6.2, placed here by ADR-0009): creates the
/// sessions, routes their events to the state machine, and holds the truth of the
/// states for the view layer. The runtime measures; the StateEngine decides; the manager connects.
public actor SessionManager {

    public struct SessionSpec: Sendable {
        public var command: Command
        public var workingDirectory: URL
        public var geometry: TerminalGeometry
        /// `nil` = no heuristic channel (hook-driven sessions).
        public var samplingInterval: Duration?
        /// IPC token already embedded in the command (hooks --settings); `nil` = the
        /// manager generates one.
        public var hookToken: String?
        /// GIT-01: `.create` builds the worktree BEFORE the fork and the session
        /// works there isolated on its `loom/<slug>` branch.
        public var worktree: WorktreeStrategy = .none
        /// PRJ-03: the project this session belongs to, persisted with the session.
        public var projectID: ProjectID?
        /// The UUID imposed on the CLI (`claude --session-id`): the SAME end to end —
        /// command, manager, database — otherwise `--resume` replays an identifier the
        /// agent never knew. `nil` = the manager generates one.
        public var sessionID: SessionID?
        /// Displayed title; `nil` = "Session".
        public var title: String?
        public init(command: Command, workingDirectory: URL,
                    geometry: TerminalGeometry = .default,
                    samplingInterval: Duration? = nil,
                    hookToken: String? = nil) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.geometry = geometry
            self.samplingInterval = samplingInterval
            self.hookToken = hookToken
        }
    }

    private let runtimeDependencies: SessionRuntime.Dependencies
    /// `nil` in pure unit tests; the database never fails a live session —
    /// write errors are silently absorbed (NFR-R).
    private let store: SessionStore?
    private var runtimes: [SessionID: SessionRuntime] = [:]
    private var states: [SessionID: StateEngine.State] = [:]
    private var pumps: [SessionID: Task<Void, Never>] = [:]
    /// Per-session IPC token (ADR-0005): issued at birth, verified on every payload.
    private var tokens: [String: SessionID] = [:]
    private var tokensBySession: [SessionID: String] = [:]
    private var stateContinuation: AsyncStream<StateUpdate>.Continuation?
    private let clock = ContinuousClock()

    public struct StateUpdate: Sendable, Equatable {
        public let id: SessionID
        public let state: SessionState
    }

    /// Stream of real transitions for the view layer. Single-consumer,
    /// buffered: the UI can subscribe before or after the first transitions.
    public func stateUpdates() -> AsyncStream<StateUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: StateUpdate.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        stateContinuation = continuation
        return stream
    }

    /// P0 perf: the user's terminal refresh setting, applied to every runtime.
    private var frameInterval: Duration = .milliseconds(33)

    public func setFrameInterval(_ interval: Duration) {
        frameInterval = interval
        for runtime in runtimes.values { runtime.setFrameInterval(interval) }
    }

    private let tuning: StateEngine.Tuning
    private let interpreter: HeuristicInterpreter
    private let git: GitService
    private let notifier: (any SessionNotifier)?

    public enum WorktreeStrategy: Sendable {
        /// The session works directly in the provided directory.
        case none
        /// Dedicated worktree: `<repo>-worktrees/<slug>` on `loom/<slug>` (GIT-01,
        /// sibling root by default — decision from the first review of the spec:
        /// never nested worktrees in the agents' sight).
        case create(repo: URL, slug: String)
    }

    /// v2 (search): per-session transcript sinks — every session writes to its
    /// own files, so transcripts can be indexed per session instead of being
    /// interleaved in shared TerminalID-named files. `nil` keeps the shared sink.
    private let transcriptFactory: (@Sendable (SessionID) throws -> any TranscriptSink)?

    public init(runtimeDependencies: SessionRuntime.Dependencies, store: SessionStore? = nil,
                tuning: StateEngine.Tuning = .standard,
                interpreter: HeuristicInterpreter = HeuristicInterpreter(),
                git: GitService = GitService(),
                notifier: (any SessionNotifier)? = nil,
                transcriptFactory: (@Sendable (SessionID) throws -> any TranscriptSink)? = nil) {
        self.transcriptFactory = transcriptFactory
        self.runtimeDependencies = runtimeDependencies
        self.store = store
        self.tuning = tuning
        self.interpreter = interpreter
        self.git = git
        self.notifier = notifier
    }

    /// UC-1: worktree (if requested) → runtime → event pump; the session is born
    /// in `starting`.
    public func launch(_ spec: SessionSpec) async throws -> SessionID {
        let id = spec.sessionID ?? SessionID()
        var workingDirectory = spec.workingDirectory
        var worktree: Worktree?
        if case .create(let repo, let slug) = spec.worktree {
            let root = repo.deletingLastPathComponent()
                .appendingPathComponent(repo.lastPathComponent + "-worktrees")
            let created = try await git.createWorktree(repo: repo, root: root, slug: slug)
            worktree = created
            workingDirectory = created.path
        }
        var dependencies = runtimeDependencies
        if let transcriptFactory, let sink = try? transcriptFactory(id) {
            dependencies.transcript = sink
        }
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: spec.command,
                              workingDirectory: workingDirectory,
                              geometry: spec.geometry,
                              samplingInterval: spec.samplingInterval),
            using: dependencies)
        runtime.setFrameInterval(frameInterval)
        runtimes[id] = runtime
        states[id] = StateEngine.State(session: .starting)
        let token = spec.hookToken ?? UUID().uuidString
        tokens[token] = id
        tokensBySession[id] = token
        try? store?.insert(SessionRecord(id: id, title: spec.title ?? "Session",
                                         agentID: "claude-code", state: .starting,
                                         branch: worktree?.branch,
                                         worktreePath: worktree?.path.path,
                                         projectID: spec.projectID,
                                         createdAt: Date()))
        pumps[id] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, for: id)
            }
        }
        return id
    }

    /// UC-7: relaunches an interrupted session under the SAME identifier — the history
    /// remains one continuous thread. The command (`claude --resume <uuid>` + hooks) is
    /// built by the caller, who owns the wiring.
    public func resume(_ record: SessionRecord, command: Command, workingDirectory: URL,
                       geometry: TerminalGeometry = .default,
                       samplingInterval: Duration? = nil, hookToken: String? = nil) async throws {
        let id = record.id
        var dependencies = runtimeDependencies
        if let transcriptFactory, let sink = try? transcriptFactory(id) {
            dependencies.transcript = sink
        }
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: command,
                              workingDirectory: workingDirectory,
                              geometry: geometry,
                              samplingInterval: samplingInterval),
            using: dependencies)
        runtime.setFrameInterval(frameInterval)
        runtimes[id] = runtime
        states[id] = StateEngine.State(session: .interrupted)
        let token = hookToken ?? UUID().uuidString
        tokens[token] = id
        tokensBySession[id] = token
        pumps[id] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, for: id)
            }
        }
        apply(.user(.resume), to: id)   // interrupted → starting, logged, database and UI up to date
    }

    /// SES-07: archive — including a session from history, absent from memory.
    public func archive(_ id: SessionID) {
        if states[id] == nil {
            let record = (try? store?.session(id: id)) ?? nil
            guard let record else { return }
            states[id] = StateEngine.State(session: record.state)
        }
        apply(.user(.archive), to: id)
    }

    /// Entry point for hooks (IPC server) and heuristics: every transition
    /// goes through the reducer — the manager never writes a state by hand.
    public func apply(_ event: StateEngine.Event, to id: SessionID) {
        guard let current = states[id] else { return }
        let next = StateEngine.reduce(current, event, at: clock.now, tuning: tuning)
        states[id] = next
        guard next.session != current.session else { return }
        stateContinuation?.yield(StateUpdate(id: id, state: next.session))
        if next.session == .needsInput {
            let record = (try? store?.session(id: id)) ?? nil
            notifier?.sessionNeedsInput(id, title: record?.title ?? "Session")
        }
        // The transition is real: STA-06 journal + current state in the database.
        try? store?.recordTransition(session: id, from: current.session, to: next.session,
                                     source: Self.source(of: event), at: Date())
        if case .process(.exited(let code)) = event {
            try? store?.updateState(session: id, to: next.session, exitCode: code, endedAt: Date())
        } else {
            try? store?.updateState(session: id, to: next.session)
        }
    }

    private static func source(of event: StateEngine.Event) -> TransitionSource {
        switch event {
        case .hook: .hook
        case .heuristic: .heuristic
        case .process: .process
        case .user: .user
        }
    }

    // MARK: - Hook circuit (wired to HookSocketServer)

    public func hookToken(for id: SessionID) -> String? {
        tokensBySession[id]
    }

    /// The IPC server's `validate`: token → session, `nil` for any unknown token.
    public func session(forToken token: String) -> SessionID? {
        tokens[token]
    }

    /// The IPC server's `handler`: raw payload → interpretation by the adapter →
    /// reducer. A forged token or a payload with no state value produces nothing.
    public func ingestHookPayload(_ payload: Data, token: String) {
        guard let id = tokens[token] else { return }
        ingest(payload, for: id)
    }

    /// Variant for when the session is already authenticated (the server validated the token).
    public func ingest(_ payload: Data, for id: SessionID) {
        guard states[id] != nil, let event = ClaudeCodeAdapter.interpret(payload) else { return }
        apply(event, to: id)
    }

    public func state(of id: SessionID) -> SessionState? {
        states[id]?.session
    }

    public func sessions() -> [SessionID] {
        Array(runtimes.keys)
    }

    public func runtime(for id: SessionID) -> SessionRuntime? {
        runtimes[id]
    }

    /// SES-06: escalated shutdown delegated to the runtime; the final state will come
    /// from the exit via the pump, never from a direct write.
    public func stop(_ id: SessionID, ladder: ShutdownLadder = .graceful) async {
        guard let runtime = runtimes[id] else { return }
        await runtime.stop(ladder)
    }

    private func handle(_ event: SessionRuntime.Event, for id: SessionID) {
        switch event {
        case .started:
            break   // the session stays `starting` until the agent's first signal
        case .activity(let sample):
            if let proposal = interpreter.propose(sample) {
                apply(proposal, to: id)
            }
        case .terminated(let report):
            apply(.process(.exited(code: report.exitStatus.code)), to: id)
            pumps[id] = nil
        }
    }
}
