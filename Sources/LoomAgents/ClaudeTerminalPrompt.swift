import Foundation

/// A choice claude asks for in its terminal — a permission ("Do you want to
/// proceed?"), a question with options — read off the screen's text. The
/// terminal is where claude draws it, and the only place: the transcript
/// holds the tool call it is about, never the options offered. Read here so
/// the chat view can show it and answer it (ADR-0023).
public struct ClaudeTerminalPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        /// The number claude shows before it: the key that picks it.
        public let number: Int
        public let label: String
    }

    /// What is asked: "Do you want to proceed?".
    public let question: String
    /// The lines above the question, up to the dialog's top: the tool, its
    /// command, its explanation. Trimmed, blank lines dropped.
    public let context: [String]
    public let options: [Option]
    /// The option the marker (❯) is on.
    public let selected: Int?

    /// The key that picks an option. claude's menus take the option's
    /// number and act on it at once, as Return would on the highlighted one.
    public static func answer(_ option: Option) -> String { String(option.number) }

    /// The prompt the screen's last lines show, or nil. Strict on purpose:
    /// a numbered list in an answer must not read as a question. The
    /// options have to be the last thing on the screen (only blank lines and
    /// a short hint may follow), numbered from 1 without a gap, at least two,
    /// one of them under the marker.
    public static func parse(lines raw: [String]) -> ClaudeTerminalPrompt? {
        let lines = raw.map(clean)
        var index = lines.count - 1
        // Below the options: blank lines and a hint ("Esc to cancel").
        var hints = 0
        while index >= 0 {
            let line = lines[index]
            if line.isEmpty || isRule(line) {
                index -= 1
            } else if option(in: line) == nil, hints < 3, isHint(line) {
                hints += 1
                index -= 1
            } else {
                break
            }
        }
        // The options, read upwards. A line that is not an option but sits
        // between two is the wrapped end of the one above it.
        var found: [(number: Int, label: String, marked: Bool)] = []
        var wrapped: [String] = []
        while index >= 0 {
            let line = lines[index]
            if let parsed = option(in: line) {
                let label = ([parsed.label] + wrapped.reversed()).joined(separator: " ")
                found.append((parsed.number, label, parsed.marked))
                wrapped = []
                if parsed.number == 1 { index -= 1; break }
            } else if !line.isEmpty, wrapped.count < 4, !isRule(line) {
                // The wrapped end of the option above — the last option's
                // too: in a narrow terminal it runs onto a line of its own,
                // and a dialog that ended on such a line was not read at all.
                wrapped.append(line)
            } else {
                return nil
            }
            index -= 1
        }
        found.reverse()
        guard found.count >= 2, found.first?.number == 1,
              found.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }),
              found.contains(where: \.marked) else { return nil }
        // The question: the first line above the options.
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 0, !isRule(lines[index]) else { return nil }
        let question = lines[index]
        index -= 1
        // The context, up to the dialog's top rule, a run of blank lines or
        // a dozen lines.
        var context: [String] = []
        var blanks = 0
        while index >= 0, context.count < 12 {
            let line = lines[index]
            if isRule(line) { break }
            if line.isEmpty {
                blanks += 1
                if blanks >= 2, !context.isEmpty { break }
            } else {
                blanks = 0
                context.append(line)
            }
            index -= 1
        }
        return ClaudeTerminalPrompt(question: question,
                                    context: context.reversed(),
                                    options: found.map { Option(number: $0.number, label: $0.label) },
                                    selected: found.first(where: \.marked)?.number)
    }

    // MARK: Reading a line

    /// The dialog's box drawing and the padding inside it, gone.
    static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        let edges: Set<Character> = ["│", "┃", "║"]
        if let first = text.first, edges.contains(first) { text.removeFirst() }
        if let last = text.last, edges.contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A horizontal rule or a box's top or bottom edge.
    static func isRule(_ line: String) -> Bool {
        let rules: Set<Character> = ["─", "━", "═", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "-", "╌"]
        return line.count >= 3 && line.allSatisfy { rules.contains($0) || $0 == " " }
    }

    /// What claude prints under a menu: how to leave it, how to amend.
    static func isHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        return line.count <= 100 && (lower.contains("esc") || lower.contains("tab to")
            || lower.contains("enter to") || lower.contains("ctrl") || lower.contains("to navigate")
            || lower.contains("to select") || lower.contains("to cancel") || lower.contains("↑")
            || lower.contains("shift+"))
    }

    /// "❯ 1. Yes", "  2. No, and tell Claude…".
    static func option(in line: String) -> (number: Int, label: String, marked: Bool)? {
        var rest = Substring(line)
        var marked = false
        if let first = rest.first, first == "❯" || first == "›" || first == ">" || first == "▶" {
            marked = true
            rest = rest.dropFirst().drop(while: { $0 == " " })
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard let dot = rest.first, dot == "." || dot == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label, marked)
    }
}
