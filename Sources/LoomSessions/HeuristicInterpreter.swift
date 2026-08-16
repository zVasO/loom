import LoomCore
import LoomTerminal
import Foundation

/// STA-02 fallback channel (hookless agents — Codex, Gemini): translates an
/// activity sample into a state proposal. Pure and memoryless — the smoothing
/// (hysteresis, hook priority window) belongs to the StateEngine, not to it.
/// The prompt patterns deliberately live in an editable array: the spec calls
/// for updating them without a release (risk #1, definitions file).
public struct HeuristicInterpreter: Sendable {

    public var silenceThreshold: Duration
    /// The agent can be silent on screen yet deep in thought: above this CPU
    /// threshold (process group), silence does not count as inactivity.
    public var busyCPUFraction: Double
    public var promptPatterns: [String]

    public init(silenceThreshold: Duration = .seconds(2),
                busyCPUFraction: Double = 0.15,
                promptPatterns: [String] = HeuristicInterpreter.defaultPromptPatterns) {
        self.silenceThreshold = silenceThreshold
        self.busyCPUFraction = busyCPUFraction
        self.promptPatterns = promptPatterns
    }

    /// Line endings typical of a shell or an agent waiting for input.
    public static let defaultPromptPatterns = [
        #"[$%>❯]\s*$"#,          // shell prompts: $, %, >, ❯
        #"\(y/n\)\s*$"#,         // confirmations
        #"\?\s*$"#,              // question displayed on screen
    ]

    public func propose(_ sample: SessionRuntime.ActivitySample) -> StateEngine.Event? {
        if sample.bytesSinceLastSample > 0 { return .heuristic(.working) }
        guard sample.silence >= silenceThreshold else { return nil }
        if sample.cpuFraction >= busyCPUFraction { return .heuristic(.working) }
        if let lastLine = sample.visibleTail.last, matchesPrompt(lastLine) {
            return .heuristic(.needsInput)
        }
        return .heuristic(.idle)
    }

    private func matchesPrompt(_ line: String) -> Bool {
        promptPatterns.contains { pattern in
            line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
