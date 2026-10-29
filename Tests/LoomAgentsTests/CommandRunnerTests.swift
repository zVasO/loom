import Testing
import Foundation
import LoomAPI
@testable import LoomAgents

// A workflow's command step (ADR-0019): its exit code, the end of its
// output, a deadline that stops it and its children, and an environment
// without Loom's socket or tokens.
@Suite("CommandRunner")
struct CommandRunnerTests {

    private let sh = URL(fileURLWithPath: "/bin/sh")
    private var folder: URL { FileManager.default.temporaryDirectory }

    @Test("the exit code and the output; the step's variables in, Loom's tokens out")
    func sortie() async throws {
        let base = ["PATH": "/usr/bin:/bin", APIProtocol.socketEnvironmentKey: "/tmp/s",
                    APIProtocol.sessionTokenEnvironmentKey: "secret", "CLAUDECODE": "1"]
        let request = CommandRunner.Request(
            command: #"echo "pr=$LOOM_PR_NUMBER socket=${LOOM_SOCKET:-none} token=${LOOM_SESSION_TOKEN:-none}"; echo oops >&2; exit 3"#,
            workingDirectory: folder, environment: ["LOOM_PR_NUMBER": "42"])
        let result = try await CommandRunner.run(request, shell: sh, environment: base)
        #expect(result.exitCode == 3)
        #expect(result.stdout == "pr=42 socket=none token=none\n")
        #expect(result.stderr == "oops\n")
        #expect(!result.timedOut)
    }

    @Test("only the end of a long output is kept")
    func fin() async throws {
        let request = CommandRunner.Request(command: "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done",
                                            workingDirectory: folder, outputLimit: 64)
        let result = try await CommandRunner.run(request, shell: sh)
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("…"))
        #expect(result.stdout.hasSuffix("line1999\n"))
    }

    @Test("past its deadline, the command and the processes it started are stopped")
    func delai() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let request = CommandRunner.Request(command: "sleep 30 & sleep 30; wait", workingDirectory: folder, timeout: 1)
        let result = try await CommandRunner.run(request, shell: sh)
        #expect(result.timedOut)
        #expect(clock.now - started < .seconds(10), "the children's open pipes do not keep it waiting")
    }
}
