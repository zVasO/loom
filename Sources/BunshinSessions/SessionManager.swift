import BunshinAgents
import BunshinCore
import BunshinPersistence
import BunshinTerminal
import Foundation

/// L'acteur central (§6.2 du cahier des charges, placé ici par ADR-0009) : crée les
/// sessions, route leurs événements vers la machine à états, porte la vérité des
/// états pour la couche vue. Le runtime mesure ; le StateEngine décide ; le manager relie.
public actor SessionManager {

    public struct SessionSpec: Sendable {
        public var command: Command
        public var workingDirectory: URL
        public var geometry: TerminalGeometry
        public init(command: Command, workingDirectory: URL,
                    geometry: TerminalGeometry = .default) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.geometry = geometry
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
    private let clock = ContinuousClock()

    public init(runtimeDependencies: SessionRuntime.Dependencies, store: SessionStore? = nil) {
        self.runtimeDependencies = runtimeDependencies
        self.store = store
    }

    /// UC-1 : crée le runtime, arme le pump d'événements, la session naît en `starting`.
    public func launch(_ spec: SessionSpec) async throws -> SessionID {
        let id = SessionID()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: spec.command,
                              workingDirectory: spec.workingDirectory,
                              geometry: spec.geometry),
            using: runtimeDependencies)
        runtimes[id] = runtime
        states[id] = StateEngine.State(session: .starting)
        let token = UUID().uuidString
        tokens[token] = id
        tokensBySession[id] = token
        try? store?.insert(SessionRecord(id: id, title: spec.command.executable,
                                         agentID: "claude-code", state: .starting,
                                         createdAt: Date()))
        pumps[id] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, for: id)
            }
        }
        return id
    }

    /// Point d'entrée des hooks (serveur IPC) et des heuristiques : toute transition
    /// passe par le réducteur — le manager n'écrit jamais un état à la main.
    public func apply(_ event: StateEngine.Event, to id: SessionID) {
        guard let current = states[id] else { return }
        let next = StateEngine.reduce(current, event, at: clock.now)
        states[id] = next
        guard next.session != current.session else { return }
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
        guard let id = tokens[token],
              let event = ClaudeCodeAdapter.interpret(payload) else { return }
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
        case .terminated(let report):
            apply(.process(.exited(code: report.exitStatus.code)), to: id)
            pumps[id] = nil
        }
    }
}
