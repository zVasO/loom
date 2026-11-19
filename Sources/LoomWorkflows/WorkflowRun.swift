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
    /// The orchestrator's Loom session (ADR-0018), once launched.
    public var orchestratorSessionID: String?
    /// Questions, reruns and skips the orchestrator spent.
    public var interventions: Int
    /// What the orchestrator and the steps said to each other, oldest first.
    public var messages: [RunMessage]
    /// Where the agents ran (the PR's worktree, the project): a headless
    /// step's conversation is resumed from there.
    public var workingDirectory: String?
    /// The orchestrator's appended system prompt and model, as launched:
    /// a resumed session gets them again.
    public var orchestratorInstructions: String?
    public var orchestratorModel: String?
    /// Every visible step's session this run launched, every pass and rerun
    /// included: session id (lowercased) → step id.
    public var stepSessions: [String: String]
    /// The palette's blocks and the rule sets, frozen at launch (ADR-0019).
    public var blocks: [WorkflowBlock]
    public var ruleSets: [RuleSet]
    /// The worktree the run works in, when it has one of its own (ADR-0021).
    public var worktree: RunWorktree?
    /// What the run changed there, measured when it ended.
    public var changes: RunChanges?

    public init(id: UUID = UUID(), workflow: Workflow, experts: [Expert], connectors: [Connector],
                inputs: RunInputs, state: RunState, status: Status = .running, startedAt: Date = Date(),
                finishedAt: Date? = nil, costUSD: Double = 0, artifactPath: String? = nil, error: String? = nil,
                orchestratorSessionID: String? = nil, interventions: Int = 0, messages: [RunMessage] = [],
                workingDirectory: String? = nil, orchestratorInstructions: String? = nil,
                orchestratorModel: String? = nil, stepSessions: [String: String] = [:],
                blocks: [WorkflowBlock] = [], ruleSets: [RuleSet] = [],
                worktree: RunWorktree? = nil, changes: RunChanges? = nil) {
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
        self.orchestratorSessionID = orchestratorSessionID
        self.interventions = interventions
        self.messages = messages
        self.workingDirectory = workingDirectory
        self.orchestratorInstructions = orchestratorInstructions
        self.orchestratorModel = orchestratorModel
        self.stepSessions = stepSessions
        self.blocks = blocks
        self.ruleSets = ruleSets
        self.worktree = worktree
        self.changes = changes
    }

    /// Runs saved before the orchestrator have none of its keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  workflow: try c.decode(Workflow.self, forKey: .workflow),
                  experts: try c.decodeIfPresent([Expert].self, forKey: .experts) ?? [],
                  connectors: try c.decodeIfPresent([Connector].self, forKey: .connectors) ?? [],
                  inputs: try c.decodeIfPresent(RunInputs.self, forKey: .inputs) ?? RunInputs(),
                  state: try c.decodeIfPresent(RunState.self, forKey: .state) ?? RunState(),
                  status: try c.decodeIfPresent(Status.self, forKey: .status) ?? .interrupted,
                  startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(),
                  finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt),
                  costUSD: try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0,
                  artifactPath: try c.decodeIfPresent(String.self, forKey: .artifactPath),
                  error: try c.decodeIfPresent(String.self, forKey: .error),
                  orchestratorSessionID: try c.decodeIfPresent(String.self, forKey: .orchestratorSessionID),
                  interventions: try c.decodeIfPresent(Int.self, forKey: .interventions) ?? 0,
                  messages: try c.decodeIfPresent([RunMessage].self, forKey: .messages) ?? [],
                  workingDirectory: try c.decodeIfPresent(String.self, forKey: .workingDirectory),
                  orchestratorInstructions: try c.decodeIfPresent(String.self, forKey: .orchestratorInstructions),
                  orchestratorModel: try c.decodeIfPresent(String.self, forKey: .orchestratorModel),
                  stepSessions: try c.decodeIfPresent([String: String].self, forKey: .stepSessions) ?? [:],
                  blocks: try c.decodeIfPresent([WorkflowBlock].self, forKey: .blocks) ?? [],
                  ruleSets: try c.decodeIfPresent([RuleSet].self, forKey: .ruleSets) ?? [],
                  worktree: try c.decodeIfPresent(RunWorktree.self, forKey: .worktree),
                  changes: try c.decodeIfPresent(RunChanges.self, forKey: .changes))
    }

    /// The step a Loom session runs in this run, if any.
    public func step(ofSession session: String) -> String? {
        let wanted = session.lowercased()
        return stepSessions[wanted] ?? state.nodes.first { $0.value.sessionID?.lowercased() == wanted }?.key
    }

    /// The steps' sessions in the workflow's order, oldest pass first.
    public var stepSessionIDs: [String] {
        let order = Dictionary(workflow.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set(stepSessions.keys)
        for record in state.nodes.values { if let id = record.sessionID?.lowercased() { ids.insert(id) } }
        return ids.sorted { a, b in
            let (sa, sb) = (step(ofSession: a) ?? "", step(ofSession: b) ?? "")
            return (order[sa] ?? .max, a) < (order[sb] ?? .max, b)
        }
    }

    /// The interventions left to the orchestrator.
    public var interventionsLeft: Int {
        max(0, (workflow.orchestrator?.interventionLimit ?? 0) - interventions)
    }

    /// One line for the runs list: "PR #42 · AB-12", or the start of the
    /// task the run was given.
    public var subject: String {
        var parts: [String] = []
        if let number = inputs.prNumber { parts.append("PR #\(number)") }
        if let key = inputs.jiraKey, !key.isEmpty { parts.append(key) }
        if parts.isEmpty, let headline = inputs.taskHeadline { return headline }
        return parts.isEmpty ? "Manual run" : parts.joined(separator: " · ")
    }
}

