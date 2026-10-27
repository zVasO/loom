import Testing
import Foundation
import LoomAPI
@testable import LoomWorkflows

// The rules of a run, pure: what starts when, what a condition and a loop
// decide, how a failure stops what depends on it.
@Suite("WorkflowPlanner — dispatch, wait, branch, loop")
struct WorkflowPlannerTests {

    private func agent(_ id: String) -> WorkflowNode {
        WorkflowNode(id: id, title: id, kind: .agent(AgentConfig(prompt: "do \(id)",
                                                                 output: [OutputField("ok", .boolean)])))
    }

    private func start() -> WorkflowNode {
        WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig()))
    }

    private func workflow(_ nodes: [WorkflowNode], _ edges: [(String, String)],
                          branches: [String: Branch] = [:]) -> Workflow {
        Workflow(name: "t", nodes: nodes, edges: edges.map {
            WorkflowEdge(from: $0.0, to: $0.1, branch: branches["\($0.0)->\($0.1)"])
        })
    }

    /// Runs every ready step at once, answering with `answer(id, pass)`,
    /// resolving conditions and loops — the runner's loop without claude.
    private func run(_ workflow: Workflow,
                     answer: (String, Int) -> JSONValue = { _, _ in .object(["ok": .bool(true)]) },
                     failing: Set<String> = []) -> (state: RunState, order: [[String]]) {
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        var order: [[String]] = []
        for _ in 0..<100 {
            let ready = planner.ready(state)
            if ready.isEmpty { break }
            order.append(ready.sorted())
            for id in ready {
                let context = TemplateRenderer.context(inputs: .object([:]), state: state, planner: planner)
                switch workflow.node(id)?.kind.type {
                case .condition?: planner.resolveCondition(id, in: &state, context: context)
                case .loop?: planner.resolveLoop(id, in: &state, context: context)
                default:
                    planner.markRunning(id, in: &state)
                    if failing.contains(id) {
                        planner.fail(id, error: "boom", in: &state)
                    } else {
                        planner.complete(id, output: answer(id, planner.pass(of: id, in: state)),
                                         text: id, in: &state)
                    }
                }
            }
        }
        return (state, order)
    }

    @Test("a line runs step after step")
    func linear() {
        let flow = workflow([start(), agent("a"), agent("b")], [("start", "a"), ("a", "b")])
        let result = run(flow)
        #expect(result.order == [["start"], ["a"], ["b"]])
        #expect(WorkflowPlanner(flow).succeeded(result.state))
    }

    @Test("several links out dispatch in parallel; several in wait for all")
    func fanOutFanIn() {
        let flow = workflow([start(), agent("a"), agent("b"), agent("c"), agent("join")],
                            [("start", "a"), ("start", "b"), ("start", "c"),
                             ("a", "join"), ("b", "join"), ("c", "join")])
        let planner = WorkflowPlanner(flow)
        var state = planner.initialState()
        planner.complete("start", output: nil, text: nil, in: &state)
        #expect(planner.ready(state).sorted() == ["a", "b", "c"])
        planner.complete("a", output: nil, text: nil, in: &state)
        planner.complete("b", output: nil, text: nil, in: &state)
        #expect(!planner.ready(state).contains("join"), "c is still running")
        planner.complete("c", output: nil, text: nil, in: &state)
        #expect(planner.ready(state) == ["join"])
    }

    @Test("a condition takes one branch; the other is skipped")
    func condition() {
        let check = WorkflowNode(id: "check", title: "check",
                                 kind: .condition(ConditionConfig(condition: Condition(path: "steps.a.ok"))))
        let flow = workflow([start(), agent("a"), check, agent("yes"), agent("no"), agent("after")],
                            [("start", "a"), ("a", "check"), ("check", "yes"), ("check", "no"),
                             ("yes", "after"), ("no", "after")],
                            branches: ["check->yes": .yes, "check->no": .no])
        let result = run(flow)
        #expect(result.state.status("yes") == .done)
        #expect(result.state.status("no") == .skipped)
        #expect(result.state.status("after") == .done, "one live input is enough once the others are dead")
        let negative = run(flow) { _, _ in .object(["ok": .bool(false)]) }
        #expect(negative.state.status("yes") == .skipped)
        #expect(negative.state.status("no") == .done)
    }

    private func loopFlow(max: Int, stop: Condition?) -> Workflow {
        let loop = WorkflowNode(id: "loop", title: "loop",
                                kind: .loop(LoopConfig(targets: ["x", "y"], maxIterations: max, stopWhen: stop)))
        return workflow([start(), agent("intent"), agent("x"), agent("y"), agent("check"), loop, agent("report")],
                        [("start", "intent"), ("intent", "x"), ("intent", "y"), ("x", "check"), ("y", "check"),
                         ("check", "loop"), ("loop", "report")])
    }

    @Test("a loop runs its body again, at most maxIterations more times: three passes in all")
    func loopBounded() {
        let flow = loopFlow(max: 2, stop: Condition(path: "steps.check.stable"))
        #expect(WorkflowPlanner(flow).loopBodies["loop"] == ["x", "y", "check"])
        var passes: [String: [Int]] = [:]
        let result = run(flow) { id, pass in
            passes[id, default: []].append(pass)
            return .object(["ok": .bool(true), "stable": .bool(false), "pass": .number(Double(pass))])
        }
        #expect(passes["x"] == [1, 2, 3])
        #expect(passes["check"] == [1, 2, 3])
        #expect(passes["intent"] == [1], "what is before the targets runs once")
        #expect(result.state.status("report") == .done)
        #expect(result.state.iterations["loop"] == 2)
        #expect(result.state.history["check"]?.count == 2, "the two earlier passes are kept")
        #expect(result.state.history["check"]?.first?["pass"] == .number(1))
    }

    @Test("a loop stops early when its condition holds")
    func loopStopsEarly() {
        let flow = loopFlow(max: 2, stop: Condition(path: "steps.check.stable"))
        let result = run(flow) { id, pass in
            .object(["ok": .bool(true), "stable": .bool(id == "check" && pass == 2)])
        }
        #expect(result.state.iterations["loop"] == 1, "stable on the second pass")
        #expect(result.state.status("report") == .done)
    }

    @Test("a loop with no extra pass lets the run through")
    func loopZero() {
        let result = run(loopFlow(max: 0, stop: nil))
        #expect(result.state.iterations["loop"] == nil)
        #expect(result.state.status("report") == .done)
    }

    @Test("a failed step blocks what depends on it, and the run ends failed")
    func failure() {
        let flow = workflow([start(), agent("a"), agent("b"), agent("c"), agent("after")],
                            [("start", "a"), ("start", "b"), ("a", "after"), ("b", "c")])
        let result = run(flow, failing: ["a"])
        #expect(result.state.status("after") == .skipped)
        #expect(result.state.nodes["after"]?.error?.contains("a failed") == true)
        #expect(result.state.status("c") == .done, "an independent branch goes on")
        let planner = WorkflowPlanner(flow)
        #expect(planner.isFinished(result.state))
        #expect(!planner.succeeded(result.state))
    }

    @Test("the built-in PR review: contexts in parallel, four experts, three passes when never stable")
    func builtInRuns() {
        let flow = BuiltInWorkflows.prReview()
        var expertPasses = 0
        let result = run(flow) { id, _ in
            if id == "php" { expertPasses += 1 }
            return .object(["stable": .bool(false)])
        }
        #expect(result.order[1] == ["pr", "repo", "ticket"])
        #expect(result.order[3] == ["php", "security", "symfony", "tests"])
        #expect(expertPasses == 3)
        #expect(result.state.status("report") == .done)
    }
}

