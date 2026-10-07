import Darwin
import Foundation
import LoomAPI
import LoomCore

/// One non-interactive `claude -p` run: a prompt in, a text answer out
/// (ADR-0015). The PR tour uses it with claude's own tools in the repo; an
/// extension's `claude.complete` uses it with none at all — no tools, no MCP
/// server, no hook, no slash command, no transcript, an empty folder for
/// working directory. Either way the user's Claude Code login is what runs
/// it: no API key goes anywhere.
///
/// The prompt goes through stdin, never argv: no `ARG_MAX`, and nothing an
/// extension wrote shows in `ps`.
public enum ClaudeOneShot {

    public enum ToolAccess: Sendable, Equatable {
        /// Text only: what an extension gets.
        case none
        /// Claude Code as the user configured it, in `workingDirectory`.
        case inherited
    }

    public struct Request: Sendable, Equatable {
        public var prompt: String
        public var systemPrompt: String?
        /// An alias (`sonnet`) or a model id; nil is the user's default.
        public var model: String?
        public var tools: ToolAccess
        public var timeout: TimeInterval
        /// nil: a fresh empty temporary folder, removed afterwards.
        public var workingDirectory: URL?
        public var maxOutputBytes: Int

        public init(prompt: String, systemPrompt: String? = nil, model: String? = nil,
                    tools: ToolAccess = .none, timeout: TimeInterval = 120,
                    workingDirectory: URL? = nil, maxOutputBytes: Int = 4 << 20) {
            self.prompt = prompt
            self.systemPrompt = systemPrompt
            self.model = model
            self.tools = tools
            self.timeout = timeout
            self.workingDirectory = workingDirectory
            self.maxOutputBytes = maxOutputBytes
        }
    }

    /// The JSON envelope `--output-format json` prints.
    public struct Result: Sendable, Equatable {
        public var text: String
        public var isError: Bool
        public var subtype: String?
        public var costUSD: Double?
        public var durationMs: Int?
        public var model: String?

        public init(text: String, isError: Bool = false, subtype: String? = nil,
                    costUSD: Double? = nil, durationMs: Int? = nil, model: String? = nil) {
            self.text = text
            self.isError = isError
            self.subtype = subtype
            self.costUSD = costUSD
            self.durationMs = durationMs
            self.model = model
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case launchFailed(String)
        case timedOut
        case cancelled
        /// A non-zero exit with no envelope: an unknown option (an old
        /// claude), a crash. The tail of stderr says which.
        case exited(Int32, stderrTail: String)
        case malformed
        /// claude answered, with an error: not logged in, a rate limit…
        case claudeError(String)
        case outputTooLarge

        public var description: String {
            switch self {
            case .launchFailed(let message): return "claude could not start: \(message)"
            case .timedOut: return "claude did not answer in time"
            case .cancelled: return "the request was cancelled"
            case .exited(let status, let tail):
                return tail.isEmpty ? "claude exited with status \(status)" : "claude exited with status \(status): \(tail)"
            case .malformed: return "claude's answer could not be read"
            case .claudeError(let message): return message
            case .outputTooLarge: return "claude's answer is too large"
            }
        }
    }

    /// What a text-only run stands as when the caller brings no system prompt:
    /// it replaces Claude Code's agent persona, which talks about tools it
    /// would not have.
    public static let defaultSystemPrompt =
        "Answer with text only. You have no tools, no files and no web access."

    /// Hooks off for a text-only run: the user's hooks would see a session Loom
    /// never hosts — and Loom's own would report it.
    public static let noHooksSettings = #"{"disableAllHooks":true}"#

    /// What reaches claude from Loom's environment: everything but what would
    /// tie the run to a session or to Loom's agents API.
    public static let strippedEnvironmentKeys: Set<String> = [
        "CLAUDECODE",
        APIProtocol.socketEnvironmentKey,
        APIProtocol.sessionTokenEnvironmentKey,
        APIProtocol.browserToolsEnvironmentKey,
    ]

    // MARK: - Pure

    public static func arguments(for request: Request) -> [String] {
        var arguments = ["-p", "--output-format", "json"]
        switch request.tools {
        case .none:
            arguments += [
                "--no-session-persistence",
                "--tools", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--settings", noHooksSettings,
                "--system-prompt", request.systemPrompt ?? defaultSystemPrompt,
            ]
        case .inherited:
            if let systemPrompt = request.systemPrompt {
                arguments += ["--system-prompt", systemPrompt]
            }
        }
        if let model = request.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        return arguments
    }