/// The worktree a run made for itself (ADR-0021): its steps write there,
/// and its branch is what the run leaves behind.
public struct RunWorktree: Codable, Equatable, Sendable {
    public var path: String
    public var branch: String
    /// The commit it started from: what its changes are measured against.
    public var baseRevision: String?

    public init(path: String, branch: String, baseRevision: String? = nil) {
        self.path = path
        self.branch = branch
        self.baseRevision = baseRevision
    }
}

/// What a run changed in its worktree, committed or not: how much, and where.
public struct RunChanges: Codable, Equatable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int
    /// The paths touched, the first few dozen.
    public var paths: [String]
    /// Commits the steps made on the run's branch.
    public var commits: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0, paths: [String] = [], commits: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.paths = paths
        self.commits = commits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(files: try c.decodeIfPresent(Int.self, forKey: .files) ?? 0,
                  additions: try c.decodeIfPresent(Int.self, forKey: .additions) ?? 0,
                  deletions: try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0,
                  paths: try c.decodeIfPresent([String].self, forKey: .paths) ?? [],
                  commits: try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0)
    }

    public var isEmpty: Bool { files == 0 && commits == 0 }

    public static let maxPaths = 40

    /// From `git diff --numstat <base>` (tracked changes against the run's
    /// starting commit, committed or not) and the untracked files of
    /// `git status`: "12\t3\tpath", "-\t-\tbinary".
    public static func parse(numstat: String, untracked: [String] = [], commits: Int = 0) -> RunChanges {
        var changes = RunChanges(commits: max(0, commits))
        var paths: [String] = []
        for line in numstat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            changes.additions += Int(parts[0]) ?? 0
            changes.deletions += Int(parts[1]) ?? 0
            paths.append(String(parts[2]))
        }
        for path in untracked where !paths.contains(path) { paths.append(path) }
        changes.files = paths.count
        changes.paths = Array(paths.prefix(maxPaths))
        return changes
    }

    /// "4 files · +120 −18 · 2 commits".
    public var summary: String {
        guard !isEmpty else { return "no change" }
        var parts = ["\(files) file\(files == 1 ? "" : "s")"]
        if additions > 0 || deletions > 0 { parts.append("+\(additions) −\(deletions)") }
        if commits > 0 { parts.append("\(commits) commit\(commits == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One line of the conversation between the orchestrator and the steps.
public struct RunMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The orchestrator asked a step; the step answered.
        case question, answer
        /// A step wrote to the orchestrator.
        case fromStep
        /// The orchestrator ran a step again, skipped one, stopped the run, let the report go.
        case rerun, skip, stop, proceed
        /// What Loom told the orchestrator.
        case event
    }

    public var id: UUID
    public var kind: Kind
    /// A step id, "orchestrator" or "loom".
    public var from: String
    public var to: String
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), kind: Kind, from: String, to: String, text: String, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.text = text
        self.date = date
    }

    public static let orchestrator = "orchestrator"
    public static let loom = "loom"
}

/// What a run starts from.
public struct RunInputs: Codable, Equatable, Sendable {
    public var trigger: Trigger
    public var projectID: ProjectID?
    public var prNumber: Int?
    public var jiraKey: String?
    /// Free text the user typed at launch — `{{run.note}}`.
    public var note: String
    /// What the run is asked to do, in the person's words — `{{run.task}}`
    /// (ADR-0021). Empty for a workflow that asks for none.
    public var task: String

    public init(trigger: Trigger = .manual, projectID: ProjectID? = nil, prNumber: Int? = nil,
                jiraKey: String? = nil, note: String = "", task: String = "") {
        self.trigger = trigger
        self.projectID = projectID
        self.prNumber = prNumber
        self.jiraKey = jiraKey
        self.note = note
        self.task = task
    }

    /// Runs saved before tasks have none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(trigger: try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .manual,
                  projectID: try c.decodeIfPresent(ProjectID.self, forKey: .projectID),
                  prNumber: try c.decodeIfPresent(Int.self, forKey: .prNumber),
                  jiraKey: try c.decodeIfPresent(String.self, forKey: .jiraKey),
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  task: try c.decodeIfPresent(String.self, forKey: .task) ?? "")
    }

    /// The task's first line, short: what a list calls the run.
    public var taskHeadline: String? {
        let first = task.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return nil }
        return first.count <= 72 ? first : String(first.prefix(71)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A branch name's worth of the task: "Fix the cache bug!" → `fix-the-cache-bug`.
    public var taskSlug: String {
        let source = taskHeadline ?? ""
        let folded = source.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(mapped).split(separator: "-").joined(separator: "-").prefix(40)
        return String(slug.split(separator: "-").joined(separator: "-"))
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
