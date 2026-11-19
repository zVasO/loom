import Testing
import Foundation
import LoomAPI
@testable import LoomWorkflows

// Workflows that deliver (ADR-0021), pure: the templates Loom offers, a
// run's own worktree and task, and a step that carries on a conversation.
@Suite("Templates, the run's workspace, continued conversations")
struct TemplatesTests {

    /// Runs every ready step at once — the runner's loop without claude.
    /// `answer(id, pass)` is what a step answers; the conversation each
    /// agent step would run in is recorded as the runner does.
    private func run(_ workflow: Workflow, answer: (String, Int) -> JSONValue)
        -> (state: RunState, order: [String], picked: [String: [String?]]) {
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        var order: [String] = []
        var picked: [String: [String?]] = [:]
        for _ in 0..<100 {
            let ready = planner.ready(state)
            if ready.isEmpty { break }
            for id in ready {
                order.append(id)
                let pass = planner.pass(of: id, in: state)
                planner.markRunning(id, in: &state)
                if case .agent(let config)? = workflow.node(id)?.kind {
                    let before = planner.conversation(for: id, in: state)
                    picked[id, default: []].append(config.mode == .visible ? before?.sessionID : before?.claudeSessionID)
                    // A continued conversation stays the same one; a new step starts its own.
                    let own = "\(id)#\(pass)"
                    let conversation = config.mode == .visible
                        ? StepConversation(sessionID: before?.sessionID ?? own)
                        : StepConversation(claudeSessionID: before?.claudeSessionID ?? own)
                    planner.remember(conversation, of: id, in: &state)
                }
                planner.complete(id, output: answer(id, pass), text: id, in: &state)
            }
        }
        return (state, order, picked)
    }

    private func verdict(_ value: String, comment: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["verdict": .string(value), "verdictReason": .string("because")]
        if let comment { object = ["verdict": .string(value), "comment": .string(comment)] }
        return .object(object)
    }

    // MARK: - The templates

    @Test("every template is a workflow that may run as it is: no error, no warning")
    func templatesValidate() {
        #expect(WorkflowTemplates.all.count >= 4)
        #expect(Set(WorkflowTemplates.all.map(\.id)).count == WorkflowTemplates.all.count, "ids are unique")
        for template in WorkflowTemplates.all {
            let bundle = template.bundle()
            let issues = WorkflowValidator.validate(bundle.workflow, experts: bundle.experts,
                                                    connectors: bundle.connectors, blocks: bundle.blocks,
                                                    ruleSets: bundle.ruleSets)
            #expect(issues.isEmpty, "\(template.id): \(issues.map(\.message))")
            #expect(bundle.workflow.name == template.name)
            #expect(!template.tagline.isEmpty && !template.highlights.isEmpty)
            #expect(WorkflowTemplates.template(template.id)?.name == template.name)
            // Exactly the experts its steps name.
            let needed = WorkflowBundle.make(bundle.workflow, experts: bundle.experts, connectors: [])
            #expect(Set(needed.experts.map(\.id)) == Set(bundle.experts.map(\.id)), "\(template.id) ships what it uses")
            // The file a person exports and imports back is the same workflow.
            let decoded = try? WorkflowBundle.decode(bundle.encoded())
            #expect(decoded?.workflow.nodes == bundle.workflow.nodes)
            #expect(decoded?.workflow.workspace == bundle.workflow.workspace)
        }
    }

