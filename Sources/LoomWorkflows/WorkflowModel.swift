import Foundation
import LoomAPI

/// A workflow (ADR-0017): a named graph of steps — a start, context loaders,
/// agents each run by an expert, conditions, bounded loops, and the artifact
/// a run ends with. Edges say what waits for what: several leaving a node
/// dispatch in parallel, several entering one wait for all of them. Loops
/// are not edges: a loop node names the steps it runs again.
public struct Workflow: Codable, Identifiable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var id: UUID
    public var name: String
    public var summary: String
    public var tags: [String]
    /// `#RRGGBB`, the workflow's dot in the library.
    public var color: String
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    /// The run's conductor (ADR-0018): a Loom session that follows the run,
    /// talks to its steps and steers it. nil: none.
    public var orchestrator: OrchestratorConfig?
    public var createdAt: Date
    public var updatedAt: Date
    public var formatVersion: Int

    public init(id: UUID = UUID(), name: String, summary: String = "", tags: [String] = [],
                color: String = "#0D6E74", nodes: [WorkflowNode] = [], edges: [WorkflowEdge] = [],
                orchestrator: OrchestratorConfig? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                formatVersion: Int = Workflow.currentFormatVersion) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tags = tags
        self.color = color
        self.nodes = nodes
        self.edges = edges
        self.orchestrator = orchestrator
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.formatVersion = formatVersion
    }

    /// Files written by hand or by the editor may leave keys out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled workflow",
                  summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
                  tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
                  color: try c.decodeIfPresent(String.self, forKey: .color) ?? "#0D6E74",
                  nodes: try c.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? [],
                  edges: try c.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? [],
                  orchestrator: try c.decodeIfPresent(OrchestratorConfig.self, forKey: .orchestrator),
                  createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
                  formatVersion: try c.decodeIfPresent(Int.self, forKey: .formatVersion)
                    ?? Workflow.currentFormatVersion)
    }

    public func node(_ id: String) -> WorkflowNode? { nodes.first { $0.id == id } }

    public var start: WorkflowNode? { nodes.first { $0.kind.type == .start } }

    /// The triggers its start accepts — none without a start.
    public var triggers: [Trigger] {
        if case .start(let config)? = start?.kind { return config.triggers }
        return []
    }
}

public struct WorkflowNode: Codable, Identifiable, Equatable, Sendable {
    /// Short and stable (`intent`, `php`): templates name a step by it.
    public var id: String
    public var title: String
    public var position: Position
    public var kind: NodeKind

    public init(id: String, title: String, position: Position = Position(), kind: NodeKind) {
        self.id = id
        self.title = title
        self.position = position
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, title, position, type, config }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? Position()
        let type = try c.decode(NodeType.self, forKey: .type)
        func config<T: Decodable>(_: T.Type, _ fallback: @autoclosure () -> T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: .config) ?? fallback()
        }
        switch type {
        case .start: kind = .start(try config(StartConfig.self, StartConfig()))
        case .context: kind = .context(try config(ContextConfig.self, ContextConfig()))
        case .agent: kind = .agent(try config(AgentConfig.self, AgentConfig()))
        case .condition: kind = .condition(try config(ConditionConfig.self, ConditionConfig()))
        case .loop: kind = .loop(try config(LoopConfig.self, LoopConfig()))
        case .artifact: kind = .artifact(try config(ArtifactConfig.self, ArtifactConfig()))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(position, forKey: .position)
        try c.encode(kind.type, forKey: .type)
        switch kind {
        case .start(let config): try c.encode(config, forKey: .config)
        case .context(let config): try c.encode(config, forKey: .config)
        case .agent(let config): try c.encode(config, forKey: .config)
        case .condition(let config): try c.encode(config, forKey: .config)
        case .loop(let config): try c.encode(config, forKey: .config)
        case .artifact(let config): try c.encode(config, forKey: .config)
        }
    }
}

public struct Position: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct WorkflowEdge: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    /// Out of a condition: the branch this edge belongs to.
    public var branch: Branch?

    public init(id: String? = nil, from: String, to: String, branch: Branch? = nil) {
        self.id = id ?? "\(from)->\(to)" + (branch.map { ":\($0.rawValue)" } ?? "")
        self.from = from
        self.to = to
        self.branch = branch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let from = try c.decode(String.self, forKey: .from)
        let to = try c.decode(String.self, forKey: .to)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id), from: from, to: to,
                  branch: try c.decodeIfPresent(Branch.self, forKey: .branch))
    }
}

public enum Branch: String, Codable, Sendable, CaseIterable {
    case yes, no
}

// MARK: - Node kinds

public enum NodeType: String, Codable, Sendable, CaseIterable {
    case start, context, agent, condition, loop, artifact
}

