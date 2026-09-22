import Testing
import LoomCore
import LoomTerminal
import LoomTerminalTestSupport
import Foundation

// Tests at the agreed seam: SessionRuntime's public interface, via ScriptedPTYHost.
// No test crosses the session queue or touches the engine.

@Suite("SessionRuntime — lifecycle")
struct SessionRuntimeTests {

    // The engine's own voice: a program queries the terminal (DA, DSR, and the
    // mouse reports that carry scrolling) and expects an answer on the PTY.
    // Unplugged, that channel makes a full-screen agent unscrollable.
    @Test("what the terminal answers on its own reaches the PTY")
    func reponsesDuTerminalRemontentAuPTY() async throws {
        let pty = ScriptedPTYHost()
        _ = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty,
                transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in
                    SwiftTermEngine(geometry: geometry, scrollback: 100)
                })
        )
        pty.emit("\u{1B}[6n")   // DSR — "where is your cursor?"
        #expect(await pollUntil {
            String(decoding: pty.writtenBytes, as: UTF8.self).contains("\u{1B}[1;1R")
        }, "no answer means the program talks to a wall")
    }

    @Test("launch starts the agent and emits .started first")
    func launchEmetStarted() async throws {
        let pty = ScriptedPTYHost()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("the first event must be .started")
            return
        }
    }

    @Test("exit concludes: transcript complete and flushed before .terminated, stream ends after")
    func exitConclutAvecTranscriptComplet() async throws {
        let pty = ScriptedPTYHost()
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }

        pty.emit("Analyzing the repository…\r\n")
        pty.emit("Fix applied, 42 tests green.\r\n")
        pty.exit(code: 0)

        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("process exit must emit .terminated")
            return
        }
        #expect(report.exitStatus.code == 0)
        #expect(transcript.isFinished, "the transcript is flushed and closed BEFORE .terminated (NFR-R)")
        #expect(transcript.text.contains("42 tests green"),
                "no byte emitted before the exit is missing from the transcript")
        #expect(await iterator.next() == nil, "the stream ends right after .terminated")
    }

    @Test("an agent deaf to SIGINT and SIGTERM ends up SIGKILLed, in ladder order (SES-06)")
    func escaladeJusquAuKill() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .kill = signal { host.exit(bySignal: 9) }   // only SIGKILL gets the better of it
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let ladder = ShutdownLadder(steps: [
            .init(signal: .interrupt, scope: .process, grace: .milliseconds(20)),
            .init(signal: .terminate, scope: .group, grace: .milliseconds(20)),
            .init(signal: .kill, scope: .group, grace: .milliseconds(200)),
        ])
        let report = await runtime.stop(ladder)

        // SES-06: graceful SIGINT to the agent alone, escalation hits the whole group.
        #expect(pty.receivedSignals == [
            .init(signal: .interrupt, scope: .process),
            .init(signal: .terminate, scope: .group),
            .init(signal: .kill, scope: .group),
        ])
        #expect(report.exitStatus.code == nil)
        #expect(report.exitStatus.signal == 9)
    }

    @Test("escalation stops as soon as the agent exits")
    func escaladeInterrompueParLaSortie() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .interrupt = signal { host.exit(code: 130) }   // polite agent
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let report = await runtime.stop(.graceful)

        #expect(pty.receivedSignals == [.init(signal: .interrupt, scope: .process)],
                "no SIGTERM or SIGKILL for an agent that obeys, and the SIGINT hits the agent only")
        #expect(report.exitStatus.code == 130)
    }

    @Test("PTY bytes feed the engine; snapshot() returns the current screen")
    func snapshotRefleteLEcran() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty,
                                               transcript: MemoryTranscriptSink(),
                                               makeEngine: { geometry, _ in LineEngine(geometry: geometry) }))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }

        pty.emit("Analyzing the repository…\r\n")
        pty.emit("Fix applied.")

        let screen = await runtime.snapshot()
        let texts = screen.lines.map(\.text)
        #expect(texts.contains("Analyzing the repository…"))
        #expect(texts.contains("Fix applied."), "the last chunk is already parsed when snapshot returns")
    }

    @Test("without configuration, the production engine parses the output (SwiftTerm default)")
    func moteurParDefaut() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }

        pty.emit("\u{1B}[32mready\u{1B}[0m")
        let screen = await runtime.snapshot()
        #expect(screen.lines[0].text.hasPrefix("ready"), "the default is not a blank screen: SwiftTerm parses")
        #expect(screen.lines[0].cells[0].style.foreground == .ansi(2))
    }

    @Test("the runtime samples: bytes, silence, screen tail (STA-02)")
    func echantillonnageHeuristique() async throws {
        let pty = ScriptedPTYHost()
        var plan = SessionLaunchPlan(command: Command(executable: "/fake/codex"),
                                     workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))
        plan.samplingInterval = .milliseconds(30)
        let (_, events) = try SessionRuntime.launch(
            plan,
            using: SessionRuntime.Dependencies(ptyHost: pty,
                                               transcript: MemoryTranscriptSink(),
                                               makeEngine: { geometry, _ in LineEngine(geometry: geometry) }))

        pty.emit("prompt $ ")

        var sawActivity = false
        var sawQuietTail = false
        for await event in events {
            if case .activity(let sample) = event {
                sawActivity = true
                if sample.bytesSinceLastSample == 0,
                   sample.silence >= .milliseconds(30),
                   sample.visibleTail.last?.hasPrefix("prompt $") == true {
                    sawQuietTail = true
                    break
                }
            }
        }
        #expect(sawActivity, "samples arrive on the event stream")
        #expect(sawQuietTail, "after the calm: zero bytes, measured silence, prompt pattern visible")
    }

    @Test("late bytes after exit are drained before conclusion (EOF/exit race)")
    func drainageAvantConclusion() async throws {
        let pty = ScriptedPTYHost()
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: transcript))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }

        // Adversarial order documented by the research (§7.4): the exit arrives
        // BEFORE the last PTY bytes, the EOF closes the parade.
        pty.deliverTerminated(code: 0)
        pty.emit("last batch of bytes in flight")
        pty.emitEOF()

        guard case .terminated = await iterator.next() else {
            Issue.record("no .terminated")
            return
        }
        #expect(transcript.text.contains("last batch of bytes in flight"),
                "bytes in flight after the exit are part of the transcript")
        #expect(!transcript.appendedAfterFinish,
                "no byte is written after the transcript is closed (barrier)")
        #expect(pty.closeCount == 1, "the PTY channel is closed at conclusion")
    }

    @Test("two concurrent stop() calls do not replay the ladder: a single SIGINT goes out")
    func stopConcurrentsSingleFlight() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            guard case .interrupt = signal else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
                host.exit(code: 130)
            }
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        async let first = runtime.stop(.graceful)     // user confirmation
        async let second = runtime.stop(.graceful)    // app closing at the same moment
        let (r1, r2) = await (first, second)

        #expect(pty.receivedSignals == [.init(signal: .interrupt, scope: .process)],
                "the second call waits for the first one's outcome, it does not re-signal")
        #expect(r1.exitStatus.code == 130)
        #expect(r2.exitStatus.code == 130, "every caller receives the same report")
    }

    @Test("a cancelled stop() does not invent an outcome: it waits for the real exit")
    func stopAnnuleAttendLaVraieSortie() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .kill = signal { host.exit(bySignal: 9) }
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let ladder = ShutdownLadder(steps: [
            .init(signal: .interrupt, scope: .process, grace: .milliseconds(50)),
            .init(signal: .kill, scope: .group, grace: .milliseconds(200)),
        ])
        let stopTask = Task { await runtime.stop(ladder) }
        try await Task.sleep(for: .milliseconds(10))
        stopTask.cancel()

        let report = await stopTask.value
        #expect(report.exitStatus.signal == 9,
                "despite the task cancellation, the report is the process's real outcome")
    }

    @Test("the child environment is complete: PATH guaranteed, the session overlay wins")
    func environnementCompletAvecPath() async throws {
        let pty = ScriptedPTYHost()
        _ = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude",
                                               environment: ["LOOM_EXTRA": "yes", "LANG": "fr_FR.UTF-8"]),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        #expect(pty.openedEnvironment["PATH"]?.isEmpty == false,
                "SwiftTerm omits PATH; the runtime must guarantee it (research §7.3)")
        #expect(pty.openedEnvironment["LOOM_EXTRA"] == "yes", "the session's variables pass through")
        #expect(pty.openedEnvironment["LANG"] == "fr_FR.UTF-8", "the overlay wins over the base on collision")
        #expect(pty.openedEnvironment["TERM"] == "xterm-256color", "the terminal base is set")
    }
    @Test("an exec that fails instantly still concludes")
    func exitImmediatConclut() async throws {
        let pty = InstantExitPTYHost(exitCode: 127)
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/nonexistent/agent"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }
        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("an exit delivered before the channel is stored must still conclude")
            return
        }
        #expect(report.exitStatus.code == 127)
        #expect(await iterator.next() == nil, "the stream ends right after .terminated")
    }

    /// Bounded active wait (2 s) — the PTY → queue → PTY path is asynchronous by nature.
    private func pollUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // TRM-02: the runtime owns the dedup, against the grid it actually applied.
    // A surface-side memory could disagree with the PTY — and a resize that
    // never reaches the PTY leaves the agent drawing for a pane it no longer has.
    @Test("resize: only a genuinely new geometry reaches the PTY, every new one does")
    @MainActor
    func resizeDedupliqueContreLaGrilleAppliquee() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 53, rows: 45)),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))
        let surface = runtime.surface()

        surface.resize(cols: 53, rows: 45)   // the launch grid: nothing to do
        surface.resize(cols: 88, rows: 45)   // the drawer widened
        surface.resize(cols: 88, rows: 45)   // the same pane measured twice
        surface.resize(cols: 88, rows: 46)   // the window grew
        surface.resize(cols: 19, rows: 46)   // below the column floor: refused
        surface.resize(cols: 88, rows: 4)    // below the row floor: refused

        #expect(await pollUntil { pty.resizes.count == 2 })
        #expect(pty.resizes == [TerminalGeometry(cols: 88, rows: 45),
                                TerminalGeometry(cols: 88, rows: 46)])
        #expect(await runtime.currentGeometry() == TerminalGeometry(cols: 88, rows: 46))
    }

    // The readiness probe reads the runtime, not a surface: it must tell the
    // truth with NO pane attached — the review drawer may not be open yet.
    @Test("readiness: bytes, bracketed paste and the prompt line, with nobody watching")
    func readinessSansSurfaceAttachee() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                              geometry: TerminalGeometry(cols: 40, rows: 6)),
            using: SessionRuntime.Dependencies(
                ptyHost: pty,
                transcript: MemoryTranscriptSink(),
                makeEngine: { geometry, _ in SwiftTermEngine(geometry: geometry, scrollback: 100) }))

        let blank = await runtime.readiness()
        #expect(blank.bytesReceived == 0)
        #expect(!blank.modes.bracketedPaste)
        #expect(blank.visibleTail.isEmpty)
        #expect(!AgentReadiness.isReady(blank))

        pty.emit("\u{1B}[?2004hClaude Code v2.1\r\n> ")
        #expect(await pollUntil2 { await runtime.readiness().bytesReceived > 0 })
        try await Task.sleep(for: AgentReadiness.settleDuration)
        let painted = await runtime.readiness()
        #expect(painted.modes.bracketedPaste)
        #expect(painted.visibleTail.last == ">")
        #expect(painted.silence >= AgentReadiness.settleDuration)
        #expect(AgentReadiness.isReady(painted))
    }

    private func pollUntil2(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

}

