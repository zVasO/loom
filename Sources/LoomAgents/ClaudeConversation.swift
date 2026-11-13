import LoomCore
import Foundation

/// The conversation of a native session, read from claude's own
/// `<uuid>.jsonl`: what was said on both sides, which tools ran and what they
/// returned. Pure — the seam the tests contract against.
///
/// claude writes one line per content block, and answers a tool call in a
/// later `user` line: most `user` lines are tool results, not messages. Much
/// of the rest is what claude code writes on the user's side in the user's
/// name (reminders, slash commands, notifications): shown as a notice, or not
/// at all.
public enum ClaudeConversation {

    /// The entries of a conversation, in order, from the text of its file.
    public static func entries(fromJSONL text: String) -> [ConversationEntry] {
        var reader = Reader()
        reader.consume(text)
        return reader.entries
    }

    /// What a view keeps to follow a file as it grows: the entries so far and
    /// where the reading stopped. These files reach megabytes — only what was
    /// written since the last call is parsed.
    public struct Reader: Sendable {
        public private(set) var entries: [ConversationEntry] = []
        /// Where each tool call sits in `entries`: its result comes in a later
        /// line, often in a later read.
        private var calls: [String: Int] = [:]
        /// A line handed over twice must not show twice.
        private var seen: Set<String> = []
        /// Every line read so far: what names an entry whose line has no `uuid`.
        private var lineCount: Int = 0
        private var file: URL?
        private var offset: UInt64 = 0

        public init() {}

        /// Complete lines of JSONL, appended to what was read before. True
        /// when entries changed.
        @discardableResult
        public mutating func consume(_ text: String) -> Bool {
            read(lines: Data(text.utf8))
        }

        /// What the file gained since the last call — from the start again
        /// when it shrank, or when another file is asked for. Synchronous
        /// disk read: call off the main actor. True when entries changed.
        @discardableResult
        public mutating func refresh(from url: URL) -> Bool {
            var changed = false
            if url != file {
                changed = !entries.isEmpty
                reset()
                file = url
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return changed }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset {
                // A file that shrank was rewritten: nothing read so far still holds.
                changed = changed || !entries.isEmpty
                reset()
                file = url
            }
            guard size > offset else { return changed }
            try? handle.seek(toOffset: offset)
            // The last line may be half written: only what ends with a newline
            // is read, the rest waits for the next call.
            guard let data = try? handle.readToEnd(),
                  let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return changed }
            let whole = data[data.startIndex...lastNewline]
            offset += UInt64(whole.count)
            if read(lines: whole) { changed = true }
            return changed
        }

        public mutating func reset() {
            self = Reader()
        }

        // MARK: Lines

        /// Split on the newline byte, not on the character: a JSON line holds
        /// no raw newline, and a megabyte line of base64 need not become a
        /// String to be skipped.
        private mutating func read(lines data: Data) -> Bool {
            var changed = false
            for line in data.split(separator: UInt8(ascii: "\n")) {
                lineCount += 1
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if apply(object) { changed = true }
            }
            return changed
        }

