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

    public static func validate(_ workflow: Workflow, experts: [Expert] = [], connectors: [Connector] = [],
                                blocks: [WorkflowBlock] = [], ruleSets: [RuleSet] = []) -> [WorkflowIssue] {
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
            issues.append(.init(.error, "The links make a circle: go back up with a link that retries, or a Loop step."))
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
                issues += agentIssues(config, node: node.id, in: workflow, expertIDs: expertIDs,
                                      connectorIDs: connectorIDs, blocks: blocks, ruleSets: ruleSets,
                                      predecessors: predecessors)
            case .forEach(let config):
                if config.items.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(.init(.error, "Say which list to go through (steps.repo.touched…).", node: node.id))
                } else if let problem = templateProblem(config.items, from: node.id, in: workflow,
                                                        predecessors: predecessors) {
                    issues.append(.init(.warning, problem, node: node.id))
                }
                if BlockResolver.effective(config.agent, blocks: blocks).mode == .visible {
                    issues.append(.init(.error, "A step run for each item is headless: one session per item would bury you.",
                                        node: node.id))
                }
                if config.maxItems < 1 || config.maxItems > ForEachConfig.maxItemsAllowed {
                    issues.append(.init(.error, "1 to \(ForEachConfig.maxItemsAllowed) items at most.", node: node.id))
                }
                issues += agentIssues(config.agent, node: node.id, in: workflow, expertIDs: expertIDs,
                                      connectorIDs: connectorIDs, blocks: blocks, ruleSets: ruleSets,
                                      predecessors: predecessors)
            case .approval(let config):
                if config.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(.error, "Write the question the person answers.", node: node.id))
                }
                if config.cleanOptions.count < 2 {
                    issues.append(.init(.error, "Give at least two answers to choose from.", node: node.id))
                }
            case .command(let config):
                if config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(.error, "Write the command to run.", node: node.id))
                }
                if config.command.contains("{{") {
                    issues.append(.init(.error, "No {{…}} in a command: a PR's text never goes into a shell line. "
                                        + "Read $LOOM_PR_NUMBER, $LOOM_PR_BASE, $LOOM_PR_HEAD, $LOOM_REPO_PATH instead.",
                                        node: node.id))
                }
                if config.timeoutSeconds < 1 || config.timeoutSeconds > CommandConfig.maxTimeout {
                    issues.append(.init(.error, "A command runs 1 s to \(CommandConfig.maxTimeout / 60) min.", node: node.id))
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
        issues += edgeIssues(workflow, blocks: blocks, ruleSets: ruleSets)
        if !workflow.nodes.contains(where: { $0.kind.type == .artifact }) {
            issues.append(.init(.warning, "No Artifact step: the run leaves no report."))
        }
        if let orchestrator = workflow.orchestrator {
            if let expert = orchestrator.expertID, !expertIDs.contains(expert) {
                issues.append(.init(.error, "The orchestrator's expert was deleted."))
            }
            if orchestrator.interventionLimit == 0 {
                issues.append(.init(.warning, "The orchestrator has no intervention: it can only read and comment."))
            }
        }
        return issues
    }

    /// An agent step, as it runs: its block resolved.
    private static func agentIssues(_ raw: AgentConfig, node: String, in workflow: Workflow, expertIDs: Set<UUID>,
                                    connectorIDs: Set<UUID>, blocks: [WorkflowBlock], ruleSets: [RuleSet],
                                    predecessors: [String: [String]]) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        if raw.blockID != nil, BlockResolver.block(of: raw, in: blocks) == nil {
            issues.append(.init(.error, "Its block was deleted.", node: node))
        }
        let config = BlockResolver.effective(raw, blocks: blocks)
        if config.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.error, "Write what this step asks.", node: node))
        }
        if config.output.isEmpty, config.verdict == nil {
            issues.append(.init(.warning, "No output field: the next steps only get its text.", node: node))
        }
        let names = config.answerFields.map(\.name)
        if Set(names).count != names.count {
            issues.append(.init(.error, "Two output fields share a name.", node: node))
        }
        if let verdict = config.verdict, verdict.cleanOptions.count < 2 {
            issues.append(.init(.error, "A verdict needs at least two options, the best first.", node: node))
        }
        if let expert = config.expertID, !expertIDs.contains(expert) {
            issues.append(.init(.error, "Its expert was deleted.", node: node))
        }
        for id in config.connectorIDs where !connectorIDs.contains(id) {
            issues.append(.init(.error, "A connector of this step was deleted.", node: node))
        }
        let sets = raw.ruleSetIDs + (BlockResolver.block(of: raw, in: blocks)?.ruleSetIDs ?? [])
        if sets.contains(where: { id in !ruleSets.contains { $0.id == id } }) {
            issues.append(.init(.warning, "A rule set of this step was deleted.", node: node))
        }
        for path in TemplateRenderer.paths(in: config.prompt) {
            if let problem = templateProblem(path, from: node, in: workflow, predecessors: predecessors) {
                issues.append(.init(.warning, problem, node: node))
            }
        }
        return issues
    }

    /// Conditional links and ways back up (ADR-0019).
    private static func edgeIssues(_ workflow: Workflow, blocks: [WorkflowBlock], ruleSets: [RuleSet]) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        let predecessors = WorkflowGraph.predecessors(workflow)
        for edge in workflow.edges {
            guard let source = workflow.node(edge.from), workflow.node(edge.to) != nil else { continue }
            let options = BlockResolver.verdictOptions(of: source, blocks: blocks)
            if let when = edge.when {
                if options.isEmpty {
                    issues.append(.init(.error, "The link to \(edge.to) waits for a verdict \(edge.from) never gives.",
                                        node: edge.from))
                } else if !options.contains(where: { VerdictConfig.same($0, when) }) {
                    issues.append(.init(.error, "«\(when)» is not one of \(edge.from)'s verdicts (\(options.joined(separator: ", "))).",
                                        node: edge.from))
                }
            }
            if edge.otherwise, options.isEmpty {
                issues.append(.init(.warning, "\(edge.from) gives no verdict: its “otherwise” link is always taken.",
                                    node: edge.from))
            }
            if edge.ruleSetIDs.contains(where: { id in !ruleSets.contains { $0.id == id } }) {
                issues.append(.init(.warning, "A rule set of the link to \(edge.to) was deleted.", node: edge.from))
            }
            guard let retry = edge.retry else { continue }
            if edge.when == nil {
                issues.append(.init(.error, "Say on which verdict the run goes back to \(edge.to).", node: edge.from))
            }
            if retry.max < 0 || retry.max > RetryConfig.maxAllowed {
                issues.append(.init(.error, "A way back runs again 0 to \(RetryConfig.maxAllowed) times.", node: edge.from))
            }
            let upstream = WorkflowGraph.reachable(from: [edge.from], next: predecessors)
            if workflow.node(edge.to)?.kind.type == .start {
                issues.append(.init(.error, "A way back cannot go to Start.", node: edge.from))
            } else if edge.from != edge.to, !upstream.contains(edge.to) {
                issues.append(.init(.error, "\(edge.to) is not before \(edge.from): the run cannot go back to it.",
                                    node: edge.from))
            }
            // Spent, the step follows its links forward: something must take the verdict.
            if let when = edge.when {
                let forward = workflow.forwardEdges.filter { $0.from == edge.from }
                let covered = forward.contains { $0.otherwise || $0.when.map { VerdictConfig.same($0, when) } ?? false }
                    || forward.contains { $0.when == nil && !$0.otherwise && $0.branch == nil }
                if !covered {
                    issues.append(.init(.warning, "When its rounds are spent and \(edge.from) still says «\(when)», "
                                        + "nothing follows: add an “otherwise” link.", node: edge.from))
                }
            }
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
        case "pr", "ticket", "repo", "iteration", "run", "in", "item", "index":
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

    public static func estimate(_ workflow: Workflow, experts: [Expert], defaultModel: String,
                                blocks: [WorkflowBlock] = []) -> CostEstimate {
        let planner = WorkflowPlanner(workflow)
        var runs = 0
        var total: Decimal = 0
        var priced = true
        for node in workflow.nodes {
            let model: String
            var items = 1
            switch node.kind {
            case .agent(let raw):
                let config = BlockResolver.effective(raw, blocks: blocks)
                let expert = experts.first { $0.id == config.expertID }
                model = config.model ?? expert?.model ?? defaultModel
            case .forEach(let each):
                let config = BlockResolver.effective(each.agent, blocks: blocks)
                let expert = experts.first { $0.id == config.expertID }
                model = config.model ?? expert?.model ?? defaultModel
                items = each.itemLimit
            case .context(let config) where config.source == .jiraTicket:
                model = "haiku"
            default:
                continue
            }
            var passes = 1
            for (key, body) in planner.loopBodies where body.contains(node.id) {
                if case .loop(let config)? = workflow.node(key)?.kind {
                    passes = max(passes, 1 + min(max(config.maxIterations, 0), LoopConfig.maxAllowed))
                } else if let edge = workflow.retryEdges.first(where: { WorkflowPlanner.retryKey($0) == key }) {
                    passes = max(passes, 1 + (edge.retry?.limit ?? 0))
                }
            }
            passes *= items
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
