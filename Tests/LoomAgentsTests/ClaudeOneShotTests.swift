import Testing
import LoomAgents
import LoomAPI
import Foundation

// ADR-0015: one non-interactive claude run — the arguments that strip a text-only
// run of every tool, the envelope it answers with, and the process around it
// (prompt on stdin, deadline, cancellation), against fake claude scripts.

@Suite("ClaudeOneShot — claude -p, text only")
struct ClaudeOneShotTests {

    private func fakeClaude(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-oneshot-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    @Test("text only: no tools, no MCP, no hooks, no slash commands, no transcript — and no prompt in argv")
    func argumentsTexteSeul() {
        let request = ClaudeOneShot.Request(prompt: "SECRET PROMPT", systemPrompt: "Be brief.", model: "haiku")
        let arguments = ClaudeOneShot.arguments(for: request)
        #expect(Array(arguments.prefix(3)) == ["-p", "--output-format", "json"])
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "")
        let settings = arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] }
        #expect(settings == #"{"disableAllHooks":true}"#)
        #expect(arguments.firstIndex(of: "--system-prompt").map { arguments[$0 + 1] } == "Be brief.")
        #expect(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] } == "haiku")
        #expect(!arguments.contains { $0.contains("SECRET") })
    }

    @Test("text only without a system prompt: Loom's own replaces the agent persona")
    func promptSystemeParDefaut() {
        let arguments = ClaudeOneShot.arguments(for: .init(prompt: "x"))
        #expect(arguments.firstIndex(of: "--system-prompt").map { arguments[$0 + 1] }
                == ClaudeOneShot.defaultSystemPrompt)
        #expect(!arguments.contains("--model"))
    }

    @Test("inherited tools (the PR tour): Claude Code as configured, nothing stripped")
    func argumentsHerites() {
        let arguments = ClaudeOneShot.arguments(for: .init(prompt: "x", tools: .inherited))
        #expect(arguments == ["-p", "--output-format", "json"])
    }

    @Test("the environment loses what ties a run to a session or to Loom's socket")
    func environnement() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me", "CLAUDECODE": "1",
                    APIProtocol.socketEnvironmentKey: "/tmp/s", APIProtocol.sessionTokenEnvironmentKey: "t"]
        #expect(ClaudeOneShot.environment(from: base) == ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }

    @Test("the envelope: text, cost, duration, model")
    func enveloppe() throws {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"Bonjour","total_cost_usd":0.0123,"duration_ms":2345,"modelUsage":{"claude-sonnet-x":{}}}"#
        let result = try ClaudeOneShot.parse(stdout: Data(json.utf8))
        #expect(result == .init(text: "Bonjour", isError: false, subtype: "success",
                                costUSD: 0.0123, durationMs: 2345, model: "claude-sonnet-x"))
        #expect(throws: ClaudeOneShot.Failure.malformed) { try ClaudeOneShot.parse(stdout: Data("nope".utf8)) }
        #expect(throws: ClaudeOneShot.Failure.malformed) { try ClaudeOneShot.parse(stdout: Data("{}".utf8)) }
    }

    @Test("a prompt past the 64 KB pipe buffer reaches claude whole, in an empty temporary folder")
    func promptSurStdin() async throws {
        let claude = try fakeClaude("""
        n=$(wc -c | tr -d ' ')
        printf '{"is_error":false,"result":"%s|%s|%s"}' "$n" "$(pwd)" "${LOOM_SOCKET:-none}"
        """)
        let prompt = String(repeating: "é", count: 100_000)   // 200 000 bytes
        let result = try await ClaudeOneShot.run(.init(prompt: prompt, timeout: 20), executable: claude,
                                                 environment: ["PATH": "/usr/bin:/bin", "LOOM_SOCKET": "/tmp/s"])
        let parts = result.text.split(separator: "|").map(String.init)
        #expect(parts.first == "200000")
        #expect(parts.count == 3 && parts[1].contains("loom-claude-"))
        #expect(parts.last == "none")
        #expect(!FileManager.default.fileExists(atPath: parts[1]), "the scratch folder is removed afterwards")
    }

    @Test("past the deadline: timedOut, and the process is gone")
    func delaiDepasse() async throws {
        let claude = try fakeClaude("exec sleep 30\n")
        let start = Date()
        await #expect(throws: ClaudeOneShot.Failure.timedOut) {
            try await ClaudeOneShot.run(.init(prompt: "x", timeout: 0.5), executable: claude)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("cancelling the task terminates claude")
    func annulation() async throws {
        let claude = try fakeClaude("exec sleep 30\n")
        let task = Task { try await ClaudeOneShot.run(.init(prompt: "x", timeout: 60), executable: claude) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let start = Date()
        await #expect(throws: ClaudeOneShot.Failure.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("an old claude refusing an option: exited, with stderr's tail")
    func sortieNonNulle() async throws {
        let claude = try fakeClaude("echo \"error: unknown option '--tools'\" >&2\nexit 1\n")
        do {
            _ = try await ClaudeOneShot.run(.init(prompt: "x", timeout: 20), executable: claude)
            Issue.record("expected a failure")
        } catch let failure as ClaudeOneShot.Failure {
            guard case .exited(1, let tail) = failure else {
                Issue.record("unexpected \(failure)")
                return
            }
            #expect(tail.contains("unknown option"))
        }
    }

    @Test("an envelope with is_error: claudeError, with claude's message")
    func erreurDeClaude() async throws {
        let claude = try fakeClaude("cat >/dev/null\nprintf '{\"is_error\":true,\"subtype\":\"success\",\"result\":\"Not logged in\"}'\nexit 1\n")
        await #expect(throws: ClaudeOneShot.Failure.claudeError("Not logged in")) {
            try await ClaudeOneShot.run(.init(prompt: "x", timeout: 20), executable: claude)
        }
    }

    @Test("a missing binary: launchFailed")
    func binaireAbsent() async {
        let missing = URL(fileURLWithPath: "/nonexistent/claude-\(UUID().uuidString)")
        do {
            _ = try await ClaudeOneShot.run(.init(prompt: "x"), executable: missing)
            Issue.record("expected a failure")
        } catch let failure as ClaudeOneShot.Failure {
            if case .launchFailed = failure {} else { Issue.record("unexpected \(failure)") }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