/// An exec that fails instantly: the process is already gone when `open` returns,
/// so the whole termination is drained on the session queue BEFORE the caller can
/// store the channel — the conclusion has to survive that.
private final class InstantExitPTYHost: PTYHost, @unchecked Sendable {
    private let exitCode: Int32
    init(exitCode: Int32) { self.exitCode = exitCode }

    func open(command: Command,
              workingDirectory: URL,
              environment: [String: String],
              geometry: TerminalGeometry,
              deliveringOn queue: DispatchQueue,
              sink: @escaping @Sendable (PTYEvent) -> Void) throws -> any PTYChannel {
        let code = exitCode
        let delivered = DispatchSemaphore(value: 0)
        queue.async {
            sink(.terminated(ExitStatus(code: code)))
            sink(.endOfFile)
            delivered.signal()
        }
        delivered.wait()
        return InertChannel()
    }
}

private final class InertChannel: PTYChannel, @unchecked Sendable {
    func write(_ bytes: ArraySlice<UInt8>) {}
    func resize(to geometry: TerminalGeometry) {}
    func signal(_ signal: PTYSignal, scope: PTYSignalScope) {}
    func close() {}
    var capabilities: PTYCapabilities { [] }
    var processGroup: pid_t? { nil }
    func cpuFraction() -> Double { 0 }
}
