import LoomCore
import Dispatch
import Foundation

// Seam de la source d'octets (décision docs/design/session-runtime.md, forme du candidat B).
// Adapters : ForkPTYHost (prod v1), ScriptedPTYHost (test), TmuxPTYHost (v2, ADR-0006).
//
// Le contrat est délibérément SANS descripteur de fichier : un backend tmux n'en a pas
// à offrir. `PTYEvent` rend l'ordre EOF/exit explicite et donc testable — les deux
// événements arrivent dans un ordre non garanti, et seul `terminated` conclut.

public protocol PTYHost: Sendable {
    /// Ouvre un canal. `sink` n'est appelé QUE sur `queue`, et plus jamais après `close()`.
    /// L'environnement transmis est complet (le runtime a déjà construit la base + PATH).
    func open(command: Command,
              workingDirectory: URL,
              environment: [String: String],
              geometry: TerminalGeometry,
              deliveringOn queue: DispatchQueue,
              sink: @escaping @Sendable (PTYEvent) -> Void) throws -> any PTYChannel
}

public enum PTYEvent: Sendable {
    /// Slice valide uniquement pendant l'appel du sink — copier pour conserver.
    case bytes([UInt8])
    /// Informatif : ne termine JAMAIS une session (recherche SwiftTerm §7.4).
    case endOfFile
    /// Seule vérité sur la fin du process et son code de sortie.
    case terminated(ExitStatus)
}

public protocol PTYChannel: AnyObject, Sendable {
    func write(_ bytes: ArraySlice<UInt8>)
    /// TIOCSWINSZ (forkpty) / refresh-client (tmux). Le moteur est redimensionné à part.
    func resize(to geometry: TerminalGeometry)
    /// SES-06 distingue la cible : SIGINT gracieux à l'agent seul (`.process`),
    /// l'escalade SIGTERM/SIGKILL au groupe entier (`.group`) pour atteindre les
    /// descendants (TRM-02) — sans quoi un SIGINT frapperait aussi les builds/tests
    /// que l'agent a lancés.
    func signal(_ signal: PTYSignal, scope: PTYSignalScope)
    /// Idempotent ; ne délivre plus rien après retour, et LIBÈRE la référence au sink
    /// (c'est ce qui rompt le cycle de rétention sink → runtime à la conclusion).
    func close()
    var capabilities: PTYCapabilities { get }
    /// `nil` pour un backend sans process group joignable (tmux).
    var processGroup: pid_t? { get }
    /// Fraction CPU 0…1 du groupe (proc_pid_rusage) — matière de l'heuristique STA-02.
    func cpuFraction() -> Double
}

public enum PTYSignal: Sendable {
    case interrupt   // SIGINT
    case terminate   // SIGTERM
    case kill        // SIGKILL
}

public enum PTYSignalScope: Sendable {
    /// Le process de l'agent seul (kill(pid, …)).
    case process
    /// Le groupe de process entier (kill(-pgid, …)).
    case group
}

public struct PTYCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let signals = PTYCapabilities(rawValue: 1 << 0)      // process group joignable
    public static let survivesHost = PTYCapabilities(rawValue: 1 << 1) // vraie persistance (tmux, v2)
    public static let cpuSampling = PTYCapabilities(rawValue: 1 << 2)  // proc_pid_rusage possible
}

public struct ExitStatus: Sendable, Equatable {
    /// `nil` si le process a été tué par un signal.
    public let code: Int32?
    public let signal: Int32?
    public init(code: Int32?, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }
}

/// L'escalade d'arrêt est une donnée, pas du code : testable sous horloge injectée (SES-06).
public struct ShutdownLadder: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let signal: PTYSignal
        public let scope: PTYSignalScope
        public let grace: Duration
        public init(signal: PTYSignal, scope: PTYSignalScope, grace: Duration) {
            self.signal = signal
            self.scope = scope
            self.grace = grace
        }
    }
    public var steps: [Step]
    public init(steps: [Step]) { self.steps = steps }

    /// SES-06 : SIGINT gracieux à l'agent, puis SIGTERM au groupe après 5 s, puis SIGKILL.
    public static let graceful = ShutdownLadder(steps: [
        Step(signal: .interrupt, scope: .process, grace: .seconds(5)),
        Step(signal: .terminate, scope: .group, grace: .seconds(5)),
        Step(signal: .kill, scope: .group, grace: .seconds(1)),
    ])

    /// Fermeture d'onglet : le DOUBLE SIGINT du « Ctrl+C Ctrl+C » utilisateur —
    /// claude ignore le premier (« press ctrl-c again ») et sort proprement au
    /// second ; SIGTERM/SIGKILL ne servent que de filet.
    public static let close = ShutdownLadder(steps: [
        Step(signal: .interrupt, scope: .process, grace: .milliseconds(350)),
        Step(signal: .interrupt, scope: .process, grace: .seconds(2)),
        Step(signal: .terminate, scope: .group, grace: .seconds(3)),
        Step(signal: .kill, scope: .group, grace: .seconds(1)),
    ])
    public static let immediate = ShutdownLadder(steps: [Step(signal: .kill, scope: .group, grace: .seconds(1))])
}
