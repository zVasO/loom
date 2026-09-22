import LoomCore
import Foundation

/// When is an agent READY for a line typed from the outside (the review setup
/// command, a quick action)? Never "the screen changed": a resize repaints a
/// blank screen, and the boot of a plugin-heavy claude takes seconds during
/// which everything typed is dropped or mangled. Ready means all of:
/// the program has painted, it negotiated bracketed paste (claude's input is
/// mounted — DECSET 2004 is the first thing it switches on), a prompt is on
/// screen, and the output has settled.
/// Pure and memoryless — the caller polls `SessionRuntime.readiness()`.
public enum AgentReadiness {

    /// Line endings typical of a shell or an agent waiting for input. Shared
    /// with the STA-02 heuristic: one list, editable without a release.
    public static let promptPatterns = [
        #"[$%>❯]\s*$"#,          // shell prompts: $, %, >, ❯
        #"\(y/n\)\s*$"#,         // confirmations
        #"\?\s*$"#,              // question displayed on screen
    ]

    /// An agent's INPUT LINE, wherever it sits: claude draws `> ` (or `❯ `)
    /// and, below it, a status line or its shortcut hints — so the prompt is
    /// rarely the last line on screen, and may carry a placeholder after it.
    public static let inputLinePattern = #"^[>❯](\s|$)"#

    /// claude paints its prompt, then keeps negotiating modes for a beat; the
    /// output must have settled this long before a line goes in.
    public static let settleDuration: Duration = .milliseconds(700)

    public static func isReady(_ sample: SessionRuntime.ReadinessSample,
                               promptPatterns: [String] = promptPatterns,
                               settle: Duration = settleDuration) -> Bool {
        guard sample.bytesReceived > 0, sample.modes.bracketedPaste,
              sample.silence >= settle else { return false }
        return showsPrompt(sample.visibleTail, promptPatterns: promptPatterns)
    }

    /// A shell-like prompt ending the last line, or an input line anywhere in
    /// the tail (trimmed, non-empty lines, oldest first).
    public static func showsPrompt(_ tail: [String],
                                   promptPatterns: [String] = promptPatterns) -> Bool {
        guard let last = tail.last else { return false }
        if promptPatterns.contains(where: { matches(last, $0) }) { return true }
        return tail.contains { matches($0, inputLinePattern) }
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