public enum NodeKind: Equatable, Sendable {
    case start(StartConfig)
    case context(ContextConfig)
    case agent(AgentConfig)
    case condition(ConditionConfig)
    case loop(LoopConfig)
    case artifact(ArtifactConfig)

    public var type: NodeType {
        switch self {
        case .start: .start
        case .context: .context
        case .agent: .agent
        case .condition: .condition
        case .loop: .loop
        case .artifact: .artifact
        }
    }
}

/// What can start a run.
public enum Trigger: String, Codable, Sendable, CaseIterable {
    /// The Workflows tab's "Run", or ⌘K.
    case manual
    /// A PR's tab, with the PR as input.
    case pullRequest
    /// A Jira key alone, no PR.
    case jiraTicket
    /// A review schedule, once per PR it picks.
    case schedule
}

public struct StartConfig: Codable, Equatable, Sendable {
    public var triggers: [Trigger]
    public init(triggers: [Trigger] = [.manual, .pullRequest]) { self.triggers = triggers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? [.manual, .pullRequest]
    }
}

/// Built-in loaders: what a step knows before any agent reads it.
public enum ContextSource: String, Codable, Sendable, CaseIterable {
    /// Body, files, conversation, checks — and the review worktree.
    case pullRequest
    /// The ticket, read through an Atlassian MCP connector.
    case jiraTicket
    /// The worktree's tree, README and the files the PR touches.
    case repository
}

public struct ContextConfig: Codable, Equatable, Sendable {
    public var source: ContextSource
    /// For a ticket: the connector it is read through.
    public var connectorIDs: [UUID]
    public init(source: ContextSource = .pullRequest, connectorIDs: [UUID] = []) {
        self.source = source
        self.connectorIDs = connectorIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ContextSource.self, forKey: .source) ?? .pullRequest
        connectorIDs = try c.decodeIfPresent([UUID].self, forKey: .connectorIDs) ?? []
    }
}

/// How an agent step runs.
public enum AgentMode: String, Codable, Sendable, CaseIterable {
    /// `claude -p`: parallel, structured answer, nothing on screen.
    case headless
    /// A Loom session in the sidebar: followed live, taken over at will.
    case visible
}

public enum FieldType: String, Codable, Sendable, CaseIterable {
    case text, list, boolean, number, object
}

