import Foundation
import LoomCore

/// What keeps a workflow from running, step by step — the editor marks the
/// steps, the Run button stays off while an error remains.
public struct WorkflowIssue: Codable, Equatable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var id: String { (nodeID ?? "-") + ":" + message }
    public let nodeID: String?
    public let severity: Severity
    public let message: String

    public init(_ severity: Severity, _ message: String, node: String? = nil) {
        self.severity = severity
        self.message = message
        self.nodeID = node
    }
}

public enum WorkflowValidator {

    public static func validate(_ workflow: Workflow, experts: [Expert] = [],
                                connectors: [Connector] = []) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        let ids = workflow.nodes.map(\.id)
        let known = Set(ids)
        if Set(ids).count != ids.count {
            issues.append(.init(.error, "Two steps share an id."))
        }
        let starts = workflow.nodes.filter { $0.kind.type == .start }
        if starts.isEmpty { issues.append(.init(.error, "Add a Start step: it is where a run begins.")) }
        for extra in starts.dropFirst() {
            issues.append(.init(.error, "A workflow has one Start step.", node: extra.id))
        }
        for edge in workflow.edges where !known.contains(edge.from) || !known.contains(edge.to) {
            issues.append(.init(.error, "A link points to a step that no longer exists."))
        }
        if WorkflowGraph.hasCycle(workflow) {
            issues.append(.init(.error, "The links make a circle: go around with a Loop step instead."))
        }
        let predecessors = WorkflowGraph.predecessors(workflow)
        let successors = WorkflowGraph.successors(workflow)
        let reachable = WorkflowGraph.reachable(from: starts.map(\.id), next: successors)
        let expertIDs = Set(experts.map(\.id))
        let connectorIDs = Set(connectors.map(\.id))

