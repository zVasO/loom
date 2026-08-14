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
        /// Défaut de production : SwiftTermEngine, scrollback TRM-05 (10 000 lignes —
        /// jamais les 500 par défaut de SwiftTerm, pensés mono-session).
        public var makeEngine: @Sendable (TerminalGeometry, DispatchQueue) -> any TerminalEngine
        public init(ptyHost: any PTYHost,
                    transcript: any TranscriptSink,
                    makeEngine: @escaping @Sendable (TerminalGeometry, DispatchQueue) -> any TerminalEngine
                        = { geometry, _ in SwiftTermEngine(geometry: geometry, scrollback: 10_000) }) {
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
    // Barrière de drainage (course EOF/exit, recherche §7.4) : la session ne conclut
    // qu'après avoir vu l'exit ET l'EOF — les octets en vol entre les deux sont donc
    // toujours dans le transcript avant sa fermeture. Confinés à `queue`.
    private var sawEOF = false
    private var exitStatus: ExitStatus?
    private let geometry: TerminalGeometry
    private let lock = NSLock()

    /// Appelé sur la queue de session. Conclut quand exit ET EOF sont là : ferme le
    /// canal, fixe le transcript, émet `.terminated`, termine le flux.
    private func concludeIfDrained(transcript: any TranscriptSink,
                                   continuation: AsyncStream<Event>.Continuation) {
        guard sawEOF, let status = exitStatus else { return }
        channel.close()
        Task {
            await transcript.finish(terminal: .primary)
            let report = TerminationReport(exitStatus: status)
            continuation.yield(.terminated(report))
            continuation.finish()
            self.onTerminated(report)
        }
    }
    private var report: TerminationReport?
    private var isStopping = false
    private var terminationWaiters: [UUID: CheckedContinuation<TerminationReport?, Never>] = [:]
    private var uncancellableWaiters: [CheckedContinuation<TerminationReport, Never>] = []

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
    /// naturelle et en concurrence : un seul appelant déroule l'échelle, tous
    /// reçoivent le même rapport.
    @discardableResult
    public func stop(_ ladder: ShutdownLadder = .graceful) async -> TerminationReport {
        let leadsEscalation: Bool = lock.withLock {
            guard report == nil, !isStopping else { return false }
            isStopping = true
            return true
        }
        guard leadsEscalation else { return await awaitTerminationUncancellable() }

        for step in ladder.steps {
            if let done = currentReport() { return done }
            channel.signal(step.signal, scope: step.scope)
            if let done = await awaitTermination(upTo: step.grace) { return done }
        }
        // Après le dernier échelon (normalement SIGKILL), la sortie est inéluctable ;
        // cette attente ignore l'annulation — `stop` ne rend jamais un état inventé.
        return await awaitTerminationUncancellable()
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
        let sureWaiters = uncancellableWaiters
        uncancellableWaiters = []
        lock.unlock()
        for waiter in waiters.values { waiter.resume(returning: newReport) }
        for waiter in sureWaiters { waiter.resume(returning: newReport) }
    }

    /// Attend la terminaison en ignorant l'annulation : la sortie est certaine
    /// (SIGKILL déjà envoyé, ou un autre appelant déroule l'échelle).
    private func awaitTerminationUncancellable() async -> TerminationReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<TerminationReport, Never>) in
            lock.lock()
            if let report {
                lock.unlock()
                continuation.resume(returning: report)
                return
            }
            uncancellableWaiters.append(continuation)
            lock.unlock()
        }
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

        // Soumis avant `open` : sur la queue sérielle, `.started` précède donc
        // structurellement tout événement que le sink pourra délivrer — même un
        // exit immédiat (exec échoué) ne peut pas le devancer.
        queue.async {
            runtime.engine = dependencies.makeEngine(plan.geometry, queue)
            continuation.yield(.started)
        }

        runtime.channel = try dependencies.ptyHost.open(
            command: plan.command,
            workingDirectory: plan.workingDirectory,
            environment: Self.childEnvironment(overlay: plan.command.environment),
            geometry: plan.geometry,
            deliveringOn: queue
        ) { event in
            // Capture FORTE délibérée : la session vit tant que son process vit, même si
            // l'appelant lâche sa poignée — le transcript ne dépend d'aucune référence
            // de la couche vue (NFR-R). Le cycle runtime → channel → sink → runtime se
            // rompt à la conclusion, quand `close()` libère le sink (contrat PTYChannel).
            // Sur la queue sérielle de session : l'ordre PTY est l'ordre du transcript.
            switch event {
            case .bytes(let bytes):
                // Le transcript reçoit AVANT le parsing : un crash du moteur ne perd
                // aucun octet déjà lu (NFR-R).
                dependencies.transcript.append(bytes[...], terminal: .primary)
                runtime.engine?.feed(bytes[...])
            case .endOfFile:
                runtime.sawEOF = true
                runtime.concludeIfDrained(transcript: dependencies.transcript, continuation: continuation)
            case .terminated(let status):
                runtime.exitStatus = status
                runtime.concludeIfDrained(transcript: dependencies.transcript, continuation: continuation)
            }
        }

        return (runtime, stream)
    }
}

extension SessionRuntime {
    /// Environnement COMPLET du process enfant : base héritée de l'app + réglages
    /// terminal + `PATH` toujours présent (SwiftTerm l'omet de son environnement par
    /// défaut — recherche §7.3), puis l'overlay de la session qui gagne toute collision.
    /// La résolution du PATH depuis le shell de login (GIT-06) viendra avec
    /// l'EnvironmentResolver ; en attendant, l'héritage de l'app + repli système.
    static func childEnvironment(overlay: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["PATH"]?.isEmpty != false {
            environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        environment.merge(overlay) { _, session in session }
        return environment
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
