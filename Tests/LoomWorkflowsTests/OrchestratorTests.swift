import Testing
import Foundation
import LoomAPI
@testable import LoomWorkflows

// The orchestrator's moves on a run (ADR-0018), pure: a rerun sends a step
// and what read it around again, a skip lets the run through, both bounded.
@Suite("Orchestrator — reruns, skips, its words")
struct OrchestratorTests {

    private func agent(_ id: String) -> WorkflowNode {
        WorkflowNode(id: id, title: id.uppercased(), kind: .agent(AgentConfig(prompt: "do \(id)")))
    }

    /// start → a → (b, c) → d → report
    private var flow: Workflow {
        let nodes = [WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig())),
                     agent("a"), agent("b"), agent("c"), agent("d"),
                     WorkflowNode(id: "report", title: "Report", kind: .artifact(ArtifactConfig()))]
        let edges = [("start", "a"), ("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"), ("d", "report")]
        return Workflow(name: "t", nodes: nodes, edges: edges.map { WorkflowEdge(from: $0.0, to: $0.1) },
                        orchestrator: OrchestratorConfig())
    }

    /// Everything done but the report, every step answering its id.
    private func finished(_ planner: WorkflowPlanner) -> RunState {
        var state = planner.initialState()
        for id in ["start", "a", "b", "c", "d"] {
            planner.markRunning(id, in: &state)
            planner.complete(id, output: .object(["answer": .string(id)]), text: id, in: &state)
        }
        return state
    }

    @Test("a rerun sends the step and everything after it around again, answers kept in history")
    func rerun() throws {
        let planner = WorkflowPlanner(flow)
        var state = finished(planner)
        #expect(planner.ready(state) == ["report"])
        try planner.rerun("b", instructions: "  Look at the SQL.  ", limit: 2, in: &state)
        #expect(state.status("a") == .done, "what came before stays")
        #expect(state.status("c") == .done, "a sibling stays")
        for id in ["b", "d", "report"] { #expect(state.status(id) == .pending, "\(id) waits again") }
        #expect(state.nodes["b"]?.reruns == 1)
        #expect(state.nodes["b"]?.extraInstructions == "Look at the SQL.")
        #expect(state.nodes["d"]?.extraInstructions == nil)
        #expect(state.history["b"] == [.object(["answer": .string("b")])])
        #expect(state.history["d"] == [.object(["answer": .string("d")])])
        #expect(planner.ready(state) == ["b"], "only the rerun step can start")
        planner.markRunning("b", in: &state)
        #expect(state.nodes["b"]?.extraInstructions == "Look at the SQL.", "kept for its prompt")
        #expect(state.nodes["b"]?.reruns == 1)
    }

    @Test("a rerun is refused while it or a step after it runs, past its limit, and on Loom's own steps")
    func rerunRefusals() throws {
        let planner = WorkflowPlanner(flow)
        var state = finished(planner)
        planner.markRunning("report", in: &state)
        #expect(throws: WorkflowPlanner.InterventionError.busy("report")) {
            try planner.rerun("d", instructions: "x", limit: 2, in: &state)
        }
        state = finished(planner)
        try planner.rerun("c", instructions: "x", limit: 1, in: &state)
        for id in ["c", "d"] {
            planner.markRunning(id, in: &state)
            planner.complete(id, output: .object([:]), text: id, in: &state)
        }
        #expect(throws: WorkflowPlanner.InterventionError.tooManyReruns("c", limit: 1)) {
            try planner.rerun("c", instructions: "again", limit: 1, in: &state)
        }
        #expect(throws: WorkflowPlanner.InterventionError.notAllowed("report")) {
            try planner.rerun("report", instructions: "x", limit: 2, in: &state)
        }
        #expect(throws: WorkflowPlanner.InterventionError.unknownStep("zz")) {
            try planner.rerun("zz", instructions: "x", limit: 2, in: &state)
        }
    }

    @Test("a failed step rerun unblocks what it had blocked")
    func rerunAfterFailure() throws {
        let planner = WorkflowPlanner(flow)
        var state = planner.initialState()
        for id in ["start", "a"] {
            planner.markRunning(id, in: &state)
            planner.complete(id, output: .object([:]), text: id, in: &state)
        }
        planner.markRunning("b", in: &state)
        planner.fail("b", error: "boom", in: &state)
        planner.markRunning("c", in: &state)
        planner.complete("c", output: .object([:]), text: "c", in: &state)
        #expect(state.status("d") == .skipped, "blocked by b")
        #expect(planner.isFinished(state))
        try planner.rerun("b", instructions: "retry", limit: 2, in: &state)
        #expect(state.status("d") == .pending)
        #expect(state.status("report") == .pending)
        #expect(planner.ready(state) == ["b"])
        #expect(!planner.isFinished(state))
    }

    @Test("a skip settles a pending step done, so the run goes on; never one that ran")
    func skip() throws {
        let planner = WorkflowPlanner(flow)
        var state = planner.initialState()
        for id in ["start", "a"] {
            planner.markRunning(id, in: &state)
            planner.complete(id, output: .object([:]), text: id, in: &state)
        }
        try planner.skip("b", reason: "Not a PHP change.", in: &state)
        #expect(state.status("b") == .done)
        #expect(state.nodes["b"]?.output?["skipped"] == .bool(true))
        #expect(state.nodes["b"]?.text == "Skipped by the orchestrator: Not a PHP change.")
        planner.markRunning("c", in: &state)
        planner.complete("c", output: .object([:]), text: "c", in: &state)
        #expect(planner.ready(state) == ["d"], "what waited on the skipped step runs")
        #expect(throws: WorkflowPlanner.InterventionError.alreadySettled("c")) {
            try planner.skip("c", reason: "", in: &state)
        }
        planner.markRunning("d", in: &state)
        #expect(throws: WorkflowPlanner.InterventionError.busy("d")) { try planner.skip("d", reason: "", in: &state) }
        #expect(throws: WorkflowPlanner.InterventionError.notAllowed("start")) {
            try planner.skip("start", reason: "", in: &state)
        }
    }

    @Test("a loop's new pass forgets the orchestrator's instructions, not its reruns")
    func loopPass() throws {
        let nodes = [WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig())), agent("a"),
                     WorkflowNode(id: "loop", title: "Loop", kind: .loop(LoopConfig(targets: ["a"], maxIterations: 1)))]
        let flow = Workflow(name: "t", nodes: nodes,
                            edges: [WorkflowEdge(from: "start", to: "a"), WorkflowEdge(from: "a", to: "loop")])
        let planner = WorkflowPlanner(flow)
        var state = planner.initialState()
        for id in ["start", "a"] {
            planner.markRunning(id, in: &state)
            planner.complete(id, output: .object([:]), text: id, in: &state)
        }
        try planner.rerun("a", instructions: "deeper", limit: 2, in: &state)
        planner.markRunning("a", in: &state)
        planner.complete("a", output: .object([:]), text: "a", in: &state)
        #expect(planner.resolveLoop("loop", in: &state, context: .object([:])))
        #expect(state.nodes["a"]?.extraInstructions == nil)
        #expect(state.nodes["a"]?.reruns == 1)
    }

    @Test("an orchestrator decodes with its defaults; a workflow without one has none")
    func decoding() throws {
        let config = try JSONDecoder().decode(OrchestratorConfig.self, from: Data(#"{"instructions":"x"}"#.utf8))
        #expect(config == OrchestratorConfig(instructions: "x"))
        #expect(config.maxInterventions == 12 && config.maxRerunsPerStep == 2 && config.reviewBeforeArtifact)
        #expect(OrchestratorConfig(maxInterventions: 500, maxRerunsPerStep: -3).interventionLimit == 50)
        #expect(OrchestratorConfig(maxInterventions: 500, maxRerunsPerStep: -3).rerunLimit == 0)
        let bare = try WorkflowJSON.decoder.decode(Workflow.self, from: Data(#"{"name":"w"}"#.utf8))
        #expect(bare.orchestrator == nil)
        let data = try WorkflowJSON.encoder.encode(flow)
        #expect(try WorkflowJSON.decoder.decode(Workflow.self, from: data).orchestrator == OrchestratorConfig())
    }

    @Test("a run saved before the orchestrator still reads, its new keys empty")
    func oldRun() throws {
        let run = WorkflowRun(workflow: flow, experts: [], connectors: [], inputs: RunInputs(),
                              state: WorkflowPlanner(flow).initialState())
        var object = try JSONSerialization.jsonObject(with: WorkflowJSON.encoder.encode(run)) as! [String: Any]
        for key in ["orchestratorSessionID", "interventions", "messages", "workingDirectory", "stepSessions"] {
            object[key] = nil
        }
        var nodes = (object["state"] as! [String: Any])["nodes"] as! [String: [String: Any]]
        nodes["a"]?["reruns"] = nil
        var stateObject = object["state"] as! [String: Any]
        stateObject["nodes"] = nodes
        object["state"] = stateObject
        let decoded = try WorkflowJSON.decoder.decode(WorkflowRun.self,
                                                      from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.interventions == 0 && decoded.messages.isEmpty && decoded.stepSessions.isEmpty)
        #expect(decoded.state.nodes["a"]?.reruns == 0)
        #expect(decoded.interventionsLeft == 12)
    }

    @Test("a session is found as the step it ran, every pass included, in the workflow's order")
    func stepSessions() {
        var run = WorkflowRun(workflow: flow, experts: [], connectors: [], inputs: RunInputs(prNumber: 4),
                              state: WorkflowPlanner(flow).initialState())
        run.state.nodes["c"]?.sessionID = "BBBB"
        run.stepSessions = ["aaaa": "c", "cccc": "a"]
        #expect(run.step(ofSession: "bbbb") == "c")
        #expect(run.step(ofSession: "AAAA") == "c")
        #expect(run.step(ofSession: "dddd") == nil)
        #expect(run.stepSessionIDs == ["cccc", "aaaa", "bbbb"])
    }

    @Test("the brief lists the steps and the budget; events read as one message")
    func words() {
        let brief = OrchestratorPrompt.brief(workflow: flow, experts: [], subject: "PR #4", note: "careful",
                                             instructions: "Watch b.", budget: 12, rerunsPerStep: 2,
                                             reviewBeforeArtifact: true)
        #expect(brief.contains("`b` — B [agent, headless] → `d`"))
        #expect(brief.contains("Budget: 12 intervention(s)"))
        #expect(brief.contains("loom_workflow_proceed"))
        #expect(brief.contains("Watch b."))
        #expect(brief.contains("careful"))
        let message = OrchestratorPrompt.message(for: [
            .stepDone(id: "b", title: "B", pass: 2, summary: "ok\nfine"),
            .stepFailed(id: "c", title: "C", error: "boom"),
            .checkpoint(reason: .beforeReport),
        ])
        let lines = message.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("`b` (B) is done — pass 2. ok fine"))
        #expect(lines[1].contains("failed: boom"))
        #expect(OrchestratorPrompt.rules.contains("loom_workflow_step_rerun"))
        #expect(OrchestratorPrompt.rerunAddendum("Be precise.", previous: "old").contains("old"))
    }
}
