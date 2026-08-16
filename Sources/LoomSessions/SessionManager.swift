import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomTerminal
import Foundation

/// Notifications système (STA-04) : seam à deux adapters — UserNotifications en
/// prod (couche app), espion en test.
public protocol SessionNotifier: Sendable {
    func sessionNeedsInput(_ session: SessionID, title: String)
}

/// L'acteur central (§6.2 du cahier des charges, placé ici par ADR-0009) : crée les
/// sessions, route leurs événements vers la machine à états, porte la vérité des
/// états pour la couche vue. Le runtime mesure ; le StateEngine décide ; le manager relie.
public actor SessionManager {

    public struct SessionSpec: Sendable {
        public var command: Command
        public var workingDirectory: URL
        public var geometry: TerminalGeometry
        /// `nil` = pas de canal heuristique (sessions pilotées par hooks).
        public var samplingInterval: Duration?
        /// Token IPC déjà embarqué dans la commande (hooks --settings) ; `nil` = le
        /// manager en génère un.
        public var hookToken: String?
        /// GIT-01 : `.create` fabrique le worktree AVANT le fork et la session y
        /// travaille isolée sur sa branche `loom/<slug>`.
        public var worktree: WorktreeStrategy = .none
        /// PRJ-03 : projet de rattachement, persisté avec la session.
        public var projectID: ProjectID?
        /// L'UUID imposé au CLI (`claude --session-id`) : le MÊME de bout en bout —
        /// commande, manager, base — sans quoi `--resume` rejoue un identifiant que
        /// l'agent n'a jamais connu. `nil` = le manager en génère un.
        public var sessionID: SessionID?
        /// Titre affiché ; `nil` = « Session ».
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
    /// `nil` en tests unitaires purs ; la base ne fait jamais échouer une session
    /// vivante — les erreurs d'écriture sont silencieusement absorbées (NFR-R).
    private let store: SessionStore?
    private var runtimes: [SessionID: SessionRuntime] = [:]
    private var states: [SessionID: StateEngine.State] = [:]
    private var pumps: [SessionID: Task<Void, Never>] = [:]
    /// Token IPC par session (ADR-0005) : émis à la naissance, vérifié à chaque payload.
    private var tokens: [String: SessionID] = [:]
    private var tokensBySession: [SessionID: String] = [:]
    private var stateContinuation: AsyncStream<StateUpdate>.Continuation?
    private let clock = ContinuousClock()

    public struct StateUpdate: Sendable, Equatable {
        public let id: SessionID
        public let state: SessionState
    }

    /// Flux des transitions réelles pour la couche vue. Mono-consommateur,
    /// tamponné : l'UI peut s'abonner avant ou après les premières transitions.
    public func stateUpdates() -> AsyncStream<StateUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: StateUpdate.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        stateContinuation = continuation
        return stream
    }

    private let tuning: StateEngine.Tuning
    private let interpreter: HeuristicInterpreter
    private let git: GitService
    private let notifier: (any SessionNotifier)?

    public enum WorktreeStrategy: Sendable {
        /// La session travaille directement dans le dossier fourni.
        case none
        /// Worktree dédié : `<repo>-worktrees/<slug>` sur `loom/<slug>` (GIT-01,
        /// racine sibling par défaut — décision du premier avis sur le cahier des
        /// charges : jamais de worktrees imbriqués sous les yeux des agents).
        case create(repo: URL, slug: String)
    }

    public init(runtimeDependencies: SessionRuntime.Dependencies, store: SessionStore? = nil,
                tuning: StateEngine.Tuning = .standard,
                interpreter: HeuristicInterpreter = HeuristicInterpreter(),
                git: GitService = GitService(),
                notifier: (any SessionNotifier)? = nil) {
        self.runtimeDependencies = runtimeDependencies
        self.store = store
        self.tuning = tuning
        self.interpreter = interpreter
        self.git = git
        self.notifier = notifier
    }

    /// UC-1 : worktree (si demandé) → runtime → pump d'événements ; la session naît
    /// en `starting`.
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
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: spec.command,
                              workingDirectory: workingDirectory,
                              geometry: spec.geometry,
                              samplingInterval: spec.samplingInterval),
            using: runtimeDependencies)
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

    /// UC-7 : relance une session interrompue sous le MÊME identifiant — l'historique
    /// reste un fil continu. La commande (`claude --resume <uuid>` + hooks) est
    /// construite par l'appelant, qui possède le câblage.
    public func resume(_ record: SessionRecord, command: Command, workingDirectory: URL,
                       geometry: TerminalGeometry = .default,
                       samplingInterval: Duration? = nil, hookToken: String? = nil) async throws {
        let id = record.id
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: command,
                              workingDirectory: workingDirectory,
                              geometry: geometry,
                              samplingInterval: samplingInterval),
            using: runtimeDependencies)
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
        apply(.user(.resume), to: id)   // interrupted → starting, journalisé, base et UI à jour
    }

    /// SES-07 : archive — y compris une session de l'historique, absente de la mémoire.
    public func archive(_ id: SessionID) {
        if states[id] == nil {
            let record = (try? store?.session(id: id)) ?? nil
            guard let record else { return }
            states[id] = StateEngine.State(session: record.state)
        }
        apply(.user(.archive), to: id)
    }

    /// Point d'entrée des hooks (serveur IPC) et des heuristiques : toute transition
    /// passe par le réducteur — le manager n'écrit jamais un état à la main.
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
        // La transition est réelle : journal STA-06 + état courant en base.
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

    // MARK: - Circuit hooks (branché sur HookSocketServer)

    public func hookToken(for id: SessionID) -> String? {
        tokensBySession[id]
    }

    /// Le `validate` du serveur IPC : token → session, `nil` pour tout token inconnu.
    public func session(forToken token: String) -> SessionID? {
        tokens[token]
    }

    /// Le `handler` du serveur IPC : payload brut → interprétation par l'adapter →
    /// réducteur. Un token forgé ou un payload sans valeur d'état ne produit rien.
    public func ingestHookPayload(_ payload: Data, token: String) {
        guard let id = tokens[token] else { return }
        ingest(payload, for: id)
    }

    /// Variante quand la session est déjà authentifiée (le serveur a validé le token).
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

    /// SES-06 : arrêt escaladé délégué au runtime ; l'état final viendra de l'exit
    /// via le pump, jamais d'une écriture directe.
    public func stop(_ id: SessionID, ladder: ShutdownLadder = .graceful) async {
        guard let runtime = runtimes[id] else { return }
        await runtime.stop(ladder)
    }

    private func handle(_ event: SessionRuntime.Event, for id: SessionID) {
        switch event {
        case .started:
            break   // la session reste `starting` jusqu'au premier signal de l'agent
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
