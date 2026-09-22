import Testing
import LoomCore
import LoomTerminal
import LoomTerminalTestSupport
import Foundation

// Integration against the real kernel: forkpty, DispatchIO, NOTE_EXIT. We go
// through the whole SessionRuntime — since conclusion requires exit AND EOF, an
// adapter missing either one fails these tests by construction.

@Suite("ForkPTYHost — real processes", .serialized)
struct ForkPTYHostTests {

    private func plan(_ script: String, extra: [String: String] = [:]) -> SessionLaunchPlan {
        SessionLaunchPlan(
            command: Command(executable: "/bin/sh", arguments: ["-c", script], environment: extra),
            workingDirectory: FileManager.default.temporaryDirectory)
    }

    @Test("a real process end to end: output parsed, transcript complete, exit 0")
    func processReelDeBoutEnBout() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try SessionRuntime.launch(
            plan("printf 'hello from the real pty'"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("no .started")
            return
        }
        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("no .terminated — exit or EOF missing at the call")
            return
        }
        #expect(report.exitStatus.code == 0)
        #expect(transcript.isFinished)
        #expect(transcript.text.contains("hello from the real pty"))
        let screen = await runtime.snapshot()
        #expect(screen.lines[0].text.hasPrefix("hello from the real pty"), "the engine parsed the real output")
    }

    @Test("the constructed environment reaches the child process (PATH included)")
    func environnementAtteintLEnfant() async throws {
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            plan("printf \"%s|%s\" \"$LOOM_MARKER\" \"${PATH:+path-present}\"",
                 extra: ["LOOM_MARKER": "alive"]),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        guard case .terminated = await iterator.next() else { return }
        #expect(transcript.text.contains("alive|path-present"),
                "session overlay AND PATH guaranteed in the child (research §7.3)")
    }

    @Test("graceful stop on a real process: SIGINT is enough for a polite agent")
    func stopGracieuxSurVraiProcess() async throws {
        let (runtime, events) = try SessionRuntime.launch(
            plan("sleep 30"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: MemoryTranscriptSink()))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        try await Task.sleep(for: .milliseconds(150))   // let sh start sleep

        let report = await runtime.stop(.graceful)
        #expect(report.exitStatus.code != 0 || report.exitStatus.signal != nil,
                "the process died before the 30 s deadline, killed by the SIGINT")
    }
}

extension ForkPTYHostTests {
    @Test("resize reaches the real PTY: the process sees the new grid (TRM-02)")
    @MainActor
    func resizeAtteintLeVraiPty() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try SessionRuntime.launch(
            plan("sleep 0.5; stty size"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }

        runtime.surface().resize(cols: 90, rows: 30)

        guard case .terminated = await iterator.next() else { return }
        #expect(transcript.text.contains("30 90"),
                "stty must see 30 rows × 90 cols after TIOCSWINSZ — saw: \(transcript.text)")
    }

    // The ioctl alone proves the kernel knows the grid; the agent must also be
    // TOLD. A process that only prints on SIGWINCH shows whether the signal
    // reaches it — the review drawer's agent kept drawing for its old width.
    @Test("resize signals the process: a SIGWINCH handler sees the new grid")
    @MainActor
    func resizeSignaleLeProcess() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try SessionRuntime.launch(
            plan("trap 'stty size; exit 0' WINCH; sleep 8 & wait"),
            using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        try await Task.sleep(for: .milliseconds(300))   // let sh install its trap

        runtime.surface().resize(cols: 90, rows: 30)

        guard case .terminated = await iterator.next() else {
            Issue.record("the process never heard SIGWINCH: it ran to its 8 s sleep")
            return
        }
        #expect(transcript.text.contains("30 90"),
                "the handler must run with the new grid — saw: \(transcript.text)")
    }
}

// The signal state a child is born with (research §7.6). The app forks from
// the session manager, an actor — a kernel workqueue thread, which XNU starts
// with SIGWINCH, SIGINT, SIGTERM and SIGHUP blocked. `fork` copies that mask,
// `execve` keeps it, and the agent never hears a resize nor a graceful stop.
// Each test here reproduces the birth deterministically: the signal is blocked
// (or ignored) on the forking thread around `launch`, and the probe is perl,
// which does NOT clear its own mask — bash and python don't either; node and
// an interactive zsh do, and would hide the bug.
@Suite("ForkPTYHost — the child's signal state", .serialized)
struct ForkPTYHostSignalTests {

    private static let perlPath = "/usr/bin/perl"
    private static var perlAvailable: Bool { FileManager.default.isExecutableFile(atPath: perlPath) }

    private func perl(_ script: String) -> SessionLaunchPlan {
        SessionLaunchPlan(command: Command(executable: Self.perlPath, arguments: ["-e", script]),
                          workingDirectory: FileManager.default.temporaryDirectory)
    }

