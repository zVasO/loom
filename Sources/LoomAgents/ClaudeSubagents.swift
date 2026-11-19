import Foundation
import LoomCore

/// The sub-agents of a Claude Code session. claude keeps each one's own
/// conversation beside the session's file, in
/// `<session>/subagents/agent-<id>.jsonl` (one folder deeper for those a
/// workflow starts), with what it was started as in `agent-<id>.meta.json`.
/// Read here so the chat view can open a sub-agent as it opens a tool call.
public enum ClaudeSubagents {

    public struct Agent: Equatable, Sendable {
        public let id: String
        public let file: URL
        /// The meta file's `description` and `agentType`, when it has them.
        public let description: String
        public let type: String
        /// The first thing the sub-agent was told: its brief.
        public let prompt: String
    }

    /// The folder a session's sub-agents live in: its file's name, without `.jsonl`.
    public static func folder(forSessionFile session: URL) -> URL {
        session.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    }

    /// Every sub-agent of the session, two folders deep at most.
    /// Synchronous disk work: call off the main actor.
    public static func list(forSessionFile session: URL) -> [Agent] {
        let root = folder(forSessionFile: session)
        let manager = FileManager.default
        var files: [URL] = []
        for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if isTranscript(entry) {
                files.append(entry)
            } else if isFolder(entry) {
                for deeper in (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] {
                    if isTranscript(deeper) {
                        files.append(deeper)
                    } else if isFolder(deeper) {
                        let last = (try? manager.contentsOfDirectory(at: deeper, includingPropertiesForKeys: nil)) ?? []
                        files.append(contentsOf: last.filter(isTranscript))
                    }
                }
            }
        }
        return files.compactMap(agent(at:))
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func isTranscript(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl"
    }

    /// One sub-agent, from its file's first line and its meta file.
    static func agent(at file: URL) -> Agent? {
        let name = file.deletingPathExtension().lastPathComponent
        let id = String(name.dropFirst("agent-".count))
        guard !id.isEmpty else { return nil }
        var description = ""
        var type = ""
        let meta = file.deletingPathExtension().appendingPathExtension("meta.json")
        if let data = try? Data(contentsOf: meta),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            description = (object["description"] as? String) ?? ""
            type = (object["agentType"] as? String) ?? ""
        }
        return Agent(id: id, file: file, description: description, type: type, prompt: brief(of: file))
    }

    /// The brief: the first line's user message. Only the head of the file
    /// is read — the rest can be megabytes.
    static func brief(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let end = head.firstIndex(of: UInt8(ascii: "\n")) ?? (head.isEmpty ? nil : head.endIndex),
              let object = try? JSONSerialization.jsonObject(with: head[head.startIndex..<end]) as? [String: Any],
              let message = object["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text }
        let blocks = (message["content"] as? [[String: Any]]) ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// The sub-agent a call started: the one its result names, else the one
    /// whose brief is the call's prompt — the only link while it still runs.
    public static func find(_ call: ConversationEntry.AgentCall, in agents: [Agent]) -> Agent? {
        if let id = call.agentID, let named = agents.first(where: { $0.id == id }) { return named }
        let prompt = call.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return agents.first { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }
    }

    /// What the sub-agent did, as a conversation: its tool calls and what it
    /// said, without the brief it opens on (the call already shows it).
    /// Synchronous disk work: call off the main actor.
    public static func entries(of agent: Agent) -> [ConversationEntry] {
        var reader = ClaudeConversation.Reader(sidechain: true)
        reader.refresh(from: agent.file)
        var entries = reader.entries
        if let first = entries.first, case .user = first.kind { entries.removeFirst() }
        return entries
    }

    /// The sub-agent of a call in a session, read: nil when claude has not
    /// written it yet.
    public static func transcript(of call: ConversationEntry.AgentCall,
                                  sessionFile: URL) -> [ConversationEntry]? {
        guard let agent = find(call, in: list(forSessionFile: sessionFile)) else { return nil }
        return entries(of: agent)
    }
}