        /// What one line adds. Most add nothing: a sub-agent's own exchange,
        /// what claude code notes for itself, the bookkeeping of a turn.
        private mutating func apply(_ object: [String: Any]) -> Bool {
            if object["isSidechain"] as? Bool == true { return false }
            guard let type = object["type"] as? String else { return false }
            let line = (object["uuid"] as? String) ?? "line-\(lineCount)"
            let stamp = object["timestamp"] as? String
            let message = object["message"] as? [String: Any]
            switch type {
            case "assistant":
                return readAssistant(message?["content"], line: line, stamp: stamp)
            case "user":
                if object["isMeta"] as? Bool == true { return false }
                // The summary a compaction leaves is written for claude, not for the reader.
                if object["isCompactSummary"] as? Bool == true {
                    return append(.notice(ClaudeConversation.compacted), id: line + "#0", stamp: stamp)
                }
                return readUser(message?["content"], line: line, stamp: stamp)
            case "system":
                let subtype = (object["subtype"] as? String) ?? ""
                if subtype == "compact_boundary" {
                    return append(.notice(ClaudeConversation.compacted), id: line + "#0", stamp: stamp)
                }
                // Some versions of claude code write a local command and what
                // it printed here rather than on the user's side.
                if subtype == "local_command", let content = object["content"] as? String,
                   let kind = ClaudeConversation.kind(ofUserText: content), case .notice = kind {
                    return append(kind, id: line + "#0", stamp: stamp)
                }
                return false
            case "attachment":
                // A message sent while claude works joins the running turn as
                // an attachment: it never gets a user line of its own.
                guard let attachment = object["attachment"] as? [String: Any],
                      attachment["type"] as? String == "queued_command" else { return false }
                return readUser(attachment["prompt"], line: line, stamp: stamp)
            default:
                return false
            }
        }

        private mutating func readAssistant(_ content: Any?, line: String, stamp: String?) -> Bool {
            var blocks: [[String: Any]] = []
            if let text = content as? String {
                blocks = [["type": "text", "text": text]]
            } else if let list = content as? [[String: Any]] {
                blocks = list
            }
            var changed = false
            for (index, block) in blocks.enumerated() {
                let id = "\(line)#\(index)"
                let type = (block["type"] as? String) ?? ""
                switch type {
                case "text":
                    let said = ClaudeConversation.trimmed(block["text"])
                    if !said.isEmpty, append(.assistant(said), id: id, stamp: stamp) { changed = true }
                case "thinking":
                    // Recent claude writes the block empty, or signed only: nothing to show.
                    let thought = ClaudeConversation.trimmed(block["thinking"])
                    if !thought.isEmpty, append(.thinking(thought), id: id, stamp: stamp) { changed = true }
                case "tool_use":
                    let name = (block["name"] as? String) ?? "Tool"
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let toolUseID = (block["id"] as? String) ?? ""
                    let call = ConversationEntry.ToolCall(
                        toolUseID: toolUseID, name: name,
                        summary: ClaudeConversation.summary(of: name, input: input),
                        input: ClaudeConversation.readable(input, of: name))
                    if append(.tool(call), id: id, stamp: stamp) {
                        if !toolUseID.isEmpty { calls[toolUseID] = entries.count - 1 }
                        changed = true
                    }
                default:
                    break
                }
            }
            return changed
        }

        /// One line on the user's side: the results of the tools claude
        /// called, and at most one entry for what its text and images say.
        private mutating func readUser(_ content: Any?, line: String, stamp: String?) -> Bool {
            if let text = content as? String {
                return say(text, id: line + "#0", stamp: stamp)
            }
            guard let blocks = content as? [[String: Any]] else { return false }
            var changed = false
            var pieces: [String] = []
            var first: Int?
            for (index, block) in blocks.enumerated() {
                let type = (block["type"] as? String) ?? ""
                switch type {
                case "tool_result":
                    if complete(block) { changed = true }
                case "text":
                    let text = ClaudeConversation.withoutReminders((block["text"] as? String) ?? "")
                    if !text.isEmpty {
                        pieces.append(text)
                        if first == nil { first = index }
                    }
                case "image":
                    pieces.append("[image]")
                    if first == nil { first = index }
                default:
                    break
                }
            }
            if let first, say(pieces.joined(separator: "\n"), id: "\(line)#\(first)", stamp: stamp) {
                changed = true
            }
            return changed
        }

        private mutating func say(_ text: String, id: String, stamp: String?) -> Bool {
            guard let kind = ClaudeConversation.kind(ofUserText: text) else { return false }
            return append(kind, id: id, stamp: stamp)
        }

