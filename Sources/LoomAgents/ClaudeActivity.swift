import Foundation
import LoomCore

/// What claude's sessions reached for, counted from their own records: the
/// tools called (an MCP server's, a skill, a sub-agent, a plain one), the
/// slash commands typed, the hooks that ran. One pass over a session's
/// JSONL — and its sub-agents' files beside it — gives a tally per day, so a
/// window ("the last 30 days") is a sum, not another read.
///
/// What the records hold, and so what is counted:
/// - a tool call is one `tool_use` block; its failure, the `tool_result`
///   that answers it with `is_error`;
/// - a hook is what claude wrote of it: the summary of the Stop hooks, the
///   attachments and progress lines of the others. A hook that ran silently
///   and left no line is not counted;
/// - what was offered (skills, MCP servers) comes from the listings claude
///   attaches to the conversation, when it does.
public enum ClaudeActivity {

    /// One session file's activity, by day (`yyyy-MM-dd`, UTC, as claude stamps).
    public struct FileActivity: Equatable, Sendable {
        public var days: [String: ActivityTally] = [:]
        public var skills: Set<String> = []
        public var servers: Set<String> = []

        public init() {}

        /// The days from `day` on, summed; every day when nil. What the
        /// session was offered is kept whatever the window: a skill listed
        /// last month and never called since is still unused.
        public func tally(since day: String? = nil) -> ActivityTally {
            var sum = ActivityTally()
            for (key, tally) in days where day == nil || key >= day! {
                sum.merge(tally)
            }
            if !sum.isEmpty || day == nil {
                sum.availableSkills = skills
                sum.availableServers = servers
            }
            return sum
        }

        public mutating func merge(_ other: FileActivity) {
            for (day, tally) in other.days {
                days[day, default: ActivityTally()].merge(tally)
            }
            skills.formUnion(other.skills)
            servers.formUnion(other.servers)
        }
    }

    /// Many sessions, summed.
    public struct Overview: Equatable, Sendable {
        public var tally = ActivityTally()
        /// The sessions that did something in the window.
        public var sessions = 0

        public init() {}
    }

    // MARK: Reading

    public static func activity(fromJSONL text: String) -> FileActivity {
        activity(from: Data(text.utf8))
    }

    public static func activity(from data: Data) -> FileActivity {
        var parser = Parser()
        parser.consume(data)
        return parser.result
    }

    /// A session's file and its sub-agents' (`<session>/subagents/**/agent-*.jsonl`).
    /// Synchronous disk work: call off the main actor. Kept until the file changes.
    public static func activity(ofSessionFile file: URL) -> FileActivity {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = Stamp(size: values?.fileSize ?? 0,
                          modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        if let kept = Cache.shared[file.path, stamp] { return kept }
        var activity = read(file)
        for agent in subagentFiles(of: file) {
            activity.merge(read(agent))
        }
        Cache.shared[file.path, stamp] = activity
        return activity
    }

    /// One session's tally, or nil when claude has written nothing of it.
    public static func tally(for id: SessionID,
                             projectsDirectory: URL = ClaudeNativeSessions.defaultProjectsDirectory) -> ActivityTally? {
        guard let file = ClaudeNativeSessions.path(for: id, projectsDirectory: projectsDirectory) else { return nil }
        return activity(ofSessionFile: file).tally()
    }

    /// Every session on this machine over the last `days` days. Files not
    /// touched since are not opened; the others are read side by side.
    public static func overview(lastDays days: Int, now: Date = Date(),
                                projectsDirectory: URL = ClaudeNativeSessions.defaultProjectsDirectory) -> Overview {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let since = day(cutoff)
        let manager = FileManager.default
        var files: [URL] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for project in (try? manager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? []
            where file.pathExtension.lowercased() == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                // A day of slack: the file's clock is local, the stamps UTC.
                if modified >= cutoff.addingTimeInterval(-86_400) { files.append(file) }
            }
        }
        let sum = Sum()
        let pending = files
        DispatchQueue.concurrentPerform(iterations: pending.count) { index in
            let tally = activity(ofSessionFile: pending[index]).tally(since: since)
            if !tally.isEmpty { sum.add(tally) }
        }
        return sum.overview
    }

    /// The overview as the files come in, from several threads.
    private final class Sum: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Overview()

