import BunshinCore
import Dispatch
import Foundation

/// Tout ce qui est vivant dans une session : le process de l'agent sur son PTY,
/// le tee vers le Transcript, et (tranches à venir) le moteur terminal, l'échantillonnage
/// et les surfaces de vue. Décision d'interface : docs/design/session-runtime.md, ADR-0008.
public final class SessionRuntime: @unchecked Sendable {

    /// Seams internes avec défauts — aucun appelant de production ne les nomme.
    public struct Dependencies: Sendable {
        public var ptyHost: any PTYHost
        public var transcript: any TranscriptSink
        /// `nil` tant que l'adapter SwiftTerm n'existe pas ; deviendra le défaut de production.
        public var makeEngine: (@Sendable (TerminalGeometry, DispatchQueue) -> any TerminalEngine)?
        public init(ptyHost: any PTYHost,
                    transcript: any TranscriptSink,
                    makeEngine: (@Sendable (TerminalGeometry, DispatchQueue) -> any TerminalEngine)? = nil) {
            self.ptyHost = ptyHost
            self.transcript = transcript
            self.makeEngine = makeEngine
        }
    }

    public enum Event: Sendable {
        case started
        /// Toujours le dernier événement ; le flux se termine juste après. Quand un
        /// appelant le reçoit, le transcript est complet et fermé (barrière de drainage).
        case terminated(TerminationReport)
    }

    public struct TerminationReport: Sendable {
        public let exitStatus: ExitStatus
    }

    private let queue: DispatchQueue
    private var channel: (any PTYChannel)!
    /// Confiné à `queue`, sans exception (ADR-0007). Créé et nourri sur la queue de session.
    private var engine: (any TerminalEngine)?
    private let geometry: TerminalGeometry
    private let lock = NSLock()
    private var report: TerminationReport?
    private var terminationWaiters: [UUID: CheckedContinuation<TerminationReport?, Never>] = [:]

    private init(queue: DispatchQueue, geometry: TerminalGeometry) {
        self.queue = queue
        self.geometry = geometry
    }

    /// Écran visible courant du terminal principal, tous les octets déjà reçus étant parsés.
    /// Coût : un saut sur la queue de session + une copie O(cols × rows).
    public func snapshot() async -> TerminalScreen {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.engine?.snapshot() ?? .blank(self.geometry))
            }
        }
    }

    /// Arrêt escaladé (SES-06). Idempotent, ne jette jamais, valide après une sortie
    /// naturelle : tous les appelants reçoivent le même rapport.
    @discardableResult
    public func stop(_ ladder: ShutdownLadder = .graceful) async -> TerminationReport {
        for step in ladder.steps {
            if let done = currentReport() { return done }
            channel.signal(step.signal)
            if let done = await awaitTermination(upTo: step.grace) { return done }
        }
        // Après le dernier échelon (normalement SIGKILL), la sortie est inéluctable.
        return await awaitTermination(upTo: nil) ?? currentReport()!
    }

    private func currentReport() -> TerminationReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    private func onTerminated(_ newReport: TerminationReport) {
        lock.lock()
        report = newReport
        let waiters = terminationWaiters
        terminationWaiters = [:]
        lock.unlock()
        for waiter in waiters.values { waiter.resume(returning: newReport) }
    }

    /// Attend la terminaison au plus `grace` (nil = sans limite). Annulable proprement :
    /// le délai de grâce et l'exit réel courent l'un contre l'autre sans fuite de continuation.
    private func awaitTermination(upTo grace: Duration?) async -> TerminationReport? {
        await withTaskGroup(of: TerminationReport?.self) { group in
            group.addTask { await self.awaitTerminationCancellable() }
            if let grace {
                group.addTask {
                    try? await Task.sleep(for: grace)
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func awaitTerminationCancellable() async -> TerminationReport? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TerminationReport?, Never>) in
                lock.lock()
                if let report {
                    lock.unlock()
                    continuation.resume(returning: report)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                terminationWaiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = terminationWaiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(returning: nil)
        }
    }

    /// Le flux d'événements est rendu ici et une seule fois : mono-consommateur structurel.
    public static func launch(_ plan: SessionLaunchPlan,
                              using dependencies: Dependencies) throws -> (runtime: SessionRuntime, events: AsyncStream<Event>) {
        let queue = DispatchQueue(label: "app.bunshin.session")
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let runtime = SessionRuntime(queue: queue, geometry: plan.geometry)

        if let makeEngine = dependencies.makeEngine {
            queue.async {
                runtime.engine = makeEngine(plan.geometry, queue)
            }
        }

        runtime.channel = try dependencies.ptyHost.open(
            command: plan.command,
            workingDirectory: plan.workingDirectory,
            environment: plan.command.environment,
            geometry: plan.geometry,
            deliveringOn: queue
        ) { [weak runtime] event in
            // Sur la queue sérielle de session : l'ordre PTY est l'ordre du transcript.
            switch event {
            case .bytes(let bytes):
                // Le transcript reçoit AVANT le parsing : un crash du moteur ne perd
                // aucun octet déjà lu (NFR-R).
                dependencies.transcript.append(bytes[...], terminal: .primary)
                runtime?.engine?.feed(bytes[...])
            case .endOfFile:
                break   // l'EOF ne conclut jamais — seule vérité : `terminated`
            case .terminated(let status):
                Task {
                    await dependencies.transcript.finish(terminal: .primary)
                    let report = TerminationReport(exitStatus: status)
                    continuation.yield(.terminated(report))
                    continuation.finish()
                    runtime?.onTerminated(report)
                }
            }
        }

        continuation.yield(.started)
        return (runtime, stream)
    }
}

public struct SessionLaunchPlan: Sendable {
    public var command: Command
    public var workingDirectory: URL
    public var geometry: TerminalGeometry
    public init(command: Command, workingDirectory: URL, geometry: TerminalGeometry = .default) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.geometry = geometry
    }
}