        /// A tool's answer joins its call, however far back the call sits:
        /// it is not an entry of its own.
        private mutating func complete(_ block: [String: Any]) -> Bool {
            guard let toolUseID = block["tool_use_id"] as? String,
                  let index = calls[toolUseID],
                  case .tool(let pending) = entries[index].kind else { return false }
            var call = pending
            call.result = ClaudeConversation.capped(ClaudeConversation.resultText(block["content"]),
                                                    limit: ClaudeConversation.resultLimit)
            call.isError = (block["is_error"] as? Bool) ?? false
            guard call != pending else { return false }
            entries[index].kind = .tool(call)
            return true
        }

        private mutating func append(_ kind: ConversationEntry.Kind, id: String, stamp: String?) -> Bool {
            guard seen.insert(id).inserted else { return false }
            // claude marks a compaction twice, as a boundary and as the
            // summary that follows it: one notice says it.
            if kind == .notice(ClaudeConversation.compacted), entries.last?.kind == kind { return false }
            entries.append(ConversationEntry(id: id, kind: kind, timestamp: ClaudeConversation.date(stamp)))
            return true
        }
    }

    // MARK: - The user's side

    private static let compacted = "Conversation compacted"
    private static let noticeLimit = 300

    /// What a text on the user's side is: a message, or one of the things
    /// claude code writes there in the user's name. Nil when none of it is for
    /// the reader. The tags only count at the start of the text: a user who
    /// writes about `<command-name>` is still writing a message.
    private static func kind(ofUserText raw: String) -> ConversationEntry.Kind? {
        let text = withoutReminders(raw)
        if text.isEmpty || text.hasPrefix("<local-command-caveat>") { return nil }
        // "[Request interrupted by user]" and its "for tool use" variant.
        if text.hasPrefix("[Request interrupted by user") { return .notice("Interrupted") }
        if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>"),
           let name = inner("command-name", in: text) {
            var command = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.hasPrefix("/") { command = "/" + command }
            let arguments = firstLine(inner("command-args", in: text) ?? "")
            return .notice(clipped(arguments.isEmpty ? command : command + " " + arguments, limit: noticeLimit))
        }
        if text.hasPrefix("<bash-input>"), let command = inner("bash-input", in: text) {
            return .notice(clipped("! " + firstLine(command), limit: noticeLimit))
        }
        if text.hasPrefix("<local-command-std") || text.hasPrefix("<bash-std") {
            for tag in ["local-command-stdout", "local-command-stderr", "bash-stdout", "bash-stderr"] {
                guard let output = inner(tag, in: text) else { continue }
                let shown = brief(output)
                if !shown.isEmpty { return .notice(shown) }
            }
            return nil
        }
        // A background task reporting back: its summary is the line a person reads.
        if text.hasPrefix("<task-notification>") {
            let report = brief(inner("summary", in: text) ?? "")
            return .notice(report.isEmpty ? "Task notification" : report)
        }
        return .user(text)
    }

    /// The text without what claude code slipped into it for claude alone.
    private static func withoutReminders(_ text: String) -> String {
        var rest = text
        while let open = rest.range(of: "<system-reminder>") {
            if let close = rest.range(of: "</system-reminder>", range: open.upperBound..<rest.endIndex) {
                rest.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Never closed: nothing after it was written by the user.
                rest.removeSubrange(open.lowerBound..<rest.endIndex)
            }
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inner(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<" + tag + ">"),
              let close = text.range(of: "</" + tag + ">", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// The first lines of what a command printed, cut to what a notice holds.
    /// It printed for a terminal: its colour codes mean nothing here.
    private static func brief(_ text: String) -> String {
        let printed = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[\\x20-\\x2F]*[\\x40-\\x7E]", with: "",
                                                options: .regularExpression)
        let lines: [String] = printed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var kept = lines.prefix(3).joined(separator: "\n")
        if lines.count > 3 { kept += " …" }
        return clipped(kept, limit: noticeLimit)
    }

    // MARK: - Tool calls

    private static let summaryLimit = 120
    private static let inputLimit = 4_000
    private static let resultLimit = 8_000

    /// One line for a person: the tool and the argument that tells what it
    /// was called for.
    private static func summary(of name: String, input: [String: Any]) -> String {
        let line: String
        switch name {
        case "Read", "Edit", "Write", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            line = name + " " + shortPath(path)
        case "Bash":
            line = "Bash " + firstLine((input["command"] as? String) ?? "")
        case "Grep":
            var search = "Grep " + firstLine((input["pattern"] as? String) ?? "")
            if let path = input["path"] as? String, !path.isEmpty { search += " in " + shortPath(path) }
            line = search
        case "Glob":
            line = "Glob " + firstLine((input["pattern"] as? String) ?? "")
        case "Task", "Agent":
            line = name + " " + firstLine((input["description"] as? String) ?? "")
        case "WebFetch":
            line = "WebFetch " + firstLine((input["url"] as? String) ?? "")
        case "WebSearch":
            line = "WebSearch " + firstLine((input["query"] as? String) ?? "")
        case "TodoWrite":
            let count = (input["todos"] as? [Any])?.count ?? 0
            line = "TodoWrite " + (count == 1 ? "1 item" : "\(count) items")
        default:
            var label = name.hasPrefix("mcp__") ? mcpLabel(name) : name
            if let argument = tellingArgument(in: input) { label += " " + argument }
            line = label
        }
        return clipped(line.trimmingCharacters(in: .whitespaces), limit: summaryLimit)
    }

    /// `mcp__loom__browser_open` → "loom · browser_open": the server, then its tool.
    private static func mcpLabel(_ name: String) -> String {
        let rest = String(name.dropFirst("mcp__".count))
        guard let separator = rest.range(of: "__") else { return rest }
        return String(rest[..<separator.lowerBound]) + " · " + String(rest[separator.upperBound...])
    }

    /// The argument that says most about a call to a tool Loom does not know:
    /// the first line of one with a telling name, else a short string. A JSON
    /// object carries no order once parsed, so the others go alphabetically —
    /// the same line on every read.
    private static func tellingArgument(in input: [String: Any]) -> String? {
        let telling = ["description", "title", "name", "skill", "query", "url", "path", "file_path",
                       "command", "pattern", "prompt"]
        for key in telling {
            guard let value = input[key] as? String else { continue }
            let line = firstLine(value)
            if !line.isEmpty { return line }
        }
        for key in input.keys.sorted() where !telling.contains(key) {
            guard let value = input[key] as? String else { continue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 80, text.rangeOfCharacter(from: .newlines) == nil { return text }
        }
        return nil
    }

    /// The last three components: enough to tell the file, short enough for a row.
    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 3 else { return path }
        return parts.suffix(3).joined(separator: "/")
    }

    /// What the tool was given, for whoever opens the row: the command as
    /// typed, else the JSON. Empty when it was given nothing.
    private static func readable(_ input: [String: Any], of name: String) -> String {
        if name == "Bash", let command = input["command"] as? String {
            return capped(command, limit: inputLimit)
        }
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return capped(String(decoding: data, as: UTF8.self), limit: inputLimit)
    }

    /// A result is a string, or blocks: their text, and a word for an image.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for block in blocks {
            let type = (block["type"] as? String) ?? ""
            if type == "text", let text = block["text"] as? String {
                pieces.append(text)
            } else if type == "image" {
                pieces.append("[image]")
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// A file read whole or a build log would weigh on every redraw of the
    /// list: the start is kept, and a last line says how much was cut.
    private static func capped(_ text: String, limit: Int) -> String {
        let count = text.count
        guard count > limit else { return text }
        return String(text.prefix(limit)) + "\n… \(count - limit) more characters"
    }

    // MARK: - Text

    private static func trimmed(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstLine(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let kept = line.trimmingCharacters(in: .whitespaces)
            if !kept.isEmpty { return kept }
        }
        return ""
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: - Time

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        return fractional.date(from: stamp) ?? plain.date(from: stamp)
    }
}
