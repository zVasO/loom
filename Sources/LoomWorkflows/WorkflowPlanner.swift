import Foundation
import LoomAPI

public enum NodeStatus: String, Codable, Sendable {
    case pending, running, waitingOnUser, done, failed, skipped

    public var isSettled: Bool { self == .done || self == .failed || self == .skipped }
}

/// One step of a run, in its current pass.
public struct NodeRecord: Codable, Equatable, Sendable {
    public var status: NodeStatus
    /// The structured answer (an object), once done.
    public var output: JSONValue?
    /// The answer as text — what `{{steps.x.text}}` gives.
    public var text: String?
    public var error: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var costUSD: Double?
    /// A visible step's Loom session.
    public var sessionID: String?
    /// A headless step's claude conversation: `claude -p --resume` asks it
    /// a follow-up with everything it read (ADR-0018).
    public var claudeSessionID: String?
    /// How many times the orchestrator ran it again.
    public var reruns: Int
    /// The orchestrator's instructions for its next run, after the prompt.
    public var extraInstructions: String?

    public init(status: NodeStatus = .pending, output: JSONValue? = nil, text: String? = nil,
                error: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil,
                costUSD: Double? = nil, sessionID: String? = nil, claudeSessionID: String? = nil,
                reruns: Int = 0, extraInstructions: String? = nil) {
        self.status = status
        self.output = output
        self.text = text
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.costUSD = costUSD
        self.sessionID = sessionID
        self.claudeSessionID = claudeSessionID
        self.reruns = reruns
        self.extraInstructions = extraInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(status: try c.decodeIfPresent(NodeStatus.self, forKey: .status) ?? .pending,
                  output: try c.decodeIfPresent(JSONValue.self, forKey: .output),
                  text: try c.decodeIfPresent(String.self, forKey: .text),
                  error: try c.decodeIfPresent(String.self, forKey: .error),
                  startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt),
                  finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt),
                  costUSD: try c.decodeIfPresent(Double.self, forKey: .costUSD),
                  sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
                  claudeSessionID: try c.decodeIfPresent(String.self, forKey: .claudeSessionID),
                  reruns: try c.decodeIfPresent(Int.self, forKey: .reruns) ?? 0,
                  extraInstructions: try c.decodeIfPresent(String.self, forKey: .extraInstructions))
    }

    /// A fresh record for the step's next run: what the orchestrator asked
    /// of it stays with it.
    func reset() -> NodeRecord {
        NodeRecord(reruns: reruns, extraInstructions: extraInstructions)
    }
}

/// Where a run stands: every step's record, the passes each loop made, the
/// answers of the passes before, the branches conditions took.
public struct RunState: Codable, Equatable, Sendable {
    public var nodes: [String: NodeRecord]
    /// Loop id → extra passes made so far.
    public var iterations: [String: Int]
    /// Step id → its answers in earlier passes, oldest first.
    public var history: [String: [JSONValue]]
    /// Condition id → the branch it took.
    public var branches: [String: Branch]

    public init(nodes: [String: NodeRecord] = [:], iterations: [String: Int] = [:],
                history: [String: [JSONValue]] = [:], branches: [String: Branch] = [:]) {
        self.nodes = nodes
        self.iterations = iterations
        self.history = history
        self.branches = branches
    }

    public func status(_ id: String) -> NodeStatus { nodes[id]?.status ?? .pending }
}

/// The rules of a run, pure: which steps may start, what a condition or a
/// loop does, when the run is over. The runner executes; this decides.
public struct WorkflowPlanner: Sendable {
    public let workflow: Workflow
    private let incoming: [String: [WorkflowEdge]]
    private let outgoing: [String: [WorkflowEdge]]
    /// Loop id, or `edge:<id>` for a way back up → the steps it runs again.
    public let loopBodies: [String: Set<String>]

