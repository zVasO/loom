import Testing
import Foundation
import LoomAPI
@testable import LoomWorkflows

// Blocks of the palette, rules, verdicts and the links that follow them
// (ADR-0019), pure: what a placed step runs, which link the run takes, how
// far a way back up sends it.
@Suite("Blocks, rules, verdicts, conditional links")
struct BlocksTests {

    private let review = WorkflowBlock(
        name: "Revue PHP", template: AgentConfig(prompt: "Review {{in.text}}", output: [OutputField("findings", .list)],
                                                 model: "sonnet", verdict: VerdictConfig(options: ["ok", "à revoir"])),
        rules: ["Cite path:line."])

    private func start() -> WorkflowNode { WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig())) }
    private func agent(_ id: String, _ config: AgentConfig = AgentConfig(prompt: "do")) -> WorkflowNode {
        WorkflowNode(id: id, title: id.uppercased(), kind: .agent(config))
    }

    private func complete(_ id: String, verdict: String? = nil, _ planner: WorkflowPlanner, _ state: inout RunState) {
        planner.markRunning(id, in: &state)
        var object: [String: JSONValue] = ["answer": .string(id)]
        if let verdict { object["verdict"] = .string(verdict); object["verdictReason"] = .string("because") }
        planner.complete(id, output: .object(object), text: id, in: &state)
    }

    @Test("a placed step runs its block, with this use's own instructions, rules and overrides")
    func resolution() {
        var placed = AgentConfig(prompt: "Focus on the controllers.", model: "opus", blockID: review.id,
                                 rules: ["Only src/Controller."])
        placed.output = [OutputField("ignored", .text)]
        let effective = BlockResolver.effective(placed, blocks: [review])
        #expect(effective.prompt == "Review {{in.text}}\n\n## For this step\nFocus on the controllers.")
        #expect(effective.output == review.template.output, "the block's fields, not the placed step's")
        #expect(effective.model == "opus")
        #expect(effective.verdict?.cleanOptions == ["ok", "à revoir"])
        #expect(effective.answerFields.map(\.name) == ["findings", "verdict", "verdictReason"])
        #expect(effective.rules == ["Only src/Controller."])
        var edited = review
        edited.template.prompt = "Review again"
        #expect(BlockResolver.effective(placed, blocks: [edited]).prompt.hasPrefix("Review again"),
                "linked: an edited block reaches every step placed from it")
        let orphan = BlockResolver.effective(placed, blocks: [])
        #expect(orphan.prompt == "Focus on the controllers.", "a deleted block: the step runs as written")
        let block = WorkflowBlock.from(placed, name: "Mine")
        #expect(block.rules == ["Only src/Controller."] && block.template.blockID == nil && block.template.rules.isEmpty)
    }

    @Test("rules are grouped by where they come from: block, this step, rule sets, the links taken")
    func rules() {
        let style = RuleSet(name: "Style", rules: ["Write in French.", " "])
        var block = review
        block.ruleSetIDs = [style.id]
        let placed = agent("php", AgentConfig(prompt: "", blockID: block.id, rules: ["Only src/."], ruleSetIDs: [style.id]))
        let workflow = Workflow(name: "w", nodes: [start(), agent("intent"), placed], edges: [
            WorkflowEdge(from: "start", to: "intent"),
            WorkflowEdge(from: "intent", to: "php", rules: ["Take the intentions as given."]),
        ])
        let groups = RuleComposer.groups(for: placed, in: workflow, blocks: [block], ruleSets: [style])
        #expect(groups.map(\.source) == ["the block «Revue PHP»", "the rule set «Style»", "this step",
                                        "the link from `intent`"], "a rule set ticked twice counts once")
        #expect(groups[1].rules == ["Write in French."])
        let text = RuleComposer.instructions(groups)
        #expect(text.hasPrefix("## Rules for this step"))
        #expect(text.contains("- Cite path:line.") && text.contains("- Take the intentions as given."))
        #expect(RuleComposer.instructions([]).isEmpty)

        // In a run, only the links taken count.
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        #expect(!RuleComposer.groups(for: placed, in: workflow, blocks: [block], ruleSets: [style], state: state)
            .contains { $0.source.contains("link") })
        complete("start", planner, &state)
        complete("intent", planner, &state)
        #expect(RuleComposer.groups(for: placed, in: workflow, blocks: [block], ruleSets: [style], state: state)
            .contains { $0.source == "the link from `intent`" })
    }

    @Test("a verdict outside its options does not fit; the schema names them")
    func verdictOptions() {
        let fields = VerdictConfig(options: ["ok", "à revoir", "ok "]).fields
        #expect(fields[0].options == ["ok", "à revoir"])
        #expect(OutputSchema.instructions(for: fields).contains(#"one of "ok", "à revoir""#))
        #expect((try? OutputSchema.parse(#"{"verdict":"A revoir","verdictReason":"x"}"#, fields: fields).get()) != nil,
                "case and accents aside")
        guard case .failure(let error) = OutputSchema.parse(#"{"verdict":"maybe","verdictReason":"x"}"#, fields: fields)
        else { Issue.record("maybe is no option"); return }
        #expect(error.description.contains("must be one of: ok, à revoir"))
        #expect(VerdictConfig.worst(["ok", "À revoir", "ok"], options: ["ok", "à revoir", "bloquant"]) == "à revoir")
        #expect(VerdictConfig.worst([], options: ["ok"]) == nil)
    }

    /// start → review → (ok) report, (otherwise) fix
    private var routed: Workflow {
        Workflow(name: "w", nodes: [start(), agent("review"), agent("report"), agent("fix")], edges: [
            WorkflowEdge(from: "start", to: "review"),
            WorkflowEdge(from: "review", to: "report", when: "ok"),
            WorkflowEdge(from: "review", to: "fix", otherwise: true),
        ])
    }

    @Test("a link follows its source's verdict; otherwise takes what no other link does")
    func conditionalLinks() {
        let planner = WorkflowPlanner(routed)
        var state = planner.initialState()
        complete("start", planner, &state)
        complete("review", verdict: "OK", planner, &state)
        #expect(planner.ready(state) == ["report"])
        #expect(state.status("fix") == .skipped)

        state = planner.initialState()
        complete("start", planner, &state)
        complete("review", verdict: "à revoir", planner, &state)
        #expect(planner.ready(state) == ["fix"])
        #expect(state.status("report") == .skipped)

        state = planner.initialState()
        complete("start", planner, &state)
        complete("review", planner, &state)
        #expect(planner.ready(state) == ["fix"], "no verdict at all: only otherwise holds")
    }

    /// start → review ↺ (à revoir, ×2) ; review → (ok) report, (otherwise) human
    private func retrying(to target: String = "review") -> Workflow {
        Workflow(name: "w", nodes: [start(), agent("prep"), agent("review"), agent("report"), agent("human")], edges: [
            WorkflowEdge(from: "start", to: "prep"),
            WorkflowEdge(from: "prep", to: "review"),
            WorkflowEdge(from: "review", to: "report", when: "ok"),
            WorkflowEdge(from: "review", to: "human", otherwise: true),
            WorkflowEdge(from: "review", to: target, when: "à revoir", retry: RetryConfig(max: 2), rules: ["Be precise."]),
        ])
    }

    @Test("a way back up runs its body again, keeps the answers, then gives up to the links forward")
    func retries() {
        let workflow = retrying(to: "prep")
        #expect(!WorkflowGraph.hasCycle(workflow), "a way back is no circle")
        let planner = WorkflowPlanner(workflow)
        let key = WorkflowPlanner.retryKey(workflow.retryEdges[0])
        #expect(planner.loopBodies[key] == ["prep", "review"])
        var state = planner.initialState()
        complete("start", planner, &state)
        #expect(planner.ready(state) == ["prep"], "the way back is no input of prep")
        complete("prep", planner, &state)
        complete("review", verdict: "à revoir", planner, &state)
        #expect(state.iterations[key] == 1)
        #expect(state.status("prep") == .pending && state.status("review") == .pending)
        #expect(state.status("report") == .pending && state.status("human") == .pending, "nothing after it moved")
        #expect(state.history["review"]?.count == 1 && state.history["prep"]?.count == 1)
        #expect(planner.pass(of: "review", in: state) == 2)
        #expect(planner.ready(state) == ["prep"])
        let rules = RuleComposer.groups(for: workflow.node("prep")!, in: workflow, blocks: [], ruleSets: [], state: state)
        #expect(rules.contains { $0.source == "the way back from `review`" && $0.rules == ["Be precise."] })
        #expect(RuleComposer.retryNotes(for: "prep", in: workflow, state: state).contains("«à revoir»: because"))

        complete("prep", planner, &state)
        complete("review", verdict: "à revoir", planner, &state)
        #expect(state.iterations[key] == 2)
        complete("prep", planner, &state)
        complete("review", verdict: "à revoir", planner, &state)
        #expect(state.iterations[key] == 2, "spent")
        #expect(state.status("review") == .done)
        #expect(planner.ready(state) == ["human"], "spent, the step follows its links forward")
        #expect(state.status("report") == .skipped)
    }

    @Test("a step may send itself around; a good verdict goes on at once")
    func selfRetry() {
        let workflow = retrying()
        let planner = WorkflowPlanner(workflow)
        #expect(planner.loopBodies[WorkflowPlanner.retryKey(workflow.retryEdges[0])] == ["review"])
        var state = planner.initialState()
        complete("start", planner, &state)
        complete("prep", planner, &state)
        complete("review", verdict: "à revoir", planner, &state)
        #expect(planner.ready(state) == ["review"])
        #expect(state.status("prep") == .done)
        complete("review", verdict: "ok", planner, &state)
        #expect(planner.ready(state) == ["report"])
    }

    @Test("the validator: verdicts links can follow, ways back, commands, for-each, deleted blocks")
    func validation() {
        func messages(_ workflow: Workflow, blocks: [WorkflowBlock] = []) -> [String] {
            WorkflowValidator.validate(workflow, blocks: blocks).map(\.message)
        }
        #expect(messages(routed).contains { $0.contains("waits for a verdict review never gives") })
        var withVerdict = routed
        withVerdict.nodes[1] = agent("review", AgentConfig(prompt: "x", verdict: VerdictConfig(options: ["ok", "ko"])))
        #expect(!messages(withVerdict).contains { $0.contains("verdict") })
        withVerdict.edges[1].when = "maybe"
        #expect(messages(withVerdict).contains { $0.contains("«maybe» is not one of review's verdicts (ok, ko)") })

        var noCover = retrying()
        noCover.nodes[2] = agent("review", AgentConfig(prompt: "x", verdict: VerdictConfig(options: ["ok", "à revoir"])))
        noCover.edges.removeAll { $0.otherwise }
        #expect(messages(noCover).contains { $0.contains("nothing follows") })
        var down = retrying()
        down.nodes[2] = noCover.nodes[2]
        down.edges[4] = WorkflowEdge(from: "review", to: "report", when: "à revoir", retry: RetryConfig())
        #expect(messages(down).contains { $0.contains("report is not before review") })

        let command = Workflow(name: "w", nodes: [start(), WorkflowNode(id: "t", title: "T",
                               kind: .command(CommandConfig(command: "phpunit --filter {{pr.title}}")))],
                               edges: [WorkflowEdge(from: "start", to: "t")])
        #expect(messages(command).contains { $0.hasPrefix("No {{…}} in a command") })

        let visible = Workflow(name: "w", nodes: [start(), WorkflowNode(id: "each", title: "E", kind: .forEach(
            ForEachConfig(items: "steps.start.files", agent: AgentConfig(prompt: "x {{item}}", mode: .visible))))],
                               edges: [WorkflowEdge(from: "start", to: "each")])
        #expect(messages(visible).contains { $0.contains("headless") })
        #expect(!messages(visible).contains { $0.contains("{{item}}") }, "item is known")

        let deleted = Workflow(name: "w", nodes: [start(), agent("b", AgentConfig(blockID: UUID()))],
                               edges: [WorkflowEdge(from: "start", to: "b")])
        #expect(messages(deleted).contains("Its block was deleted."))
        let placed = Workflow(name: "w", nodes: [start(), agent("b", AgentConfig(blockID: review.id))],
                              edges: [WorkflowEdge(from: "start", to: "b")])
        #expect(!messages(placed, blocks: [review]).contains { $0.contains("Write what this step asks") },
                "the block's prompt counts")
    }

    @Test("the estimate counts each item and each round back")
    func estimate() {
        let each = Workflow(name: "w", nodes: [start(), WorkflowNode(id: "each", title: "E", kind: .forEach(
            ForEachConfig(items: "steps.start.files", agent: AgentConfig(prompt: "x"), maxItems: 4)))],
                            edges: [WorkflowEdge(from: "start", to: "each")])
        #expect(CostEstimate.estimate(each, experts: [], defaultModel: "sonnet").runs == 4)
        let back = retrying()
        // prep, review ×3, report, human
        #expect(CostEstimate.estimate(back, experts: [], defaultModel: "sonnet").runs == 6)
    }

    @Test("old files decode; new keys round-trip; a bundle carries its blocks and rule sets")
    func files() throws {
        let edge = try JSONDecoder().decode(WorkflowEdge.self, from: Data(#"{"from":"a","to":"b","when":" "}"#.utf8))
        #expect(edge.when == nil && !edge.otherwise && edge.retry == nil && edge.rules.isEmpty)
        let config = try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"prompt":"x"}"#.utf8))
        #expect(config.blockID == nil && config.rules.isEmpty && config.verdict == nil)
        let node = try JSONDecoder().decode(WorkflowNode.self, from: Data(#"{"id":"t","type":"command"}"#.utf8))
        #expect(node.kind == .command(CommandConfig()))

        let style = RuleSet(name: "Style", rules: ["French."])
        let unused = RuleSet(name: "Unused")
        var block = review
        block.ruleSetIDs = [style.id]
        // ISO 8601 on disk: whole seconds survive the trip.
        block.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let workflow = Workflow(name: "w", nodes: [start(), agent("b", AgentConfig(blockID: block.id))],
                                edges: [WorkflowEdge(from: "start", to: "b")])
        let bundle = WorkflowBundle.make(workflow, experts: [], connectors: [], blocks: [block, WorkflowBlock(name: "X")],
                                         ruleSets: [style, unused])
        #expect(bundle.blocks == [block] && bundle.ruleSets == [style])
        let decoded = try WorkflowBundle.decode(bundle.encoded())
        #expect(decoded.blocks == [block] && decoded.ruleSets == [style])
        var object = try JSONSerialization.jsonObject(with: bundle.encoded()) as! [String: Any]
        object["blocks"] = nil
        object["ruleSets"] = nil
        let old = try WorkflowBundle.decode(JSONSerialization.data(withJSONObject: object))
        #expect(old.blocks.isEmpty && old.ruleSets.isEmpty)
    }
}
