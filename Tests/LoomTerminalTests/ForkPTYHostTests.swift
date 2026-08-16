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
}