/// One field of a step's answer: what the next steps can name.
public struct OutputField: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: FieldType
    public var description: String
    public var required: Bool

    public init(_ name: String, _ type: FieldType, _ description: String = "", required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(FieldType.self, forKey: .type) ?? .text
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

public struct AgentConfig: Codable, Equatable, Sendable {
    /// The expert running the step; nil runs claude as configured.
    public var expertID: UUID?
    /// A template (`{{steps.intent.intent}}`…).
    public var prompt: String
    public var output: [OutputField]
    public var mode: AgentMode
    /// Over the expert's: an alias (`sonnet`) or a model id.
    public var model: String?
    /// Skills injected for THIS step only, on top of the expert's.
    public var skills: [String]
    /// Connectors for this step, on top of the expert's.
    public var connectorIDs: [UUID]
    public var timeoutSeconds: Int

    public init(expertID: UUID? = nil, prompt: String = "", output: [OutputField] = [],
                mode: AgentMode = .headless, model: String? = nil, skills: [String] = [],
                connectorIDs: [UUID] = [], timeoutSeconds: Int = 900) {
        self.expertID = expertID
        self.prompt = prompt
        self.output = output
        self.mode = mode
        self.model = model
        self.skills = skills
        self.connectorIDs = connectorIDs
        self.timeoutSeconds = timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(expertID: try c.decodeIfPresent(UUID.self, forKey: .expertID),
                  prompt: try c.decodeIfPresent(String.self, forKey: .prompt) ?? "",
                  output: try c.decodeIfPresent([OutputField].self, forKey: .output) ?? [],
                  mode: try c.decodeIfPresent(AgentMode.self, forKey: .mode) ?? .headless,
                  model: try c.decodeIfPresent(String.self, forKey: .model),
                  skills: try c.decodeIfPresent([String].self, forKey: .skills) ?? [],
                  connectorIDs: try c.decodeIfPresent([UUID].self, forKey: .connectorIDs) ?? [],
                  timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 900)
    }
}

public enum ConditionOperator: String, Codable, Sendable, CaseIterable {
    case isTrue, isFalse, equals, notEquals, contains, isEmpty, isNotEmpty, greaterThan, lessThan
}

/// A test on a value the run knows (`steps.coherence.stable`).
public struct Condition: Codable, Equatable, Sendable {
    public var path: String
    public var op: ConditionOperator
    public var value: String

    public init(path: String, op: ConditionOperator = .isTrue, value: String = "") {
        self.path = path
        self.op = op
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        op = try c.decodeIfPresent(ConditionOperator.self, forKey: .op) ?? .isTrue
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

public struct ConditionConfig: Codable, Equatable, Sendable {
    public var condition: Condition
    public init(condition: Condition = Condition(path: "")) { self.condition = condition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = try c.decodeIfPresent(Condition.self, forKey: .condition) ?? Condition(path: "")
    }
}

/// Runs its body again: every step on a path from one of `targets` to the
/// loop. Always bounded — `maxIterations` extra passes at most.
public struct LoopConfig: Codable, Equatable, Sendable {
    public var targets: [String]
    public var maxIterations: Int
    /// Leaves the loop early when it holds after a pass.
    public var stopWhen: Condition?

    public static let maxAllowed = 5

    public init(targets: [String] = [], maxIterations: Int = 2, stopWhen: Condition? = nil) {
        self.targets = targets
        self.maxIterations = maxIterations
        self.stopWhen = stopWhen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 2
        stopWhen = try c.decodeIfPresent(Condition.self, forKey: .stopWhen)
    }
}

public struct ArtifactConfig: Codable, Equatable, Sendable {
    /// A built-in template id (`pr-review`, `generic`).
    public var template: String
    /// `current` (the app's theme) or the name of a Loom theme family.
    public var theme: String
    /// The family's dark variant instead of its light one.
    public var dark: Bool
    /// A template: the report's title.
    public var title: String
    /// Findings with a path and a line become the PR tab's pending review.
    public var importToPRTab: Bool

    public init(template: String = "pr-review", theme: String = "current", dark: Bool = false,
                title: String = "{{pr.title}}", importToPRTab: Bool = false) {
        self.template = template
        self.theme = theme
        self.dark = dark
        self.title = title
        self.importToPRTab = importToPRTab
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(template: try c.decodeIfPresent(String.self, forKey: .template) ?? "pr-review",
                  theme: try c.decodeIfPresent(String.self, forKey: .theme) ?? "current",
                  dark: try c.decodeIfPresent(Bool.self, forKey: .dark) ?? false,
                  title: try c.decodeIfPresent(String.self, forKey: .title) ?? "{{pr.title}}",
                  importToPRTab: try c.decodeIfPresent(Bool.self, forKey: .importToPRTab) ?? false)
    }
}

/// The orchestrator of a workflow's runs (ADR-0018): a visible session that
/// receives each step's result, may question any step, run one again with
/// instructions, skip one or stop the run — within a budget.
public struct OrchestratorConfig: Codable, Equatable, Sendable {
    /// The expert it speaks as; nil runs claude as configured.
    public var expertID: UUID?
    /// Over the expert's: an alias (`opus`) or a model id.
    public var model: String?
    /// What this workflow expects of it, on top of Loom's own rules (a template).
    public var instructions: String
    /// Questions, reruns and skips, together, over a whole run.
    public var maxInterventions: Int
    /// How many times it may run one step again.
    public var maxRerunsPerStep: Int
    /// The report waits for its go-ahead (or the end of its turn).
    public var reviewBeforeArtifact: Bool

    public static let maxInterventionsAllowed = 50
    public static let maxRerunsAllowed = 5

    public init(expertID: UUID? = nil, model: String? = nil, instructions: String = "",
                maxInterventions: Int = 12, maxRerunsPerStep: Int = 2, reviewBeforeArtifact: Bool = true) {
        self.expertID = expertID
        self.model = model
        self.instructions = instructions
        self.maxInterventions = maxInterventions
        self.maxRerunsPerStep = maxRerunsPerStep
        self.reviewBeforeArtifact = reviewBeforeArtifact
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(expertID: try c.decodeIfPresent(UUID.self, forKey: .expertID),
                  model: try c.decodeIfPresent(String.self, forKey: .model),
                  instructions: try c.decodeIfPresent(String.self, forKey: .instructions) ?? "",
                  maxInterventions: try c.decodeIfPresent(Int.self, forKey: .maxInterventions) ?? 12,
                  maxRerunsPerStep: try c.decodeIfPresent(Int.self, forKey: .maxRerunsPerStep) ?? 2,
                  reviewBeforeArtifact: try c.decodeIfPresent(Bool.self, forKey: .reviewBeforeArtifact) ?? true)
    }

    /// The budget as the runner enforces it: never negative, never past the caps.
    public var interventionLimit: Int { min(max(maxInterventions, 0), Self.maxInterventionsAllowed) }
    public var rerunLimit: Int { min(max(maxRerunsPerStep, 0), Self.maxRerunsAllowed) }
}
