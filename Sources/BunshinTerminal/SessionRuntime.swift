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
        public init(ptyHost: any PTYHost, transcript: any TranscriptSink) {
            self.ptyHost = ptyHost
            self.transcript = transcript
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
    private let channel: any PTYChannel

    private init(queue: DispatchQueue, channel: any PTYChannel) {
        self.queue = queue
        self.channel = channel
    }

    /// Le flux d'événements est rendu ici et une seule fois : mono-consommateur structurel.
    public static func launch(_ plan: SessionLaunchPlan,
                              using dependencies: Dependencies) throws -> (runtime: SessionRuntime, events: AsyncStream<Event>) {
        let queue = DispatchQueue(label: "app.bunshin.session")
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)

        let channel = try dependencies.ptyHost.open(
            command: plan.command,
            workingDirectory: plan.workingDirectory,
            environment: plan.command.environment,
            geometry: plan.geometry,
            deliveringOn: queue
        ) { event in
            // Sur la queue sérielle de session : l'ordre PTY est l'ordre du transcript.
            switch event {
            case .bytes(let bytes):
                dependencies.transcript.append(bytes[...], terminal: .primary)
            case .endOfFile:
                break   // l'EOF ne conclut jamais — seule vérité : `terminated`
            case .terminated(let status):
                Task {
                    await dependencies.transcript.finish(terminal: .primary)
                    continuation.yield(.terminated(TerminationReport(exitStatus: status)))
                    continuation.finish()
                }
            }
        }

        continuation.yield(.started)
        return (SessionRuntime(queue: queue, channel: channel), stream)
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