@Suite("Templates, conditions, answers")
struct WorkflowTemplateTests {

    private let context: JSONValue = .object([
        "pr": .object(["number": .number(42), "title": .string("Fix cache")]),
        "steps": .object(["intent": .object([
            "intent": .string("Speed up"), "risks": .array([.string("stale"), .string("race")]),
            "score": .number(0.5), "findings": .array([.object(["title": .string("N+1")])]),
        ])]),
    ])

    @Test("paths fill in: numbers plain, text lists as bullets, objects as JSON; unknown paths reported")
    func render() {
        let rendered = TemplateRenderer.render(
            "#{{pr.number}} {{ pr.title }}: {{steps.intent.intent}}\n{{steps.intent.risks}}\n{{steps.intent.findings.0.title}} {{steps.nope.x}}{{steps.intent.score}}",
            context: context)
        #expect(rendered.text == "#42 Fix cache: Speed up\n- stale\n- race\nN+1 0.5")
        #expect(rendered.unknown == ["steps.nope.x"])
        #expect(TemplateRenderer.render("open {{ never closed", context: context).text == "open {{ never closed")
        #expect(TemplateRenderer.paths(in: "{{a.b}} and {{ c }}") == ["a.b", "c"])
    }

    @Test("conditions test what the run knows")
    func conditions() {
        func holds(_ path: String, _ op: ConditionOperator, _ value: String = "") -> Bool {
            ConditionEvaluator.holds(Condition(path: path, op: op, value: value), in: context)
        }
        #expect(holds("steps.intent.risks", .isNotEmpty))
        #expect(holds("steps.intent.risks", .contains, "RACE"))
        #expect(holds("steps.intent.score", .greaterThan, "0.4"))
        #expect(!holds("steps.intent.score", .lessThan, "0.4"))
        #expect(holds("pr.title", .equals, "fix cache"))
        #expect(holds("steps.missing", .isEmpty))
        #expect(!holds("steps.missing", .isTrue))
    }

