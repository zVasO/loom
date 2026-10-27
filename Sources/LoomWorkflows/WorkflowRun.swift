import Foundation
import LoomAPI
import LoomCore

/// One execution of a workflow, on disk as `<support>/workflow-runs/<id>/run.json`.
/// The workflow, its experts and its connectors are frozen at launch: an
/// edit made during the run changes the next one, never this one.
public struct WorkflowRun: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, cancelled
        /// Loom quit while it ran.
        case interrupted

        public var isActive: Bool { self == .running }
    }

    public var id: UUID
    public var workflow: Workflow
    public var experts: [Expert]
    public var connectors: [Connector]
    public var inputs: RunInputs
    public var state: RunState
    public var status: Status
    public var startedAt: Date
    public var finishedAt: Date?
    /// What claude reported spending, summed over the steps.
    public var costUSD: Double
    /// The report, once written (absolute path).
    public var artifactPath: String?
    /// Why the run stopped, when it did not succeed.
    public var error: String?

    public init(id: UUID = UUID(), workflow: Workflow, experts: [Expert], connectors: [Connector],
                inputs: RunInputs, state: RunState, status: Status = .running, startedAt: Date = Date(),
                finishedAt: Date? = nil, costUSD: Double = 0, artifactPath: String? = nil, error: String? = nil) {
        self.id = id
        self.workflow = workflow
        self.experts = experts
        self.connectors = connectors
        self.inputs = inputs
        self.state = state
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.costUSD = costUSD
        self.artifactPath = artifactPath
        self.error = error
    }

    /// One line for the runs list: "PR #42 · AB-12".
    public var subject: String {
        var parts: [String] = []
        if let number = inputs.prNumber { parts.append("PR #\(number)") }
        if let key = inputs.jiraKey, !key.isEmpty { parts.append(key) }
        return parts.isEmpty ? "Manual run" : parts.joined(separator: " · ")
    }
}

/// What a run starts from.
public struct RunInputs: Codable, Equatable, Sendable {
    public var trigger: Trigger
    public var projectID: ProjectID?
    public var prNumber: Int?
    public var jiraKey: String?
    /// Free text the user typed at launch — `{{run.note}}`.
    public var note: String

    public init(trigger: Trigger = .manual, projectID: ProjectID? = nil, prNumber: Int? = nil,
                jiraKey: String? = nil, note: String = "") {
        self.trigger = trigger
        self.projectID = projectID
        self.prNumber = prNumber
        self.jiraKey = jiraKey
        self.note = note
    }
}

/// Jira keys (`ABC-123`) where a PR mentions them: its title first, then
/// its branch, then its body.
public enum JiraKey {
    public static func detect(in texts: [String]) -> String? {
        for text in texts {
            if let key = first(in: text) { return key }
        }
        return nil
    }

    public static func first(in text: String) -> String? {
        // A key is uppercase letters (a digit allowed after the first), a
        // dash, digits; branches often spell it lowercase (feat/abc-123-x).
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9]{1,9})-(\d{1,7})(?![0-9])"#)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let project = Range(match.range(at: 1), in: text),
                  let number = Range(match.range(at: 2), in: text) else { continue }
            let prefix = String(text[project])
            // "utf-8", "sha-256", "v1-2": words, not projects.
            if ["utf", "sha", "iso", "rfc", "pr", "issue", "md"].contains(prefix.lowercased()) { continue }
            let isUpper = prefix == prefix.uppercased()
            let looksLikeBranch = text.contains("/") && !text.contains(" ")
            guard isUpper || looksLikeBranch else { continue }
            return prefix.uppercased() + "-" + text[number]
        }
        return nil
    }
}

/// Runs on disk: one folder each, `run.json` rewritten as the run moves.
public struct WorkflowRunStore: Sendable {
    public let root: URL

    public init(directory: URL) {
        root = directory
    }

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

    public func save(_ run: WorkflowRun) throws {
        let folder = folder(for: run.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WorkflowJSON.encoder.encode(run).write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    /// Newest first. A run still "running" on disk was cut short by a quit.
    public func load() -> [WorkflowRun] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> WorkflowRun? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")),
                  var run = try? WorkflowJSON.decoder.decode(WorkflowRun.self, from: data) else { return nil }
            if run.status == .running {
                run.status = .interrupted
                for (id, record) in run.state.nodes where record.status == .running || record.status == .waitingOnUser {
                    run.state.nodes[id]?.status = .failed
                    run.state.nodes[id]?.error = "Loom quit while this step ran."
                }
            }
            return run
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Appends a timestamped line to the run's `log.txt`.
    public func log(_ line: String, run id: UUID, at date: Date = Date()) {
        let url = folder(for: id).appendingPathComponent("log.txt")
        let stamp = ISO8601DateFormatter().string(from: date)
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
