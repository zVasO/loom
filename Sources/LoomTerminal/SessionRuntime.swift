import LoomCore
import Dispatch
import Foundation

/// Everything alive in a session: the agent process on its PTY, the tee to the
/// Transcript, and (upcoming slices) the terminal engine, sampling, and the view
/// surfaces. Interface decision: docs/design/session-runtime.md, ADR-0008.
public final class SessionRuntime: @unchecked Sendable {

    /// Internal seams with defaults — no production caller ever names them.
    public struct Dependencies: Sendable {
        public var ptyHost: any PTYHost
        public var transcript: any TranscriptSink
        /// Production default: SwiftTermEngine with the TRM-05 scrollback (10,000 lines —
        /// never SwiftTerm's 500-line default, which assumes a single session).
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
        /// Raw material for the STA-02 heuristic channel — emitted at the
        /// `SessionLaunchPlan.samplingInterval` cadence (never when `nil`). The runtime
        /// measures; it does not interpret.
        case activity(ActivitySample)
        /// Always the last event; the stream finishes right after. By the time a caller
        /// receives it, the transcript is complete and closed (drainage barrier).
        case terminated(TerminationReport)
    }

    public struct ActivitySample: Sendable {
        public let at: ContinuousClock.Instant
        public let bytesSinceLastSample: Int
        /// Since the last byte received from the PTY.
        public let silence: Duration
        /// Last non-empty lines of the visible screen, plain text only.
        public let visibleTail: [String]
        public let cpuFraction: Double
        public init(at: ContinuousClock.Instant, bytesSinceLastSample: Int, silence: Duration,
                    visibleTail: [String], cpuFraction: Double) {
            self.at = at
            self.bytesSinceLastSample = bytesSinceLastSample
            self.silence = silence
            self.visibleTail = visibleTail
            self.cpuFraction = cpuFraction
        }
    }

    public struct TerminationReport: Sendable {
        public let exitStatus: ExitStatus
    }

    private let queue: DispatchQueue
    private var channel: (any PTYChannel)!
    /// Confined to `queue`, no exceptions (ADR-0007). Created and fed on the session queue.
    private var engine: (any TerminalEngine)?
    // Drainage barrier (EOF/exit race, research §7.4): the session only concludes
    // after seeing BOTH the exit AND the EOF — so bytes in flight between the two are
    // always in the transcript before it closes. Confined to `queue`.
    private var sawEOF = false
    private var exitStatus: ExitStatus?
    // Heuristic sampling (confined to `queue`).
    private var samplingTimer: DispatchSourceTimer?
    private var bytesSinceLastSample = 0
    private var lastByteAt: ContinuousClock.Instant?
    private let geometry: TerminalGeometry
    /// Launch geometry, readable by the surface factory (MainActor).
    var launchGeometry: TerminalGeometry { geometry }
    /// Shared projections, MainActor-confined (one per TerminalID).
    @MainActor var surfaces: [TerminalID: TerminalSurface] = [:]
    /// Terminals with at least one attached surface — read on the queue for every byte
    /// batch, protected by the lock (no rendering for sessions that are not visible).
    private var attachedTerminals: Set<TerminalID> = []
    /// Coalescing: at most one frame in flight (confined to the session queue).
    private var frameScheduled = false
    private let lock = NSLock()

    /// TRM-02: synchronized resize, view → engine → PTY (TIOCSWINSZ). One operation
    /// for the caller, two internally; the process receives SIGWINCH and repaints.
    /// Last value wins, and a frame is pushed right away.
    func resize(to geometry: TerminalGeometry) {
        queue.async {
            self.engine?.resize(to: geometry)
            self.channel.resize(to: geometry)
            self.scheduleFrame()
        }
    }

    /// Write to the terminal's PTY (keystrokes, quick message SES-05).
    /// Non-blocking: one hop onto the session queue, then the channel.
    func write(_ text: String, to terminal: TerminalID) {
        let bytes = Array(text.utf8)
        queue.async { self.channel.write(bytes[...]) }
    }

    /// Called from the MainActor by the surfaces; attaching immediately paints the
    /// current screen (reattachment path < 100 ms, TRM-03).
    func setAttachment(_ terminal: TerminalID, attached: Bool) {
        lock.withLock {
            if attached { attachedTerminals.insert(terminal) } else { attachedTerminals.remove(terminal) }
        }
        if attached {
            queue.async { self.deliverFrame() }
        }
    }

    // P0 perf: frames used to fire at network-chunk rate (each paying a full
    // snapshot + history extraction). The cap coalesces them: leading edge
    // immediate, trailing edge scheduled — at most 1000/interval frames per
    // second regardless of the output rate. Confined to the session queue.
    private var frameInterval: Duration = .milliseconds(33)
    private var lastFrameAt: ContinuousClock.Instant?

    /// The user's refresh-rate setting (30/60/120 fps). Applied on the queue.
    public func setFrameInterval(_ interval: Duration) {
        queue.async { self.frameInterval = interval }
    }

