import Foundation
import LoomAgents
import LoomExtensions

/// The `claude -p` runs extensions ask for (ADR-0015): text only, a couple at
/// a time for the whole app, each one killed when its extension goes away.
@MainActor
final class ExtensionClaudeRunner {
    static let maxConcurrent = 2

    private var running: [UUID: (extensionID: String, task: Task<ClaudeOneShot.Result, Error>)] = [:]

    func run(_ request: ClaudeCompletionRequest, for extensionID: String,
             executable: URL?) async throws -> BridgeClaudeCompletion {
        guard let executable else {
            throw BridgeError(.unavailable, "Claude Code was not found on this Mac — install it, then restart Loom")
        }
        guard running.count < Self.maxConcurrent else {
            throw BridgeError(.conflict, "Loom is already running \(Self.maxConcurrent) Claude requests — try again shortly")
        }
        let oneShot = ClaudeOneShot.Request(prompt: request.prompt, systemPrompt: request.system,
                                            model: request.model, tools: .none, timeout: request.timeout)
        let key = UUID()
        let task = Task.detached { try await ClaudeOneShot.run(oneShot, executable: executable) }
        running[key] = (extensionID, task)
        defer { running[key] = nil }
        let started = Date()
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let cut = result.text.count > BridgeClaudeCompletion.maxTextLength
            return BridgeClaudeCompletion(
                text: cut ? String(result.text.prefix(BridgeClaudeCompletion.maxTextLength)) : result.text,
                model: result.model, costUsd: result.costUSD,
                durationMs: result.durationMs ?? Int(Date().timeIntervalSince(started) * 1000),
                truncated: cut)
        } catch let failure as ClaudeOneShot.Failure {
            throw Self.bridgeError(failure)
        }
    }

    /// Stops every run of an extension being disabled, updated or removed.
    func cancel(extensionID: String) {
        for (_, run) in running where run.extensionID == extensionID {
            run.task.cancel()
        }
    }

    static func bridgeError(_ failure: ClaudeOneShot.Failure) -> BridgeError {
        switch failure {
        case .timedOut:
            return BridgeError(.timeout, "Claude did not answer in time")
        case .cancelled:
            return BridgeError(.unavailable, "the request was cancelled")
        case .claudeError(let message):
            return BridgeError(.unavailable, "Claude: \(String(message.prefix(300)))")
        case .exited(_, let tail) where tail.contains("unknown option"):
            return BridgeError(.unavailable, "this Claude Code is too old for Loom's extensions — update it")
        case .launchFailed, .exited, .malformed, .outputTooLarge:
            return BridgeError(.unavailable, String(failure.description.prefix(300)))
        }
    }
}