    private func launch(_ plan: SessionLaunchPlan, transcript: MemoryTranscriptSink) throws
        -> (runtime: SessionRuntime, events: AsyncStream<SessionRuntime.Event>) {
        try SessionRuntime.launch(
            plan, using: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(), transcript: transcript))
    }

    /// Blocks `number` on the CALLING thread around `body` — `launch` forks
    /// synchronously on it, so the child is born from a thread that had the
    /// signal blocked: the session actor's thread, reproduced. No await inside.
    private func withSignalBlocked<T>(_ number: Int32, _ body: () throws -> T) rethrows -> T {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, number)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &set, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return try body()
    }

    /// SIG_IGN survives execve: a child that reports DEFAULT proves the reset.
    private func withSignalIgnored<T>(_ number: Int32, _ body: () throws -> T) rethrows -> T {
        let previous = signal(number, SIG_IGN)
        defer { _ = signal(number, previous) }
        return try body()
    }

    @Test("born from a thread that blocks SIGWINCH, the child's mask is empty",
          .enabled(if: perlAvailable))
    func masqueVideDansLEnfant() async throws {
        let transcript = MemoryTranscriptSink()
        let (_, events) = try withSignalBlocked(SIGWINCH) {
            try launch(perl(#"use POSIX; $| = 1; my $old = POSIX::SigSet->new; POSIX::sigprocmask(SIG_BLOCK, POSIX::SigSet->new, $old); print $old->ismember(SIGWINCH) ? "mask-blocked" : "mask-clear""#),
                       transcript: transcript)
        }
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        guard case .terminated = await iterator.next() else { return }
        #expect(transcript.text.contains("mask-clear") && !transcript.text.contains("mask-blocked"),
                "the child must not inherit the forking thread's mask — saw: \(transcript.text)")
    }

    @Test("SIGWINCH reaches a handler in a child born from a thread that blocked it",
          .enabled(if: perlAvailable))
    @MainActor
    func sigwinchAtteintLEnfant() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try withSignalBlocked(SIGWINCH) {
            try launch(perl(#"$| = 1; $SIG{WINCH} = sub { system("stty size"); exit 0 }; sleep 8; exit 9"#),
                       transcript: transcript)
        }
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        try await Task.sleep(for: .milliseconds(400))   // let perl install its handler
        let sentAt = ContinuousClock().now

        runtime.surface().resize(cols: 90, rows: 30)

        guard case .terminated(let report) = await iterator.next() else { return }
        #expect(report.exitStatus.code == 0, "the handler exited 0; the 8 s sleep was never reached")
        #expect(ContinuousClock().now - sentAt < .seconds(4), "the handler ran on the signal, not on the timer")
        #expect(transcript.text.contains("30 90"),
                "the handler must see the new grid — saw: \(transcript.text)")
    }

    @Test("SIGINT reaches a child born from a thread that blocked it: the graceful rung is enough",
          .enabled(if: perlAvailable))
    func sigintAtteintLEnfant() async throws {
        let transcript = MemoryTranscriptSink()
        let (runtime, events) = try withSignalBlocked(SIGINT) {
            try launch(perl(#"$| = 1; $SIG{INT} = sub { exit 3 }; sleep 8; exit 9"#), transcript: transcript)
        }
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        try await Task.sleep(for: .milliseconds(400))
        let sentAt = ContinuousClock().now

        let report = await runtime.stop(.graceful)
        #expect(report.exitStatus.code == 3,
                "SIGINT must land on the first rung; a blocked mask escalates to SIGKILL")
        #expect(ContinuousClock().now - sentAt < .seconds(4))
    }

    @Test("an ignored signal in the app is back to its default in the child",
          .enabled(if: perlAvailable))
    func dispositionsRemisesParDefaut() async throws {
        let transcript = MemoryTranscriptSink()
        let (_, events) = try withSignalIgnored(SIGUSR1) {
            try launch(perl(#"$| = 1; print defined $SIG{USR1} ? "usr1-$SIG{USR1}" : "usr1-DEFAULT""#),
                       transcript: transcript)
        }
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        guard case .terminated = await iterator.next() else { return }
        #expect(transcript.text.contains("usr1-DEFAULT"),
                "SIG_IGN survives execve unless the child resets it — saw: \(transcript.text)")
    }

    @Test("a session's master is not inherited by the next session's child")
    func masterNonHerite() async throws {
        // The baseline: what a child sees with nothing else alive.
        let alone = try await fileDescriptorCount()
        // Something alive, whose master would leak into the next fork.
        let (bystander, bystanderEvents) = try launch(
            SessionLaunchPlan(command: Command(executable: "/bin/sh", arguments: ["-c", "sleep 5"]),
                              workingDirectory: FileManager.default.temporaryDirectory),
            transcript: MemoryTranscriptSink())
        var iterator = bystanderEvents.makeAsyncIterator()
        guard case .started = await iterator.next() else { return }
        let withBystander = try await fileDescriptorCount()
        _ = await bystander.stop(.graceful)
        #expect(withBystander == alone,
                "the bystander's master leaked into the child: \(withBystander) descriptors vs \(alone)")
    }

    /// How many descriptors a fresh child finds open (its own 0-2 included).
    private func fileDescriptorCount() async throws -> Int {
        let transcript = MemoryTranscriptSink()
        let (_, events) = try launch(
            SessionLaunchPlan(command: Command(executable: "/bin/sh", arguments: ["-c", "ls /dev/fd | wc -l"]),
                              workingDirectory: FileManager.default.temporaryDirectory),
            transcript: transcript)
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else { return -1 }
        guard case .terminated = await iterator.next() else { return -1 }
        return Int(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