    /// On the session queue: schedules at most one frame delivery per interval.
    private func scheduleFrame() {
        let anyoneWatching = lock.withLock { !attachedTerminals.isEmpty }
        guard anyoneWatching, !frameScheduled else { return }
        frameScheduled = true
        let now = ContinuousClock().now
        let sinceLast = lastFrameAt.map { now - $0 } ?? frameInterval
        let remaining = frameInterval - sinceLast
        let deliver = {
            self.frameScheduled = false
            self.lastFrameAt = ContinuousClock().now
            self.deliverFrame()
        }
        if remaining <= .zero {
            queue.async(execute: deliver)
        } else {
            let nanoseconds = remaining.components.seconds * 1_000_000_000
                + remaining.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)),
                             execute: deliver)
        }
    }

    /// On the session queue: copies the screen and delivers it to the attached surfaces.
    private func deliverFrame() {
        let watching = lock.withLock { attachedTerminals }
        guard !watching.isEmpty, let engine else { return }
        let snapshot = engine.snapshot()
        let history = engine.historyTail(400)
        let base = engine.scrollbackRows - history.count
        Task { @MainActor in
            for terminal in watching {
                self.surfaces[terminal]?.receive(snapshot, history: history, base: base)
            }
        }
    }

    /// On the session queue: measures and emits a sample (STA-02). The runtime
    /// decides no state — interpretation belongs to the session layer.
    private func emitSample(_ continuation: AsyncStream<Event>.Continuation) {
        let now = ContinuousClock().now
        let tail = (engine?.snapshot().lines ?? [])
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(12)
        continuation.yield(.activity(ActivitySample(
            at: now,
            bytesSinceLastSample: bytesSinceLastSample,
            silence: lastByteAt.map { now - $0 } ?? .zero,
            visibleTail: Array(tail),
            cpuFraction: channel.cpuFraction())))
        bytesSinceLastSample = 0
    }

    /// Called on the session queue. Concludes once BOTH exit AND EOF are in: closes
    /// the channel, seals the transcript, emits `.terminated`, finishes the stream.
    private func concludeIfDrained(transcript: any TranscriptSink,
                                   continuation: AsyncStream<Event>.Continuation) {
        guard sawEOF, let status = exitStatus else { return }
        samplingTimer?.cancel()
        samplingTimer = nil
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

    /// Current visible screen of the primary terminal, with every byte received so far parsed.
    /// Cost: one hop onto the session queue + one O(cols × rows) copy.
    public func snapshot() async -> TerminalScreen {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.engine?.snapshot() ?? .blank(self.geometry))
            }
        }
    }

    /// Escalated shutdown (SES-06). Idempotent, never throws, valid after a natural
    /// exit and under concurrency: a single caller walks the ladder, everyone
    /// receives the same report.
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
        // After the last rung (normally SIGKILL), exit is inevitable; this wait
        // ignores cancellation — `stop` never returns a made-up state.
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

    /// Waits for termination, ignoring cancellation: exit is certain (SIGKILL
    /// already sent, or another caller is walking the ladder).
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

    /// Waits for termination for at most `grace` (nil = unbounded). Cleanly cancellable:
    /// the grace period and the real exit race each other without leaking a continuation.
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

    /// The event stream is handed out here and only once: structurally single-consumer.
    public static func launch(_ plan: SessionLaunchPlan,
                              using dependencies: Dependencies) throws -> (runtime: SessionRuntime, events: AsyncStream<Event>) {
        let queue = DispatchQueue(label: "app.loom.session")
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let runtime = SessionRuntime(queue: queue, geometry: plan.geometry)

        // Submitted before `open`: on the serial queue, `.started` therefore
        // structurally precedes any event the sink could deliver — even an
        // immediate exit (failed exec) cannot get ahead of it.
        queue.async {
            runtime.engine = dependencies.makeEngine(plan.geometry, queue)
            continuation.yield(.started)
            if let interval = plan.samplingInterval {
                let seconds = Double(interval.components.seconds)
                    + Double(interval.components.attoseconds) / 1e18
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + seconds, repeating: seconds)
                timer.setEventHandler { [weak runtime] in
                    runtime?.emitSample(continuation)
                }
                timer.activate()
                runtime.samplingTimer = timer
            }
        }

        runtime.channel = try dependencies.ptyHost.open(
            command: plan.command,
            workingDirectory: plan.workingDirectory,
            environment: Self.childEnvironment(overlay: plan.command.environment),
            geometry: plan.geometry,
            deliveringOn: queue
        ) { event in
            // Deliberate STRONG capture: the session lives as long as its process, even
            // if the caller drops its handle — the transcript depends on no reference
            // from the view layer (NFR-R). The runtime → channel → sink → runtime cycle
            // breaks at conclusion, when `close()` releases the sink (PTYChannel contract).
            // On the serial session queue: PTY order is transcript order.
            switch event {
            case .bytes(let bytes):
                // The transcript receives bytes BEFORE parsing: an engine crash loses
                // no byte already read (NFR-R).
                dependencies.transcript.append(bytes[...], terminal: .primary)
                runtime.engine?.feed(bytes[...])
                runtime.bytesSinceLastSample += bytes.count
                runtime.lastByteAt = ContinuousClock().now
                runtime.scheduleFrame()
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
    /// COMPLETE child-process environment: base inherited from the app + terminal
    /// settings + `PATH` always present (SwiftTerm omits it from its default
    /// environment — research §7.3), then the session overlay, which wins every
    /// collision. PATH resolution from the login shell (GIT-06) will come with the
    /// EnvironmentResolver; until then, app inheritance + system fallback.
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
    /// Cadence of the heuristic channel (STA-02). `nil` = no sampling —
    /// hook-driven sessions don't need it.
    public var samplingInterval: Duration?
    public init(command: Command, workingDirectory: URL, geometry: TerminalGeometry = .default,
                samplingInterval: Duration? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.geometry = geometry
        self.samplingInterval = samplingInterval
    }
}