    public init(_ workflow: Workflow) {
        self.workflow = workflow
        incoming = Dictionary(grouping: workflow.forwardEdges, by: \.to)
        outgoing = Dictionary(grouping: workflow.forwardEdges, by: \.from)
        var bodies: [String: Set<String>] = [:]
        for node in workflow.nodes {
            if case .loop(let config) = node.kind {
                bodies[node.id] = WorkflowGraph.body(of: node.id, targets: config.targets, in: workflow)
            }
        }
        for edge in workflow.retryEdges {
            bodies[Self.retryKey(edge)] = WorkflowGraph.retryBody(edge, in: workflow)
        }
        loopBodies = bodies
    }

    /// Where a way back up counts its rounds, in `RunState.iterations`.
    public static func retryKey(_ edge: WorkflowEdge) -> String { "edge:" + edge.id }

    /// The verdict a settled step answered, if any.
    public func verdict(of id: String, in state: RunState) -> String? {
        state.nodes[id]?.output?["verdict"]?.plainText
    }

    public func initialState() -> RunState {
        RunState(nodes: Dictionary(uniqueKeysWithValues: workflow.nodes.map { ($0.id, NodeRecord()) }))
    }

    /// The pass a step is in: 1, then 2 after its loop ran it again…
    public func pass(of id: String, in state: RunState) -> Int {
        1 + (loopBodies.filter { $0.value.contains(id) }.map { state.iterations[$0.key] ?? 0 }.max() ?? 0)
    }

    /// The highest pass any loop reached — `{{iteration}}` outside a loop.
    public func currentPass(in state: RunState) -> Int {
        1 + (state.iterations.values.max() ?? 0)
    }

    // MARK: Readiness

    private enum EdgeState { case live, dead, waiting, blocked }

    private func state(of edge: WorkflowEdge, in state: RunState) -> EdgeState {
        switch state.status(edge.from) {
        case .done:
            if let branch = edge.branch, state.branches[edge.from] != branch { return .dead }
            return followsVerdict(edge, in: state) ? .live : .dead
        case .skipped: return .dead
        case .failed: return .blocked
        case .pending, .running, .waitingOnUser: return .waiting
        }
    }

    /// A link out of a settled step follows its verdict: `when` matches it,
    /// `otherwise` takes what no other link forward does.
    private func followsVerdict(_ edge: WorkflowEdge, in state: RunState) -> Bool {
        let given = self.verdict(of: edge.from, in: state)
        if let when = edge.when {
            return given.map { VerdictConfig.same($0, when) } ?? false
        }
        if edge.otherwise {
            let siblings = (outgoing[edge.from] ?? []).filter { $0.id != edge.id && $0.when != nil }
            return !siblings.contains { sibling in given.map { VerdictConfig.same($0, sibling.when!) } ?? false }
        }
        return true
    }

    /// The run took this link: its source settled and it is live.
    public func isTaken(_ edge: WorkflowEdge, in state: RunState) -> Bool {
        !edge.isRetry && self.state(of: edge, in: state) == .live
    }

    /// Pending steps whose every input settled with at least one live: they
    /// may start. The start step is ready at once.
    public func ready(_ state: RunState) -> [String] {
        workflow.nodes.compactMap { node in
            guard state.status(node.id) == .pending else { return nil }
            let edges = incoming[node.id] ?? []
            if edges.isEmpty { return node.kind.type == .start ? node.id : nil }
            let states = edges.map { self.state(of: $0, in: state) }
            guard !states.contains(.waiting), !states.contains(.blocked),
                  states.contains(.live) else { return nil }
            return node.id
        }
    }