    @Test("a template used twice gives two workflows and the same experts")
    func templateIdentity() {
        let first = WorkflowTemplates.shipTask.bundle()
        let second = WorkflowTemplates.shipTask.bundle()
        #expect(first.workflow.id != second.workflow.id)
        #expect(first.experts.map(\.id) == second.experts.map(\.id))
        #expect(WorkflowTemplates.fixChecks.bundle().experts.map(\.id).contains(WorkflowTemplates.developer.id),
                "two templates share the developer: a library keeps one")
    }

    @Test("who may write: the developer, and nobody who only reads")
    func templateTools() {
        #expect(Expert.canWrite(WorkflowTemplates.developer.allowedTools))
        for expert in [WorkflowTemplates.reviewer, WorkflowTemplates.investigator, WorkflowTemplates.analyst,
                       WorkflowTemplates.security, WorkflowTemplates.tests, WorkflowTemplates.lead] {
            #expect(!Expert.canWrite(expert.allowedTools), "\(expert.name) reads only")
        }
        #expect(!Expert.canWrite(Expert.readOnlyTools))
        // Templates that write work on a branch of their own; those that read do not.
        for template in WorkflowTemplates.all {
            let bundle = template.bundle()
            let writers = bundle.workflow.nodes.contains { node in
                guard case .agent(let config) = node.kind,
                      let expert = bundle.experts.first(where: { $0.id == config.expertID }) else { return false }
                return Expert.canWrite(expert.allowedTools)
            }
            #expect(writers == (bundle.workflow.workspace == .worktree), "\(template.id)")
        }
    }

    @Test("the task templates ask for a task; the PR review asks for a pull request")
    func whatATemplateAsksFor() {
        #expect(WorkflowTemplates.shipTask.preview.asksForTask)
        #expect(WorkflowTemplates.fixChecks.preview.asksForTask)
        #expect(WorkflowTemplates.investigate.preview.asksForTask)
        let review = WorkflowTemplates.reviewPullRequest.preview
        #expect(!review.asksForTask)
        #expect(review.readsPullRequest)
        #expect(review.triggers.contains(.pullRequest) && review.triggers.contains(.schedule))
        #expect(!WorkflowTemplates.shipTask.preview.readsPullRequest)
    }

    // MARK: - Réaliser une tâche, as a run

    @Test("ship a task: plan, your go, implementation, review, report — one developer conversation throughout")
    func shipTaskStraight() {
        let workflow = WorkflowTemplates.shipTask.preview
        let result = run(workflow) { id, _ in
            switch id {
            case "go": verdict("go", comment: "ok pour moi")
            case "review": verdict("ok")
            default: .object(["summary": .string(id)])
            }
        }
        #expect(result.order == ["start", "plan", "go", "implement", "review", "report"])
        #expect(WorkflowPlanner(workflow).succeeded(result.state))
        // The plan starts a conversation; the implementation carries it on; the reviewer has its own.
        #expect(result.picked["plan"]! == [nil])
        #expect(result.picked["implement"]! == ["plan#1"])
        #expect(result.picked["review"]! == [nil])
    }

    @Test("ship a task: «à revoir» at the gate revises the plan in the same conversation, with your comment")
    func shipTaskPlanRevised() {
        let workflow = WorkflowTemplates.shipTask.preview
        var asked = 0
        let result = run(workflow) { id, _ in
            switch id {
            case "go":
                asked += 1
                return verdict(asked == 1 ? "à revoir" : "go", comment: "sans toucher à l'API publique")
            case "review": return verdict("ok")
            default: return .object(["summary": .string(id)])
            }
        }
        #expect(result.order == ["start", "plan", "go", "plan", "go", "implement", "review", "report"])
        #expect(result.picked["plan"]! == [nil, "plan#1"], "the second plan knows the first")
        #expect(result.picked["implement"]! == ["plan#1"])
        // What the plan sent back learns: the person's own words.
        var state = WorkflowPlanner(workflow).initialState()
        state.iterations[WorkflowPlanner.retryKey(workflow.retryEdges.first { $0.from == "go" }!)] = 1
        state.history["go"] = [verdict("à revoir", comment: "sans toucher à l'API publique")]
        let notes = RuleComposer.retryNotes(for: "plan", in: workflow, state: state)
        #expect(notes.contains("«à revoir»: sans toucher à l'API publique"))
    }

    @Test("ship a task: the review sends the work back, twice at most, then the report is written anyway")
    func shipTaskReviewSendsBack() {
        let workflow = WorkflowTemplates.shipTask.preview
        let result = run(workflow) { id, _ in
            switch id {
            case "go": verdict("go")
            case "review": verdict("à revoir")
            default: .object(["summary": .string(id)])
            }
        }
        #expect(result.order.filter { $0 == "implement" }.count == 3, "the first pass and two more")
        #expect(result.order.filter { $0 == "review" }.count == 3)
        #expect(result.order.last == "report", "spent, the run follows the link forward")
        #expect(WorkflowPlanner(workflow).succeeded(result.state))
        #expect(result.picked["implement"]! == ["plan#1", "plan#1", "plan#1"], "the same developer all along")
        #expect(result.picked["review"]! == [nil, nil, nil], "a fresh reviewer each round")
        #expect(result.state.history["review"]?.count == 2, "what {{previous.review}} reads")
    }

    @Test("ship a task: «arrêter» writes nothing — the run ends on the report of the plan")
    func shipTaskStopped() {
        let workflow = WorkflowTemplates.shipTask.preview
        let result = run(workflow) { id, _ in
            id == "go" ? verdict("arrêter") : .object(["summary": .string(id)])
        }
        #expect(result.order == ["start", "plan", "go", "report"])
        #expect(result.state.status("implement") == .skipped)
        #expect(result.state.status("review") == .skipped)
        #expect(WorkflowPlanner(workflow).succeeded(result.state))
    }

    @Test("fix until green: red goes around in the same conversation, green is reviewed")
    func fixChecksRounds() {
        let workflow = WorkflowTemplates.fixChecks.preview
        var rounds = 0
        let result = run(workflow) { id, _ in
            switch id {
            case "fix":
                rounds += 1
                return verdict(rounds < 3 ? "encore rouge" : "vert")
            case "review": return verdict("ok")
            default: return .object([:])
            }
        }
        #expect(result.order == ["start", "fix", "fix", "fix", "review", "report"])
        #expect(result.picked["fix"]! == [nil, "fix#1", "fix#1"])
        // Still red when its rounds are spent: no review, the report says so.
        let red = run(workflow) { id, _ in id == "fix" ? verdict("encore rouge") : .object([:]) }
        #expect(red.order == ["start", "fix", "fix", "fix", "report"])
        #expect(red.state.status("review") == .skipped)
    }

    @Test("investigate: a second opinion that is not convinced reopens the inquiry once")
    func investigateChallenged() {
        let workflow = WorkflowTemplates.investigate.preview
        let result = run(workflow) { id, _ in
            id == "challenge" ? verdict("à creuser") : .object(["cause": .string("x")])
        }
        #expect(result.order == ["start", "repo", "inquiry", "challenge", "inquiry", "challenge", "report"])
        #expect(result.picked["inquiry"]! == [nil, "inquiry#1"], "headless: claude's own conversation is resumed")
        #expect(workflow.workspace == .project, "it reads, it does not write")
    }

    // MARK: - Conversations

    private func agent(_ id: String, mode: AgentMode = .headless, continues: String? = nil) -> WorkflowNode {
        WorkflowNode(id: id, title: id, kind: .agent(AgentConfig(prompt: "do \(id)", output: [OutputField("a", .text)],
                                                                 mode: mode, continues: continues)))
    }

    private var startNode: WorkflowNode { WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig())) }

    private func line(_ nodes: [WorkflowNode], extra: [WorkflowEdge] = []) -> Workflow {
        var all = [startNode] + nodes
        all.append(WorkflowNode(id: "report", title: "Report", kind: .artifact(ArtifactConfig())))
        let edges = zip(all, all.dropFirst()).map { WorkflowEdge(from: $0.id, to: $1.id) }
        return Workflow(name: "t", nodes: all, edges: edges + extra)
    }

    @Test("a step that continues nothing starts a new conversation, whatever ran before")
    func freshByDefault() {
        let workflow = line([agent("a"), agent("b")])
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        planner.remember(StepConversation(claudeSessionID: "conv-a"), of: "a", in: &state)
        planner.remember(StepConversation(claudeSessionID: "conv-b"), of: "b", in: &state)
        #expect(planner.conversation(for: "b", in: state) == nil)
        #expect(planner.conversation(for: "a", in: state) == nil)
    }

    @Test("a chain of steps shares one conversation; its own earlier pass comes first")
    func chain() {
        let workflow = line([agent("a"), agent("b", continues: "a"), agent("c", continues: "b")])
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        #expect(planner.conversation(for: "b", in: state) == nil, "nothing ran yet")
        planner.remember(StepConversation(claudeSessionID: "one"), of: "a", in: &state)
        #expect(planner.conversation(for: "b", in: state)?.claudeSessionID == "one")
        #expect(planner.conversation(for: "c", in: state)?.claudeSessionID == "one", "through b, which did not run yet")
        planner.remember(StepConversation(claudeSessionID: "two"), of: "c", in: &state)
        #expect(planner.conversation(for: "c", in: state)?.claudeSessionID == "two")
        planner.remember(StepConversation(), of: "b", in: &state)
        #expect(state.conversations["b"] == nil, "an empty conversation is not one")
    }

    @Test("conversations survive a new pass: the record starts afresh, the conversation does not")
    func survivesAPass() {
        let workflow = line([agent("a", continues: "a")])
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        planner.markRunning("a", in: &state)
        state.nodes["a"]?.claudeSessionID = "conv"
        planner.remember(StepConversation(claudeSessionID: "conv"), of: "a", in: &state)
        planner.markRunning("a", in: &state)
        #expect(state.nodes["a"]?.claudeSessionID == nil)
        #expect(planner.conversation(for: "a", in: state)?.claudeSessionID == "conv")
    }

    @Test("the validator: what a step continues must exist, be an agent of the same mode, and run before it")
    func continuesIsChecked() {
        func errors(_ workflow: Workflow) -> [String] {
            WorkflowValidator.validate(workflow).filter { $0.severity == .error }.map(\.message)
        }
        #expect(errors(line([agent("a"), agent("b", continues: "a")])).isEmpty)
        #expect(errors(line([agent("a", continues: "a")])).isEmpty, "its own conversation, pass after pass")
        #expect(errors(line([agent("a"), agent("b", continues: "ghost")])).contains { $0.contains("no longer exists") })
        #expect(errors(line([agent("a"), agent("b", continues: "report")])).contains { $0.contains("not an agent step") })
        #expect(errors(line([agent("a", mode: .visible), agent("b", continues: "a")])).contains { $0.contains("same mode") })
        #expect(errors(line([agent("a", continues: "b"), agent("b")])).contains { $0.contains("does not run before") })
        // Two steps in one conversation side by side.
        let fork = Workflow(name: "t", nodes: [startNode, agent("a"), agent("b", continues: "a"), agent("c", continues: "a")],
                            edges: [WorkflowEdge(from: "start", to: "a"), WorkflowEdge(from: "a", to: "b"),
                                    WorkflowEdge(from: "a", to: "c")])
        #expect(errors(fork).contains { $0.contains("side by side") })
        // An agent run for each item has no conversation to carry on.
        let each = line([agent("a"), WorkflowNode(id: "each", title: "Each", kind: .forEach(ForEachConfig(
            items: "steps.a.a", agent: AgentConfig(prompt: "x", output: [OutputField("s", .text)], continues: "a"))))])
        #expect(errors(each).contains { $0.contains("per item") })
    }

    @Test("a placed block follows its block, but whose conversation it continues is the step's own")
    func continuesOnABlock() {
        let block = WorkflowBlock(name: "B", template: AgentConfig(prompt: "p", output: [OutputField("s", .text)]))
        let placed = AgentConfig(blockID: block.id, continues: "plan")
        #expect(BlockResolver.effective(placed, blocks: [block]).continues == "plan")
        #expect(AgentConfig(prompt: "p", continues: "  ").continues == nil, "blank is none")
    }

    // MARK: - The run's workspace and task

    @Test("a workflow works in the project unless it says otherwise; a value from the future reads as the careful one")
    func workspaceDecoding() throws {
        let bare = try WorkflowJSON.decoder.decode(Workflow.self, from: Data(#"{"name": "old"}"#.utf8))
        #expect(bare.workspace == .project)
        let own = try WorkflowJSON.decoder.decode(Workflow.self, from: Data(#"{"name": "w", "workspace": "worktree"}"#.utf8))
        #expect(own.workspace == .worktree)
        let unknown = try WorkflowJSON.decoder.decode(Workflow.self, from: Data(#"{"name": "w", "workspace": "container"}"#.utf8))
        #expect(unknown.workspace == .project)
        let again = try WorkflowJSON.decoder.decode(Workflow.self, from: WorkflowJSON.encoder.encode(own))
        #expect(again.workspace == .worktree)
    }

    @Test("a workflow on its own branch cannot load a pull request: its checkout is read only")
    func worktreeAndPullRequest() {
        var workflow = WorkflowTemplates.reviewPullRequest.preview
        #expect(WorkflowValidator.validate(workflow, experts: WorkflowTemplates.reviewPullRequest.bundle().experts)
            .filter { $0.severity == .error }.isEmpty)
        workflow.workspace = .worktree
        let issues = WorkflowValidator.validate(workflow, experts: WorkflowTemplates.reviewPullRequest.bundle().experts)
        #expect(issues.contains { $0.severity == .error && $0.nodeID == "pr" && $0.message.contains("own branch") })
    }

    @Test("a run is called by its task: the first line, short; its branch by a slug of it")
    func taskNames() {
        var inputs = RunInputs(task: "  Ajouter l'export CSV à la page Factures !\nAvec les mêmes filtres.")
        #expect(inputs.taskHeadline == "Ajouter l'export CSV à la page Factures !")
        #expect(inputs.taskSlug == "ajouter-l-export-csv-a-la-page-factures")
        inputs.task = String(repeating: "très long ", count: 20)
        #expect(inputs.taskHeadline?.count == 72)
        #expect(inputs.taskHeadline?.hasSuffix("…") == true)
        #expect(inputs.taskSlug.count <= 40 && !inputs.taskSlug.hasSuffix("-"))
        #expect(RunInputs().taskHeadline == nil)
        #expect(RunInputs(task: " \n ").taskSlug.isEmpty)

        let workflow = WorkflowTemplates.shipTask.preview
        let state = WorkflowPlanner(workflow).initialState()
        func subject(_ inputs: RunInputs) -> String {
            WorkflowRun(workflow: workflow, experts: [], connectors: [], inputs: inputs, state: state).subject
        }
        #expect(subject(RunInputs(task: "Corriger le cache")) == "Corriger le cache")
        #expect(subject(RunInputs(prNumber: 42, task: "x")) == "PR #42", "a PR names the run first")
        #expect(subject(RunInputs()) == "Manual run")
    }

    @Test("a run saved before worktrees, tasks and conversations still reads")
    func oldRunsDecode() throws {
        let workflow = WorkflowTemplates.investigate.preview
        var run = WorkflowRun(workflow: workflow, experts: [], connectors: [], inputs: RunInputs(task: "t"),
                              state: WorkflowPlanner(workflow).initialState(),
                              worktree: RunWorktree(path: "/tmp/w", branch: "loom/x", baseRevision: "abc"),
                              changes: RunChanges(files: 2, additions: 10, deletions: 1, paths: ["a", "b"], commits: 1))
        run.state.conversations["inquiry"] = StepConversation(claudeSessionID: "c")
        let data = try WorkflowJSON.encoder.encode(run)
        let back = try WorkflowJSON.decoder.decode(WorkflowRun.self, from: data)
        #expect(back.worktree == run.worktree && back.changes == run.changes)
        #expect(back.state.conversations == run.state.conversations)
        #expect(back.inputs.task == "t")
        // Strip what older versions never wrote.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["worktree"] = nil
        object["changes"] = nil
        var state = try #require(object["state"] as? [String: Any])
        state["conversations"] = nil
        object["state"] = state
        var inputs = try #require(object["inputs"] as? [String: Any])
        inputs["task"] = nil
        object["inputs"] = inputs
        let old = try WorkflowJSON.decoder.decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.worktree == nil && old.changes == nil)
        #expect(old.state.conversations.isEmpty && old.inputs.task.isEmpty)
        #expect(old.state.nodes.count == run.state.nodes.count)
    }

    @Test("what a run changed: tracked lines from numstat, untracked files counted once, binaries without lines")
    func changes() {
        let numstat = "12\t3\tSources/App/Invoice.swift\n-\t-\tAssets/logo.png\n0\t7\told name.txt\n"
        let changes = RunChanges.parse(numstat: numstat, untracked: ["Tests/InvoiceTests.swift", "Assets/logo.png"],
                                       commits: 2)
        #expect(changes.files == 4)
        #expect(changes.additions == 12 && changes.deletions == 10)
        #expect(changes.paths == ["Sources/App/Invoice.swift", "Assets/logo.png", "old name.txt", "Tests/InvoiceTests.swift"])
        #expect(changes.summary == "4 files · +12 −10 · 2 commits")
        #expect(RunChanges.parse(numstat: "").isEmpty)
        #expect(RunChanges.parse(numstat: "").summary == "no change")
        #expect(RunChanges.parse(numstat: "1\t0\ta").summary == "1 file · +1 −0")
        let many = (0..<100).map { "1\t1\tf\($0)" }.joined(separator: "\n")
        let big = RunChanges.parse(numstat: many)
        #expect(big.files == 100 && big.paths.count == RunChanges.maxPaths)
    }

    // MARK: - The outline

    @Test("a workflow reads as a line: steps in the order a run reaches them, side by side joined")
    func outline() {
        let ship = WorkflowTemplates.shipTask.bundle()
        let outline = WorkflowOutline(ship.workflow, experts: ship.experts)
        #expect(outline.oneLine == "Plan → Ton accord → Implémentation → Relecture → Rapport")
        let implement = outline.steps.first { $0.id == "implement" }
        #expect(implement?.expert == "Développeur")
        #expect(implement?.visible == true)
        #expect(implement?.continues == "plan")
        let review = outline.steps.first { $0.id == "review" }
        #expect(review?.visible == false)
        #expect(review?.verdicts == ["ok", "à revoir"])
        #expect(review?.retries == ["↺ à revoir → Implémentation ≤2×"])
        let pr = WorkflowTemplates.reviewPullRequest.bundle()
        #expect(WorkflowOutline(pr.workflow, experts: pr.experts).oneLine
                == "La PR + Le dépôt → Intentions → Exactitude + Sécurité + Tests → Synthèse → Rapport")
    }
}