    public static func environment(from base: [String: String]) -> [String: String] {
        base.filter { !strippedEnvironmentKeys.contains($0.key) }
    }

    /// `{"type":"result","subtype":"success","is_error":false,"result":"…",
    /// "total_cost_usd":0.01,"duration_ms":1234,"modelUsage":{"claude-…":{…}}}`.
    public static func parse(stdout: Data) throws -> Result {
        guard let envelope = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw Failure.malformed
        }
        let isError = envelope["is_error"] as? Bool ?? false
        let subtype = envelope["subtype"] as? String
        guard let text = envelope["result"] as? String ?? (isError ? subtype : nil) else {
            throw Failure.malformed
        }
        let model = (envelope["modelUsage"] as? [String: Any])?.keys.sorted().first
        return Result(text: text, isError: isError, subtype: subtype,
                      costUSD: (envelope["total_cost_usd"] as? NSNumber)?.doubleValue,
                      durationMs: (envelope["duration_ms"] as? NSNumber)?.intValue,
                      model: model)
    }

    // MARK: - Run

    /// Runs claude and waits for its answer. Throws a `Failure`; an envelope
    /// with `is_error` becomes `.claudeError`. Cancelling the task terminates
    /// the process.
    public static func run(_ request: Request, executable: URL,
                           environment base: [String: String] = ProcessInfo.processInfo.environment) async throws -> Result {
        let fm = FileManager.default
        var scratch: URL?
        let directory: URL
        if let given = request.workingDirectory {
            directory = given
        } else {
            let made = fm.temporaryDirectory.appendingPathComponent("loom-claude-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: made, withIntermediateDirectories: true)
            scratch = made
            directory = made
        }
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: request)
        process.currentDirectoryURL = directory
        process.environment = environment(from: base)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A child that exits before reading all its input must not take Loom
        // down with a SIGPIPE: the write fails instead.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let run = RunState()
        let outcome: (Int32, Data, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, out, err in
                        run.finished()
                        continuation.resume(returning: (status, out, err))
                    }
                } catch {
                    continuation.resume(throwing: Failure.launchFailed("\(error)"))
                    return
                }
                run.started(process)
                let input = Data(request.prompt.utf8)
                let writer = stdin.fileHandleForWriting
                DispatchQueue.global(qos: .userInitiated).async {
                    // Past 64 KB the write blocks until claude reads: never on
                    // the caller's thread.
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
                let timeout = request.timeout
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    run.stop(because: .timedOut)
                }
            }
        } onCancel: {
            run.stop(because: .cancelled)
        }

        if let reason = run.stopReason { throw reason }
        let (status, out, err) = outcome
        guard out.count <= request.maxOutputBytes else { throw Failure.outputTooLarge }
        let result: Result
        do {
            result = try parse(stdout: out)
        } catch {
            guard status == 0 else { throw Failure.exited(status, stderrTail: tail(of: err)) }
            throw error
        }
        if result.isError { throw Failure.claudeError(result.text) }
        return result
    }

    static func tail(of data: Data, limit: Int = 300) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= limit ? text : "…" + String(text.suffix(limit))
    }

    /// The process and why it was stopped, shared between the caller, the
    /// timeout and the cancellation handler.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var reason: Failure?
        private var pendingStop = false
        private var isFinished = false

        var stopReason: Failure? {
            lock.lock(); defer { lock.unlock() }
            return reason
        }

        func started(_ process: Process) {
            lock.lock()
            self.process = process
            let stopNow = pendingStop
            lock.unlock()
            if stopNow { Self.terminate(process) }
        }

        /// The process is gone and its output read: a timeout firing now is late.
        func finished() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        func stop(because failure: Failure) {
            lock.lock()
            guard reason == nil, !isFinished else { lock.unlock(); return }
            reason = failure
            let process = self.process
            if process == nil { pendingStop = true }
            lock.unlock()
            if let process { Self.terminate(process) }
        }

        /// SIGTERM, then SIGKILL for a claude that does not go.
        private static func terminate(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