        var overview: Overview {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func add(_ tally: ActivityTally) {
            lock.lock()
            defer { lock.unlock() }
            value.tally.merge(tally)
            value.sessions += 1
        }
    }

    /// `yyyy-MM-dd` in UTC: the first ten characters of claude's timestamps.
    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Files

    private static func read(_ file: URL) -> FileActivity {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return FileActivity() }
        return activity(from: data)
    }

    static func subagentFiles(of session: URL) -> [URL] {
        let root = ClaudeSubagents.folder(forSessionFile: session)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where ClaudeSubagents.isTranscript(url) {
            files.append(url)
        }
        return files
    }

    private struct Stamp: Equatable {
        var size: Int
        var modified: Double
    }

    /// What each file gave, until it changes: the overview is asked again at
    /// every window, and a session's sheet at every opening.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var kept: [String: (stamp: Stamp, activity: FileActivity)] = [:]

        subscript(path: String, stamp: Stamp) -> FileActivity? {
            get {
                lock.lock()
                defer { lock.unlock() }
                guard let entry = kept[path], entry.stamp == stamp else { return nil }
                return entry.activity
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                kept[path] = newValue.map { (stamp, $0) }
            }
        }
    }

    // MARK: Lines

    /// Only the lines that can hold something counted are parsed: a session's
    /// file is mostly tool results, megabytes of them.
    private static let markers: [[UInt8]] = [
        "\"tool_use\"", "\"is_error\":true", "<command-", "hook", "skill_listing",
        "deferred_tools_delta", "mcp_instructions_delta",
    ].map { Array($0.utf8) }

    struct Parser {
        var result = FileActivity()
        /// The day of the last line that had a timestamp: for those that have none.
        private var day = ""
        /// A tool call's id → what it was, for the result that fails it.
        private var calls: [String: (kind: ActivityTally.Kind, name: String, day: String)] = [:]
        /// Hook runs already counted: claude can write one twice (a progress
        /// line, then an attachment).
        private var hookRuns = Set<String>()
        /// Skills the model loaded, whose echo as a command is still to come.
        private var skillEchoes: [String: Int] = [:]

        mutating func consume(_ data: Data) {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let count = raw.count
                var offset = 0
                while offset < count {
                    let found = memchr(base + offset, 0x0A, count - offset)
                    let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    if end > offset {
                        let line = base + offset
                        let length = end - offset
                        let worth = ClaudeActivity.markers.contains { marker in
                            marker.withUnsafeBytes { memmem(line, length, $0.baseAddress, $0.count) != nil }
                        }
                        if worth,
                           let object = try? JSONSerialization.jsonObject(
                               with: Data(bytes: line, count: length)) as? [String: Any] {
                            apply(object)
                        }
                    }
                    offset = end + 1
                }
            }
        }

        private mutating func note(_ kind: ActivityTally.Kind, _ name: String, failed: Bool = false) {
            result.days[day, default: ActivityTally()].note(kind, name, failed: failed)
        }

        mutating func apply(_ object: [String: Any]) {
            if let stamp = object["timestamp"] as? String, stamp.count >= 10 {
                day = String(stamp.prefix(10))
            }
            switch object["type"] as? String {
            case "assistant": assistant(object)
            case "user": user(object)
            case "system": system(object)
            case "attachment": attachment(object)
            case "progress": progress(object)
            default: break
            }
        }

        private mutating func assistant(_ object: [String: Any]) {
            let message = object["message"] as? [String: Any]
            for block in (message?["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                let id = (block["id"] as? String) ?? ""
                // The same call written twice (a resumed conversation) counts once.
                if !id.isEmpty, calls[id] != nil { continue }
                let input = (block["input"] as? [String: Any]) ?? [:]
                let (kind, label) = ClaudeActivity.classify(tool: name, input: input)
                note(kind, label)
                if kind == .skill { skillEchoes[label, default: 0] += 1 }
                if !id.isEmpty { calls[id] = (kind, label, day) }
            }
        }

        private mutating func user(_ object: [String: Any]) {
            let message = object["message"] as? [String: Any]
            if let text = message?["content"] as? String {
                command(in: text)
                return
            }
            for block in (message?["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    guard block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String,
                          let call = calls[id] else { continue }
                    result.days[call.day]?.fail(call.kind, call.name)
                case "text":
                    if let text = block["text"] as? String { command(in: text) }
                default:
                    break
                }
            }
        }

        /// "<command-name>/review</command-name>": a slash command typed, or
        /// the echo of a skill. Only a message that IS a command: the same
        /// tags quoted in the middle of a message are text.
        private mutating func command(in text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("<command-"),
                  let open = trimmed.range(of: "<command-name>"),
                  let close = trimmed.range(of: "</command-name>", range: open.upperBound..<trimmed.endIndex)
            else { return }
            var name = trimmed[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            if trimmed.contains("<skill-format>true</skill-format>") {
                // A skill: already counted when the model loaded it itself;
                // counted here when the user called it by name.
                if name.hasPrefix("/") { name.removeFirst() }
                if let waiting = skillEchoes[name], waiting > 0 {
                    skillEchoes[name] = waiting - 1
                } else {
                    note(.skill, name)
                }
                return
            }
            note(.command, name.hasPrefix("/") ? name : "/" + name)
        }

        private mutating func system(_ object: [String: Any]) {
            guard object["subtype"] as? String == "stop_hook_summary" else { return }
            let run = (object["toolUseID"] as? String) ?? (object["uuid"] as? String) ?? ""
            guard run.isEmpty || hookRuns.insert("stop|" + run).inserted else { return }
            let commands = ((object["hookInfos"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            let failed = !((object["hookErrors"] as? [Any]) ?? []).isEmpty
            if commands.isEmpty {
                guard (object["hookCount"] as? Int ?? 0) > 0 else { return }
                note(.hook, "Stop", failed: failed)
                return
            }
            for command in commands {
                // Which of several hooks spoke is not said: only a lone one is blamed.
                note(.hook, ClaudeActivity.hookName(event: "Stop", command: command),
                     failed: failed && commands.count == 1)
            }
        }

        private mutating func attachment(_ object: [String: Any]) {
            guard let attachment = object["attachment"] as? [String: Any],
                  let type = attachment["type"] as? String else { return }
            switch type {
            case "skill_listing":
                result.skills.formUnion((attachment["names"] as? [String]) ?? [])
            case "deferred_tools_delta":
                for name in (attachment["addedNames"] as? [String]) ?? [] where name.hasPrefix("mcp__") {
                    result.servers.insert(ActivityTally.split(mcp: String(name.dropFirst(5))).server)
                }
            case "mcp_instructions_delta":
                result.servers.formUnion((attachment["addedNames"] as? [String]) ?? [])
            default:
                guard type.hasPrefix("hook_") else { return }
                hook(attachment, failed: type.contains("error"))
            }
        }

        private mutating func progress(_ object: [String: Any]) {
            guard let data = object["data"] as? [String: Any], data["type"] as? String == "hook_progress" else { return }
            hook(data, failed: false, run: object["toolUseID"] as? String)
        }

        private mutating func hook(_ record: [String: Any], failed: Bool, run: String? = nil) {
            let event = (record["hookName"] as? String) ?? (record["hookEvent"] as? String) ?? "Hook"
            let name = ClaudeActivity.hookName(event: event, command: record["command"] as? String)
            let run = run ?? (record["toolUseID"] as? String) ?? ""
            if !run.isEmpty, !hookRuns.insert(event + "|" + run).inserted {
                // Seen as it started; this line says how it ended.
                if failed { result.days[day]?.fail(.hook, name) }
                return
            }
            note(.hook, name, failed: failed)
        }
    }

    // MARK: Names

    /// What a tool call is: an MCP server's tool, a skill, a sub-agent, or a plain tool.
    static func classify(tool name: String, input: [String: Any]) -> (ActivityTally.Kind, String) {
        if name.hasPrefix("mcp__") { return (.mcp, String(name.dropFirst(5))) }
        switch name {
        case "Skill":
            var skill = (input["skill"] as? String) ?? (input["command"] as? String) ?? "skill"
            if skill.hasPrefix("/") { skill.removeFirst() }
            return (.skill, skill)
        case "Task", "Agent":
            let type = (input["subagent_type"] as? String) ?? ""
            return (.agent, type.isEmpty ? "general-purpose" : type)
        default:
            return (.tool, name)
        }
    }

    /// "Stop · loom-hook stop": the event, and the command when claude names
    /// one. Its placeholder ("command hook") says nothing and is dropped.
    static func hookName(event: String, command: String?) -> String {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty, command != "command hook" else { return event }
        let short = command.count > 80 ? String(command.prefix(79)) + "…" : command
        return event + " · " + short
    }
}
