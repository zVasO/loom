import LoomCore
import Dispatch
import Foundation

// Byte-source seam (decision in docs/design/session-runtime.md, shape of candidate B).
// Adapters: ForkPTYHost (prod v1), ScriptedPTYHost (test), TmuxPTYHost (v2, ADR-0006).
//
// The contract deliberately exposes NO file descriptor: a tmux backend has none to
// offer. `PTYEvent` makes the EOF/exit ordering explicit and therefore testable — the
// two events arrive in no guaranteed order, and only `terminated` concludes.

public protocol PTYHost: Sendable {
    /// Opens a channel. `sink` is called ONLY on `queue`, and never again after `close()`.
    /// The environment passed in is complete (the runtime has already built the base + PATH).
    func open(command: Command,
              workingDirectory: URL,
              environment: [String: String],
              geometry: TerminalGeometry,
              deliveringOn queue: DispatchQueue,
              sink: @escaping @Sendable (PTYEvent) -> Void) throws -> any PTYChannel
}

public enum PTYEvent: Sendable {
    /// Slice valid only for the duration of the sink call — copy to retain.
    case bytes([UInt8])
    /// Informational: NEVER terminates a session (SwiftTerm research §7.4).
    case endOfFile
    /// Sole source of truth for process termination and its exit code.
    case terminated(ExitStatus)
}

public protocol PTYChannel: AnyObject, Sendable {
    func write(_ bytes: ArraySlice<UInt8>)
    /// TIOCSWINSZ (forkpty) / refresh-client (tmux). The engine is resized separately.
    func resize(to geometry: TerminalGeometry)
    /// SES-06 distinguishes the target: graceful SIGINT to the agent alone (`.process`),
    /// SIGTERM/SIGKILL escalation to the whole group (`.group`) to reach descendants
    /// (TRM-02) — otherwise a SIGINT would also hit the builds/tests the agent
    /// has launched.
    func signal(_ signal: PTYSignal, scope: PTYSignalScope)
    /// Idempotent; delivers nothing after returning, and RELEASES the sink reference
    /// (which is what breaks the sink → runtime retain cycle at conclusion).
    func close()
    var capabilities: PTYCapabilities { get }
    /// `nil` for a backend with no reachable process group (tmux).
    var processGroup: pid_t? { get }
    /// CPU fraction 0…1 for the group (proc_pid_rusage) — input to the STA-02 heuristic.
    func cpuFraction() -> Double
}

public enum PTYSignal: Sendable {
    case interrupt   // SIGINT
    case terminate   // SIGTERM
    case kill        // SIGKILL
}

public enum PTYSignalScope: Sendable {
    /// The agent process alone (kill(pid, …)).
    case process
    /// The whole process group (kill(-pgid, …)).
    case group
}

public struct PTYCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let signals = PTYCapabilities(rawValue: 1 << 0)      // reachable process group
    public static let survivesHost = PTYCapabilities(rawValue: 1 << 1) // true persistence (tmux, v2)
    public static let cpuSampling = PTYCapabilities(rawValue: 1 << 2)  // proc_pid_rusage available
}

public struct ExitStatus: Sendable, Equatable {
    /// `nil` if the process was killed by a signal.
    public let code: Int32?
    public let signal: Int32?
    public init(code: Int32?, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }
}

/// The shutdown escalation is data, not code: testable under an injected clock (SES-06).
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

    /// SES-06: graceful SIGINT to the agent, then SIGTERM to the group after 5 s, then SIGKILL.
    public static let graceful = ShutdownLadder(steps: [
        Step(signal: .interrupt, scope: .process, grace: .seconds(5)),
        Step(signal: .terminate, scope: .group, grace: .seconds(5)),
        Step(signal: .kill, scope: .group, grace: .seconds(1)),
    ])

    /// Tab close: the DOUBLE SIGINT of the user's "Ctrl+C Ctrl+C" — claude ignores
    /// the first one ("press ctrl-c again") and exits cleanly on the second;
    /// SIGTERM/SIGKILL serve only as a safety net.
    public static let close = ShutdownLadder(steps: [
        Step(signal: .interrupt, scope: .process, grace: .milliseconds(350)),
        Step(signal: .interrupt, scope: .process, grace: .milliseconds(1200)),
        Step(signal: .terminate, scope: .group, grace: .seconds(2)),
        Step(signal: .kill, scope: .group, grace: .seconds(1)),
    ])
    public static let immediate = ShutdownLadder(steps: [Step(signal: .kill, scope: .group, grace: .seconds(1))])
}