    /// Settles what can no longer run: a step behind a failed one is
    /// skipped as blocked, one whose inputs are all dead branches is skipped.
    /// Returns whether anything changed — call until it does not.
    @discardableResult
    public func propagate(_ state: inout RunState) -> Bool {
        var changed = false
        var again = true
        while again {
            again = false
            for node in workflow.nodes where state.status(node.id) == .pending {
                let edges = incoming[node.id] ?? []
                if edges.isEmpty {
                    // Only the start may stand alone; an orphan never runs.
                    if node.kind.type != .start {
                        state.nodes[node.id] = NodeRecord(status: .skipped, error: "No step leads here.")
                        again = true
                        changed = true
                    }
                    continue
                }
                let states = edges.map { self.state(of: $0, in: state) }
                if let failed = edges.first(where: { self.state(of: $0, in: state) == .blocked }) {
                    state.nodes[node.id] = NodeRecord(status: .skipped,
                                                      error: "Blocked: \(failed.from) failed.")
                    again = true
                    changed = true
                } else if !states.contains(.waiting), !states.contains(.live) {
                    state.nodes[node.id] = NodeRecord(status: .skipped)
                    again = true
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: Steps

    public func markRunning(_ id: String, in state: inout RunState, at date: Date = Date()) {
        var record = (state.nodes[id] ?? NodeRecord()).reset()
        record.status = .running
        record.startedAt = date
        state.nodes[id] = record
    }

    public func complete(_ id: String, output: JSONValue?, text: String?, costUSD: Double? = nil,
                         in state: inout RunState, at date: Date = Date()) {
        var record = state.nodes[id] ?? NodeRecord()
        record.status = .done
        record.output = output
        record.text = text
        record.costUSD = costUSD
        record.finishedAt = date
        state.nodes[id] = record
        goBackIfAsked(id, in: &state)
        propagate(&state)
    }

    /// A way back up whose verdict the step just answered, with rounds left:
    /// the steps from its target to the step run again (ADR-0019). Spent,
    /// the step follows its links forward. Returns the link taken back.
    @discardableResult
    func goBackIfAsked(_ id: String, in state: inout RunState) -> WorkflowEdge? {
        guard let given = self.verdict(of: id, in: state) else { return nil }
        for edge in workflow.retryEdges where edge.from == id {
            guard let when = edge.when, VerdictConfig.same(given, when) else { continue }
            let key = Self.retryKey(edge)
            let done = state.iterations[key] ?? 0
            guard done < (edge.retry?.limit ?? 0), let body = loopBodies[key], !body.isEmpty else { continue }
            state.iterations[key] = done + 1
            sendAround(body, in: &state)
            return edge
        }
        return nil
    }

    /// The body of a loop or a way back starts over: answers to history,
    /// records fresh, conditions undecided, the ways back inside reset.
    private func sendAround(_ body: Set<String>, in state: inout RunState) {
        for member in body {
            if let output = state.nodes[member]?.output {
                state.history[member, default: []].append(output)
            }
            var fresh = (state.nodes[member] ?? NodeRecord()).reset()
            fresh.extraInstructions = nil
            state.nodes[member] = fresh
            state.branches[member] = nil
        }
    }

    public func fail(_ id: String, error: String, in state: inout RunState, at date: Date = Date()) {
        var record = state.nodes[id] ?? NodeRecord()
        record.status = .failed
        record.error = error
        record.finishedAt = date
        state.nodes[id] = record
        propagate(&state)
    }

    /// A condition decides its branch from what the run knows.
    public func resolveCondition(_ id: String, in state: inout RunState,
                                 context: JSONValue) {
        guard case .condition(let config)? = workflow.node(id)?.kind else { return }
        let holds = ConditionEvaluator.holds(config.condition, in: context)
        state.branches[id] = holds ? .yes : .no
        complete(id, output: .object(["result": .bool(holds)]), text: holds ? "yes" : "no", in: &state)
    }

    /// A loop either lets the run through (its condition holds, or the
    /// passes are spent) or sends its body around again: their answers move
    /// to `history`, they wait once more, and the loop waits with them.
    /// Returns whether it looped.
    @discardableResult
    public func resolveLoop(_ id: String, in state: inout RunState, context: JSONValue) -> Bool {
        guard case .loop(let config)? = workflow.node(id)?.kind else { return false }
        let done = state.iterations[id] ?? 0
        let stop = config.stopWhen.map { ConditionEvaluator.holds($0, in: context) } ?? false
        let limit = min(max(config.maxIterations, 0), LoopConfig.maxAllowed)
        guard !stop, done < limit, let body = loopBodies[id], !body.isEmpty else {
            complete(id, output: .object(["passes": .number(Double(done + 1)), "stoppedEarly": .bool(stop)]),
                     text: "\(done + 1) pass(es)", in: &state)
            return false
        }
        state.iterations[id] = done + 1
        // A new pass starts from its prompt: earlier instructions were for an
        // answer that is now history. The ways back inside count afresh.
        sendAround(body, in: &state)
        for edge in workflow.retryEdges where body.contains(edge.from) {
            state.iterations[Self.retryKey(edge)] = nil
        }
        state.nodes[id] = NodeRecord()
        return true
    }

    // MARK: The orchestrator's moves (ADR-0018)

    public enum InterventionError: Error, Equatable, CustomStringConvertible {
        case unknownStep(String)
        case notAllowed(String)
        case busy(String)
        case tooManyReruns(String, limit: Int)
        case alreadySettled(String)

        public var description: String {
            switch self {
            case .unknownStep(let id): return "no step \(id) in this workflow"
            case .notAllowed(let id): return "\(id) is run by Loom itself and cannot be rerun or skipped"
            case .busy(let id): return "\(id) is running: wait for its answer"
            case .tooManyReruns(let id, let limit): return "\(id) was already run again \(limit) time(s), the limit"
            case .alreadySettled(let id): return "\(id) already ran: rerun it instead"
            }
        }
    }

    /// Every step downstream of `id` by edges (not `id` itself).
    public func downstream(of id: String) -> Set<String> {
        WorkflowGraph.reachable(from: [id], next: WorkflowGraph.successors(workflow)).subtracting([id])
    }

    /// Runs a step again with the orchestrator's instructions: it waits once
    /// more, and so does everything that read it — their answers move to
    /// `history`, as a loop's do. Only agent and context steps; never while
    /// one of them runs (its answer would land on a step that waits again).
    public func rerun(_ id: String, instructions: String, limit: Int, in state: inout RunState) throws {
        guard let node = workflow.node(id) else { throw InterventionError.unknownStep(id) }
        guard node.kind.type.isSteerable else { throw InterventionError.notAllowed(id) }
        let affected = downstream(of: id).union([id])
        if let busy = affected.first(where: { [.running, .waitingOnUser].contains(state.status($0)) }) {
            throw InterventionError.busy(busy)
        }
        let record = state.nodes[id] ?? NodeRecord()
        guard record.reruns < limit else { throw InterventionError.tooManyReruns(id, limit: limit) }
        for member in affected {
            let current = state.nodes[member] ?? NodeRecord()
            if let output = current.output, current.status == .done {
                state.history[member, default: []].append(output)
            }
            var fresh = current.reset()
            if member != id, workflow.node(member)?.kind.type == .loop {
                // A loop downstream starts its count again with the new answers.
                state.iterations[member] = nil
            }
            for edge in workflow.retryEdges where edge.from == member {
                state.iterations[Self.retryKey(edge)] = nil
            }
            state.branches[member] = nil
            if member == id {
                fresh.reruns = record.reruns + 1
                let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                fresh.extraInstructions = trimmed.isEmpty ? nil : trimmed
            }
            state.nodes[member] = fresh
        }
    }

    /// Skips a step that has not run: it settles done with a "skipped"
    /// answer, so what follows still runs. The start and the report are Loom's.
    public func skip(_ id: String, reason: String, in state: inout RunState, at date: Date = Date()) throws {
        guard let node = workflow.node(id) else { throw InterventionError.unknownStep(id) }
        guard node.kind.type.isSteerable else { throw InterventionError.notAllowed(id) }
        switch state.status(id) {
        case .running, .waitingOnUser: throw InterventionError.busy(id)
        case .done, .failed, .skipped: throw InterventionError.alreadySettled(id)
        case .pending: break
        }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        complete(id, output: .object(["skipped": .bool(true), "reason": .string(text)]),
                 text: "Skipped by the orchestrator" + (text.isEmpty ? "." : ": \(text)"), in: &state, at: date)
    }

    // MARK: End

    /// Over once nothing runs and nothing can start.
    public func isFinished(_ state: RunState) -> Bool {
        let running = state.nodes.values.contains { $0.status == .running || $0.status == .waitingOnUser }
        return !running && ready(state).isEmpty
    }

    public func succeeded(_ state: RunState) -> Bool {
        isFinished(state) && !state.nodes.values.contains { $0.status == .failed }
            && workflow.nodes.allSatisfy { state.status($0.id).isSettled }
    }
}

/// Graph questions the planner and the validator share.
public enum WorkflowGraph {

    /// By the links forward: a way back up is no dependency.
    public static func successors(_ workflow: Workflow) -> [String: [String]] {
        Dictionary(grouping: workflow.forwardEdges, by: \.from).mapValues { $0.map(\.to) }
    }

    public static func predecessors(_ workflow: Workflow) -> [String: [String]] {
        Dictionary(grouping: workflow.forwardEdges, by: \.to).mapValues { $0.map(\.from) }
    }

    /// What a way back up runs again: the steps on a path from its target to
    /// its source, both included — the source alone when it points at itself.
    public static func retryBody(_ edge: WorkflowEdge, in workflow: Workflow) -> Set<String> {
        if edge.from == edge.to { return [edge.from] }
        let forward = reachable(from: [edge.to], next: successors(workflow))
        let backward = reachable(from: [edge.from], next: predecessors(workflow))
        let body = forward.intersection(backward)
        return body.contains(edge.to) ? body : []
    }

    /// Every step reachable from `start`, `start` included.
    public static func reachable(from start: [String], next: [String: [String]],
                                 avoiding: Set<String> = []) -> Set<String> {
        var seen = Set<String>()
        var stack = start.filter { !avoiding.contains($0) }
        while let id = stack.popLast() {
            guard seen.insert(id).inserted else { continue }
            for successor in next[id] ?? [] where !avoiding.contains(successor) {
                stack.append(successor)
            }
        }
        return seen
    }

    /// A loop's body: the steps on a path from one of its targets to it.
    public static func body(of loop: String, targets: [String], in workflow: Workflow) -> Set<String> {
        let forward = reachable(from: targets, next: successors(workflow), avoiding: [loop])
        let backward = reachable(from: [loop], next: predecessors(workflow))
        return forward.intersection(backward).subtracting([loop])
    }

    /// The edges close a cycle — loops go through a loop step, never an edge.
    public static func hasCycle(_ workflow: Workflow) -> Bool {
        let next = successors(workflow)
        var state: [String: Int] = [:]   // 1 visiting, 2 done
        func visit(_ id: String) -> Bool {
            if state[id] == 1 { return true }
            if state[id] == 2 { return false }
            state[id] = 1
            for successor in next[id] ?? [] where visit(successor) { return true }
            state[id] = 2
            return false
        }
        return workflow.nodes.contains { visit($0.id) }
    }
}

/// Tests a `Condition` against the run's context (`steps`, `pr`…).
public enum ConditionEvaluator {
    public static func holds(_ condition: Condition, in context: JSONValue) -> Bool {
        let value = JSONPath.lookup(condition.path, in: context)
        let expected = condition.value.trimmingCharacters(in: .whitespaces)
        switch condition.op {
        case .isTrue: return value?.truthy ?? false
        case .isFalse: return !(value?.truthy ?? false)
        case .isEmpty: return value?.isEmpty ?? true
        case .isNotEmpty: return !(value?.isEmpty ?? true)
        case .equals: return value?.plainText.caseInsensitiveCompare(expected) == .orderedSame
        case .notEquals: return value?.plainText.caseInsensitiveCompare(expected) != .orderedSame
        case .contains:
            switch value {
            case .array(let items)?: return items.contains { $0.plainText.caseInsensitiveCompare(expected) == .orderedSame }
            case let other?: return other.plainText.localizedCaseInsensitiveContains(expected)
            case nil: return false
            }
        case .greaterThan: return (value?.numberValue ?? .nan) > (Double(expected) ?? .nan)
        case .lessThan: return (value?.numberValue ?? .nan) < (Double(expected) ?? .nan)
        }
    }
}