    @Test("an answer is read leniently and checked against its fields")
    func outputSchema() throws {
        let fields = [OutputField("stable", .boolean), OutputField("findings", .list),
                      OutputField("note", .text, required: false)]
        let instructions = OutputSchema.instructions(for: fields)
        #expect(instructions.contains("\"stable\": true or false"))
        #expect(instructions.contains("(optional)"))
        let ok = try OutputSchema.parse("Here:\n```json\n{\"stable\": true, \"findings\": []}\n```", fields: fields).get()
        #expect(ok["stable"] == .bool(true))
        guard case .failure(.invalid(let problems)) = OutputSchema.parse(#"{"stable": "yes"}"#, fields: fields) else {
            Issue.record("expected invalid")
            return
        }
        #expect(problems.contains("\"stable\" should be boolean."))
        #expect(problems.contains("\"findings\" is missing."))
        #expect(OutputSchema.parse("no json", fields: fields) == .failure(.noObject))
    }

    @Test("JSON from JSONSerialization keeps booleans apart from numbers")
    func fromAny() throws {
        let any = try JSONSerialization.jsonObject(with: Data(#"{"a": true, "b": 1, "c": [null, "x"]}"#.utf8))
        #expect(JSONValue.from(any: any) == .object(["a": .bool(true), "b": .number(1),
                                                     "c": .array([.null, .string("x")])]))
    }
}

@Suite("WorkflowValidator — what keeps a workflow from running")
struct WorkflowValidatorTests {

    @Test("the built-in PR review is valid with its experts and connectors")
    func builtInValid() {
        let issues = WorkflowValidator.validate(BuiltInWorkflows.prReview(), experts: BuiltInWorkflows.experts,
                                                connectors: BuiltInWorkflows.connectors)
        #expect(issues.isEmpty, "\(issues.map(\.message))")
    }

    @Test("each rule reports its step")
    func rules() {
        let loop = WorkflowNode(id: "loop", title: "l", kind: .loop(LoopConfig(targets: ["after"], maxIterations: 9)))
        let workflow = Workflow(name: "bad", nodes: [
            WorkflowNode(id: "a", title: "a", kind: .agent(AgentConfig(prompt: " "))),
            WorkflowNode(id: "b", title: "b", kind: .agent(AgentConfig(expertID: UUID(), prompt: "{{steps.c.x}} {{weird}}"))),
            WorkflowNode(id: "c", title: "c", kind: .context(ContextConfig(source: .jiraTicket))),
            loop,
            WorkflowNode(id: "after", title: "after", kind: .agent(AgentConfig(prompt: "x"))),
        ], edges: [WorkflowEdge(from: "a", to: "b"), WorkflowEdge(from: "b", to: "a"),
                   WorkflowEdge(from: "b", to: "loop"), WorkflowEdge(from: "loop", to: "after"),
                   WorkflowEdge(from: "x", to: "a")])
        let messages = WorkflowValidator.validate(workflow).map(\.message)
        #expect(messages.contains("Add a Start step: it is where a run begins."))
        #expect(messages.contains("The links make a circle: go around with a Loop step instead."))
        #expect(messages.contains("A link points to a step that no longer exists."))
        #expect(messages.contains("Write what this step asks."))
        #expect(messages.contains("Its expert was deleted."))
        #expect(messages.contains("Pick the Atlassian connector the ticket is read through."))
        #expect(messages.contains("A loop runs again 0 to 5 times."))
        #expect(messages.contains("after is not before the loop: it cannot run again."))
        #expect(messages.contains("{{steps.c.x}}: c does not run before this step."))
        #expect(messages.contains("{{weird}} is not a known variable."))
        #expect(WorkflowValidator.hasErrors(WorkflowValidator.validate(workflow)))
    }

    @Test("the estimate counts each pass of each agent")
    func estimate() {
        let estimate = CostEstimate.estimate(BuiltInWorkflows.prReview(), experts: BuiltInWorkflows.experts,
                                             defaultModel: "sonnet")
        // intent 1 + ticket reader 1 + (4 experts + coherence) × 3 passes
        #expect(estimate.runs == 17)
        #expect((estimate.lowUSD ?? 0) > 0)
        #expect((estimate.highUSD ?? 0) > (estimate.lowUSD ?? 0))
        let unpriced = CostEstimate.estimate(BuiltInWorkflows.prReview(), experts: [], defaultModel: "mystery-model")
        #expect(unpriced.lowUSD == nil, "never a silent zero")
    }
}

