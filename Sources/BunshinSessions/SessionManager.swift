import BunshinCore
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
    private var runtimes: [SessionID: SessionRuntime] = [:]
    private var states: [SessionID: StateEngine.State] = [:]
    private var pumps: [SessionID: Task<Void, Never>] = [:]
    private let clock = ContinuousClock()

    public init(runtimeDependencies: SessionRuntime.Dependencies) {
        self.runtimeDependencies = runtimeDependencies
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
        states[id] = StateEngine.reduce(current, event, at: clock.now)
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