        for node in workflow.nodes {
            if node.kind.type != .start, !reachable.contains(node.id) {
                issues.append(.init(.warning, "No path from Start reaches this step: it never runs.", node: node.id))
            }
            if node.kind.type == .start, !(predecessors[node.id] ?? []).isEmpty {
                issues.append(.init(.error, "Nothing leads into Start.", node: node.id))
            }
            switch node.kind {
            case .start(let config):
                if config.triggers.isEmpty {
                    issues.append(.init(.error, "Choose at least one way to start a run.", node: node.id))
                }
            case .context(let config):
                if config.source == .jiraTicket, config.connectorIDs.isEmpty {
                    issues.append(.init(.error, "Pick the Atlassian connector the ticket is read through.", node: node.id))
                }
                for id in config.connectorIDs where !connectorIDs.contains(id) {
                    issues.append(.init(.error, "A connector of this step was deleted.", node: node.id))
                }
            case .agent(let config):
                if config.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(.error, "Write what this step asks.", node: node.id))
                }
                if config.output.isEmpty {
                    issues.append(.init(.warning, "No output field: the next steps only get its text.", node: node.id))
                }
                if Set(config.output.map(\.name)).count != config.output.count {
                    issues.append(.init(.error, "Two output fields share a name.", node: node.id))
                }
                if let expert = config.expertID, !expertIDs.contains(expert) {
                    issues.append(.init(.error, "Its expert was deleted.", node: node.id))
                }
                for id in config.connectorIDs where !connectorIDs.contains(id) {
                    issues.append(.init(.error, "A connector of this step was deleted.", node: node.id))
                }
                for path in TemplateRenderer.paths(in: config.prompt) {
                    if let problem = templateProblem(path, from: node.id, in: workflow, predecessors: predecessors) {
                        issues.append(.init(.warning, problem, node: node.id))
                    }
                }
            case .condition(let config):
                if config.condition.path.isEmpty {
                    issues.append(.init(.error, "Say what the condition tests.", node: node.id))
                }
                let branches = workflow.edges.filter { $0.from == node.id }.compactMap(\.branch)
                if branches.isEmpty {
                    issues.append(.init(.warning, "Link its Yes or No output to a step.", node: node.id))
                }
            case .loop(let config):
                if config.targets.isEmpty {
                    issues.append(.init(.error, "Choose the steps the loop runs again.", node: node.id))
                }
                if config.maxIterations < 0 || config.maxIterations > LoopConfig.maxAllowed {
                    issues.append(.init(.error, "A loop runs again 0 to \(LoopConfig.maxAllowed) times.", node: node.id))
                }
                let upstream = WorkflowGraph.reachable(from: [node.id], next: predecessors)
                for target in config.targets where !upstream.contains(target) {
                    issues.append(.init(.error, "\(target) is not before the loop: it cannot run again.", node: node.id))
                }
            case .artifact:
                break
            }
        }
        if !workflow.nodes.contains(where: { $0.kind.type == .artifact }) {
            issues.append(.init(.warning, "No Artifact step: the run leaves no report."))
        }
        return issues
    }

    public static func hasErrors(_ issues: [WorkflowIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    /// `steps.x…` must name a step that runs before this one.
    private static func templateProblem(_ path: String, from node: String, in workflow: Workflow,
                                        predecessors: [String: [String]]) -> String? {
        let parts = path.split(separator: ".").map(String.init)
        guard let root = parts.first else { return nil }
        switch root {
        case "steps", "previous", "history":
            guard parts.count >= 2 else { return "{{\(path)}} names no step." }
            guard workflow.node(parts[1]) != nil else { return "{{\(path)}}: no step \(parts[1])." }
            if root == "steps" {
                let upstream = WorkflowGraph.reachable(from: [node], next: predecessors)
                if !upstream.contains(parts[1]) {
                    return "{{\(path)}}: \(parts[1]) does not run before this step."
                }
            }
            return nil
        case "pr", "ticket", "repo", "iteration", "run":
            return nil
        default:
            return "{{\(path)}} is not a known variable."
        }
    }
}

/// An order of magnitude, shown before a run starts: how many claude runs
/// the workflow may make at most, and what that may cost.
public struct CostEstimate: Equatable, Sendable, Codable {
    public let runs: Int
    public let lowUSD: Double?
    public let highUSD: Double?

    /// Per run: a large read (mostly cached), a few thousand tokens written.
    static let typicalInput = 25_000, typicalCacheWrite = 15_000, typicalCacheRead = 60_000,
               typicalOutput = 5_000

    /// Aliases a step may name, to a priced family.
    static func modelID(for alias: String) -> String {
        switch alias.lowercased() {
        case "opus": "claude-opus-5"
        case "sonnet": "claude-sonnet-5"
        case "haiku": "claude-haiku-4-5"
        default: alias
        }
    }

    public static func estimate(_ workflow: Workflow, experts: [Expert],
                                defaultModel: String) -> CostEstimate {
        let planner = WorkflowPlanner(workflow)
        var runs = 0
        var total: Decimal = 0
        var priced = true
        for node in workflow.nodes {
            let model: String
            switch node.kind {
            case .agent(let config):
                let expert = experts.first { $0.id == config.expertID }
                model = config.model ?? expert?.model ?? defaultModel
            case .context(let config) where config.source == .jiraTicket:
                model = "haiku"
            default:
                continue
            }
            var passes = 1
            for (loop, body) in planner.loopBodies where body.contains(node.id) {
                if case .loop(let config)? = workflow.node(loop)?.kind {
                    passes = max(passes, 1 + min(max(config.maxIterations, 0), LoopConfig.maxAllowed))
                }
            }
            runs += passes
            if let cost = ModelPricing.cost(input: typicalInput, cacheWrite5m: typicalCacheWrite,
                                            cacheWrite1h: 0, cacheRead: typicalCacheRead,
                                            output: typicalOutput, modelID: modelID(for: model)) {
                total += cost * Decimal(passes)
            } else {
                priced = false
            }
        }
        guard priced else { return CostEstimate(runs: runs, lowUSD: nil, highUSD: nil) }
        let value = NSDecimalNumber(decimal: total).doubleValue
        return CostEstimate(runs: runs, lowUSD: value * 0.4, highUSD: value * 2)
    }
}