@Suite("Workflow library — files, bundles, connectors")
struct WorkflowLibraryTests {

    @Test("workflows, experts and connectors survive the disk; a broken file is skipped")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowLibraryStore(directory: directory)
        #expect(!store.exists)
        let workflow = BuiltInWorkflows.prReview()
        try store.save(workflow)
        for expert in BuiltInWorkflows.experts { try store.save(expert) }
        for connector in BuiltInWorkflows.connectors { try store.save(connector) }
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("workflows/zzz.json"))
        #expect(store.exists)
        let loaded = store.loadWorkflows()
        #expect(loaded.count == 1)
        #expect(loaded.first?.nodes == workflow.nodes)
        #expect(loaded.first?.edges == workflow.edges)
        #expect(store.loadExperts().count == BuiltInWorkflows.experts.count)
        #expect(Set(store.loadConnectors().map(\.id)) == Set(BuiltInWorkflows.connectors.map(\.id)))
        store.deleteWorkflow(workflow.id)
        #expect(store.loadWorkflows().isEmpty)
    }

    @Test("a hand-written workflow decodes with defaults")
    func lenientDecode() throws {
        let json = #"{"name": "Mini", "nodes": [{"id": "s", "type": "start"}, {"id": "a", "type": "agent", "config": {"prompt": "hi"}}], "edges": [{"from": "s", "to": "a"}]}"#
        let workflow = try WorkflowJSON.decoder.decode(Workflow.self, from: Data(json.utf8))
        #expect(workflow.name == "Mini")
        #expect(workflow.triggers == [.manual, .pullRequest])
        guard case .agent(let config) = workflow.node("a")?.kind else {
            Issue.record("agent expected")
            return
        }
        #expect(config.mode == .headless)
        #expect(config.timeoutSeconds == 900)
        #expect(workflow.edges.first?.id == "s->a")
    }

    @Test("a bundle carries exactly the experts and connectors its steps use")
    func bundle() throws {
        let workflow = BuiltInWorkflows.prReview()
        let extra = Expert(name: "Unused")
        let bundle = WorkflowBundle.make(workflow, experts: BuiltInWorkflows.experts + [extra],
                                         connectors: BuiltInWorkflows.connectors)
        #expect(bundle.experts.count == BuiltInWorkflows.experts.count)
        #expect(bundle.connectors.map(\.id) == [Connector.atlassianRemoteID])
        let decoded = try WorkflowBundle.decode(bundle.encoded())
        #expect(decoded.workflow.nodes == bundle.workflow.nodes)
        #expect(decoded.workflow.edges == bundle.workflow.edges)
        #expect(decoded.experts == bundle.experts)
        #expect(decoded.connectors == bundle.connectors)
        let bare = try WorkflowBundle.decode(WorkflowJSON.encoder.encode(workflow))
        #expect(bare.workflow.id == workflow.id && bare.experts.isEmpty)
    }

    @Test("connectors become --mcp-config with their secrets, strict unless one is the user's own")
    func wiring() throws {
        let stdio = Connector.atlassianStdio()
        let wired = ConnectorWiring.wire([stdio]) { _, key in key == "JIRA_API_TOKEN" ? "t0k" : "v-\(key)" }
        let json = try #require(wired.mcpConfig)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let server = try #require(servers["atlassian"] as? [String: Any])
        #expect(server["command"] as? String == "/bin/zsh")
        #expect((server["env"] as? [String: String])?["JIRA_API_TOKEN"] == "t0k")
        #expect(wired.strict)
        #expect(wired.toolPatterns == ["mcp__atlassian__*"])
        #expect(wired.missingSecrets.isEmpty)

        let missing = ConnectorWiring.wire([stdio]) { _, _ in nil }
        #expect(missing.missingSecrets.count == 3)

        let remote = ConnectorWiring.wire([Connector.atlassianRemote()]) { _, _ in nil }
        #expect(remote.mcpConfig == nil)
        #expect(!remote.strict, "the user's own servers must stay visible")
        #expect(remote.toolPatterns == ["mcp__atlassian__*"])

        let http = Connector(name: "My Docs!", kind: .mcpHTTP(url: "https://x/{{secret:T}}", headers: ["A": "B {{secret:T}}"]))
        let both = ConnectorWiring.wire([http, Connector.atlassianRemote()]) { _, _ in "s" }
        #expect(both.mcpConfig?.contains("\"my-docs\"") == true)
        #expect(both.mcpConfig?.contains("https://x/s") == true)
        #expect(!both.strict)
        #expect(SecretReference.keys(in: "a {{secret:X}} b {{secret: Y }}") == ["X", "Y"])
    }
}
