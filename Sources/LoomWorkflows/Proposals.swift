import Foundation
import LoomAPI
import LoomCore

/// What an agent's proposal changes, in lines the person reads before
/// validating (ADR-0020). Pure. What could run code, or widen what an agent
/// may do, is flagged: a command, a command allowed on pull requests, an
/// expert's tools.
public enum ProposalDiff {

    public struct Change: Equatable, Sendable {
        public var text: String
        /// Read twice before validating.
        public var flagged: Bool

        public init(_ text: String, flagged: Bool = false) {
            self.text = text
            self.flagged = flagged
        }
    }

    public static func workflow(_ new: Workflow, previous old: Workflow?) -> [Change] {
        var changes: [Change] = []
        guard let old else {
            changes.append(Change("New workflow «\(new.name)»: \(new.nodes.count) step(s), \(new.edges.count) link(s)."))
            changes += new.nodes.compactMap { commandChange($0, before: nil) }
            if new.orchestrator != nil { changes.append(Change("With an orchestrator.")) }
            return changes
        }
        if old.name != new.name { changes.append(Change("Renamed «\(old.name)» → «\(new.name)».")) }
        if old.summary != new.summary { changes.append(Change("Summary changed.")) }
        let before = Dictionary(old.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for node in new.nodes where before[node.id] == nil {
            changes.append(Change("Step added: `\(node.id)` (\(node.kind.type.rawValue), «\(node.title)»)."))
        }
        for node in old.nodes where after[node.id] == nil {
            changes.append(Change("Step removed: `\(node.id)`."))
        }
        for node in new.nodes {
            guard let previous = before[node.id], previous.kind != node.kind || previous.title != node.title
            else { continue }
            changes.append(Change("Step changed: `\(node.id)`."))
        }
        for node in new.nodes {
            if let change = commandChange(node, before: before[node.id]) { changes.append(change) }
        }
        let oldEdges = Set(old.edges.map(edgeKey))
        let newEdges = Set(new.edges.map(edgeKey))
        let added = newEdges.subtracting(oldEdges).count
        let removed = oldEdges.subtracting(newEdges).count
        if added + removed > 0 { changes.append(Change("Links: \(added) added or changed, \(removed) removed.")) }
        if old.orchestrator != new.orchestrator {
            changes.append(Change(new.orchestrator == nil ? "Orchestrator removed." : "Orchestrator set or changed."))
        }
        return changes.isEmpty ? [Change("Positions or layout only.")] : changes
    }

    /// A command step's line is the one thing that runs code: always shown.
    private static func commandChange(_ node: WorkflowNode, before: WorkflowNode?) -> Change? {
        guard case .command(let config) = node.kind else { return nil }
        if case .command(let old)? = before?.kind, old == config { return nil }
        let line = config.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Change("Command `\(node.id)`: \(line.prefix(120))"
                      + (config.allowOnPullRequests ? " — runs on pull requests (their code)" : ""), flagged: true)
    }

    private static func edgeKey(_ edge: WorkflowEdge) -> String {
        [edge.from, edge.to, edge.branch?.rawValue ?? "", edge.when ?? "", edge.otherwise ? "else" : "",
         edge.retry.map { "\($0.max)" } ?? "", edge.rules.joined(separator: "|"),
         edge.ruleSetIDs.map(\.uuidString).joined(separator: ",")].joined(separator: "·")
    }

    public static func block(_ new: WorkflowBlock, previous old: WorkflowBlock?) -> [Change] {
        guard let old else {
            return [Change("New block «\(new.name)», \(new.rules.count) rule(s): every step placed from it will run it.")]
        }
        var changes: [Change] = []
        if old.template.prompt != new.template.prompt { changes.append(Change("Its prompt changed.")) }
        if old.template.output != new.template.output || old.template.verdict != new.template.verdict {
            changes.append(Change("Its answer fields or verdict changed."))
        }
        if old.rules != new.rules || old.ruleSetIDs != new.ruleSetIDs { changes.append(Change("Its rules changed.")) }
        if old.template.expertID != new.template.expertID || old.template.model != new.template.model {
            changes.append(Change("Its expert or model changed."))
        }
        if old.template.mode != new.template.mode, new.template.mode == .visible {
            changes.append(Change("It now runs in a visible session."))
        }
        if old.name != new.name { changes.append(Change("Renamed «\(old.name)» → «\(new.name)».")) }
        return changes.isEmpty ? [Change("Cosmetic changes.")] : changes
            + [Change("Every step placed from it follows once validated.")]
    }

    public static func expert(_ new: Expert, previous old: Expert?) -> [Change] {
        var changes: [Change] = old == nil ? [Change("New expert «\(new.name)».")] : []
        if let old, old.systemPrompt != new.systemPrompt { changes.append(Change("Its instructions changed.")) }
        if let old, old.model != new.model { changes.append(Change("Its model changed.")) }
        let before = Set(old?.allowedTools ?? Expert.readOnlyTools)
        let added = new.allowedTools.filter { !before.contains($0) }
        if !added.isEmpty {
            changes.append(Change("Tools it may use without asking: + " + added.joined(separator: ", "), flagged: true))
        }
        if let old, old.connectorIDs != new.connectorIDs { changes.append(Change("Its connectors changed.", flagged: true)) }
        return changes.isEmpty ? [Change("Cosmetic changes.")] : changes
    }

    public static func ruleSet(_ new: RuleSet, previous old: RuleSet?) -> [Change] {
        guard let old else { return [Change("New rule set «\(new.name)», \(new.rules.count) rule(s).")] }
        let added = new.rules.filter { !old.rules.contains($0) }.count
        let removed = old.rules.filter { !new.rules.contains($0) }.count
        return [Change("Rules: \(added) added, \(removed) removed — every step ticking it follows.")]
    }
}

/// What the agents API tells an agent about the format (ADR-0020) — built
/// from the model's own defaults, so it never drifts from what Loom reads.
public enum WorkflowReference {

    /// A step of each type, with its configuration as Loom writes it by default.
    public static func defaultNode(_ type: NodeType) -> WorkflowNode {
        let kind: NodeKind
        switch type {
        case .start: kind = .start(StartConfig())
        case .context: kind = .context(ContextConfig())
        case .agent: kind = .agent(AgentConfig(prompt: "…", output: [OutputField("summary", .text)],
                                               verdict: VerdictConfig()))
        case .condition: kind = .condition(ConditionConfig(condition: Condition(path: "steps.review.verdict",
                                                                                 op: .equals, value: "ok")))
        case .loop: kind = .loop(LoopConfig(targets: ["review"]))
        case .artifact: kind = .artifact(ArtifactConfig())
        case .approval: kind = .approval(ApprovalConfig(question: "Merge {{pr.title}}?"))
        case .forEach: kind = .forEach(ForEachConfig(items: "steps.repo.touched"))
        case .command: kind = .command(CommandConfig(command: "vendor/bin/phpunit"))
        }
        return WorkflowNode(id: type.rawValue, title: type.rawValue.capitalized, kind: kind)
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static let roles: [NodeType: String] = [
        .start: "Where a run begins. `triggers`: manual, pullRequest, jiraTicket, schedule. Exactly one.",
        .context: "Loads without an LLM: `source` pullRequest (body, files, conversation, checks; the PR's worktree), "
            + "jiraTicket (through an Atlassian connector in `connectorIDs`), repository (tree, README, touched files).",
        .agent: "One claude run for an expert. `prompt` is a template; `output` the JSON fields it answers; "
            + "`verdict.options` (best first) lets links follow it; `mode` headless or visible; `blockID` places a "
            + "block (then `prompt` and `rules` are this use's own, on top of the block's).",
        .condition: "Takes its `yes` or `no` links (edges with `branch`) from a test on a path.",
        .loop: "Runs the steps between its `targets` and itself again, `maxIterations` more times (0–5), "
            + "earlier when `stopWhen` holds. Prefer a link that retries (below).",
        .artifact: "Writes the HTML report in a Loom theme; `importToPRTab` fills the PR's tab.",
        .approval: "The person decides: `question`, `options` (each a verdict its links follow).",
        .forEach: "Runs `agent` (inline or a `blockID`) once per item of the list at `items`, headless, "
            + "`maxItems` ≤ 30. `{{item}}`, `{{index}}` in its prompt.",
        .command: "A shell line in the run's folder; exit code → verdict pass / fail. NEVER `{{…}}` in it: read "
            + "$LOOM_PR_NUMBER, $LOOM_PR_BASE, $LOOM_PR_HEAD, $LOOM_PR_HEAD_SHA, $LOOM_REPO_PATH, $LOOM_RUN_FOLDER. "
            + "On a pull request it runs the PR's code: `allowOnPullRequests` must be true, and only the person "
            + "should decide that.",
    ]

    public static func markdown() -> String {
        var lines = [
            "# Loom workflows — the format",
            "",
            "A workflow is a graph: `nodes` (id, title, type, position {x, y}, config) and `edges` (from, to). "
            + "Several links out of a step run in parallel; several in wait for all. Node ids are short slugs "
            + "templates name (`php`, `review`). Positions: about 260 px apart left to right.",
            "",
            "Everything you save is a PROPOSAL: it does not run and is not scheduled until the person validates it "
            + "in Loom (Workflows › To review). Say so when you are done, and what to check.",
            "",
            "## Steps",
        ]
        for type in NodeType.allCases {
            lines.append("")
            lines.append("### `\(type.rawValue)`")
            lines.append(roles[type] ?? "")
            lines.append("```json")
            lines.append(json(defaultNode(type)))
            lines.append("```")
        }
        lines += [
            "",
            "## Links",
            "- `{\"from\": \"a\", \"to\": \"b\"}`: b waits for a.",
            "- Out of a condition: `\"branch\": \"yes\"` or `\"no\"`.",
            "- Out of a step with a verdict: `\"when\": \"ok\"` (taken on that verdict) or `\"otherwise\": true` "
                + "(taken when no other link forward matches).",
            "- A way back up: `{\"from\": \"review\", \"to\": \"review\", \"when\": \"à revoir\", \"retry\": {\"max\": 2}}` — "
                + "the steps from `to` to `from` run again on that verdict, at most `max` (≤ 5) times; then `from` "
                + "follows its links forward. Add an `otherwise` link so something always follows.",
            "- `rules` (strings) and `ruleSetIDs` on a link: rules for the step it leads to, when taken.",
            "",
            "## Templates in prompts",
            "`{{in.text}}`, `{{in.<field>}}` (the steps right before), `{{steps.<id>.<field>}}`, `{{steps.<id>.text}}`, "
                + "`{{steps.<id>.verdict}}`, `{{previous.<id>}}` (its last pass), `{{pr.number|title|url|author|base|head|body}}`, "
                + "`{{ticket.key}}`, `{{repo.name|path}}`, `{{run.note}}`, `{{iteration}}`, `{{item}}`, `{{index}}`.",
            "",
            "## Rules, blocks, experts",
            "- Rules: `rules` (strings) on an agent step, a block, a link; `ruleSetIDs` ticks named rule sets.",
            "- A block (`loom_library_block_save`): `{name, summary, color, template: <agent config>, rules, ruleSetIDs}`. "
                + "Steps placed from it (`config.blockID`) follow it.",
            "- An expert (`loom_library_expert_save`): `{name, domain, systemPrompt, model, skills, connectorIDs, allowedTools}`. "
                + "Keep `allowedTools` read-only unless the person asked otherwise: headless steps cannot ask permission.",
            "- Connectors are read only: name the ones `loom_library_get` lists.",
            "",
            "## Scheduled reviews",
            "`loom_library_schedule_save`: `{name, enabled, hour, minute, weekdays (1 = Sunday … 7 = Saturday), "
                + "targets: [{projectID, query (GitHub search, e.g. `review:none draft:false`), limit ≤ 20}], workflowID?}`. "
                + "Without `workflowID` each PR gets Loom's built-in review.",
            "",
            "## An example",
            "```json",
            json(example),
            "```",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Start → PR → a review that retries on «à revoir», otherwise asks the person → report.
    public static var example: Workflow {
        Workflow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000E1E1")!, name: "PHP review with a retry",
                 summary: "Reads the PR, reviews it, goes back once when it is not convinced.", nodes: [
                    WorkflowNode(id: "start", title: "Start", position: Position(x: 0, y: 100), kind: .start(StartConfig())),
                    WorkflowNode(id: "pr", title: "The PR", position: Position(x: 260, y: 100),
                                 kind: .context(ContextConfig(source: .pullRequest))),
                    WorkflowNode(id: "review", title: "PHP review", position: Position(x: 520, y: 100),
                                 kind: .agent(AgentConfig(
                                    prompt: "Review this pull request's PHP.\n\n{{in.text}}",
                                    output: [OutputField("findings", .list, "Objects {path, line, title, detail}")],
                                    rules: ["Cite path:line for every finding."],
                                    verdict: VerdictConfig(options: ["ok", "à revoir"])))),
                    WorkflowNode(id: "human", title: "Your call", position: Position(x: 780, y: 220),
                                 kind: .approval(ApprovalConfig(question: "The review is still not convinced: go on?"))),
                    WorkflowNode(id: "report", title: "Report", position: Position(x: 1040, y: 100),
                                 kind: .artifact(ArtifactConfig())),
                 ], edges: [
                    WorkflowEdge(from: "start", to: "pr"),
                    WorkflowEdge(from: "pr", to: "review"),
                    WorkflowEdge(from: "review", to: "report", when: "ok"),
                    WorkflowEdge(from: "review", to: "human", otherwise: true),
                    WorkflowEdge(from: "review", to: "review", when: "à revoir", retry: RetryConfig(max: 1),
                                 rules: ["Answer what the previous round found lacking."]),
                    WorkflowEdge(from: "human", to: "report", when: "approuver"),
                 ], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
}

/// The Workflow builder (ADR-0020): a Loom session that builds workflows
/// with the person, through the `loom_library_*` tools.
public enum BuilderPrompt {

    public static let instructions = """
    You are Loom's workflow builder. You design Loom workflows WITH the person, through \
    the Loom MCP tools `loom_library_*`:
    1. Call loom_library_reference once: it is the format. Call loom_library_get to see \
    what exists (experts, blocks, rule sets, connectors, projects, schedules).
    2. Ask what the workflow is for, what it reads, who decides, what ends it. A few \
    short questions, then propose a plan in plain words before building.
    3. Reuse what exists: experts, blocks, rule sets. Create a block when a step will be \
    placed more than once; a rule set for rules shared by several steps.
    4. Check with loom_library_validate, fix every error, then save with \
    loom_library_workflow_save (and the block, rule set, expert or schedule tools).
    5. Everything you save is a proposal: it does not run until the person validates it \
    in Loom (Workflows › To review). Tell them what to validate and what to look at — \
    above all any command step.
    Never put {{…}} in a command step; never set allowOnPullRequests or give an expert \
    write tools unless the person asked for it explicitly. Write titles in the person's language.
    """

    public static func opening(improving workflow: Workflow?) -> String {
        guard let workflow else {
            return "I want to create a Loom workflow. Read the reference, look at what exists, then ask me what it is for."
        }
        return "I want to improve the Loom workflow «\(workflow.name)» (id \(workflow.id.uuidString)). "
            + "Read the reference and that workflow with loom_library_workflow_get, then ask me what to change."
    }
}

extension WorkflowBundle {
    /// What a workflow uses that still awaits validation (ADR-0020): a run
    /// never starts on it.
    public var pendingProposals: [String] {
        var names: [String] = []
        if workflow.isProposed { names.append("the workflow «\(workflow.name)»") }
        names += blocks.filter(\.isProposed).map { "the block «\($0.name)»" }
        names += experts.filter(\.isProposed).map { "the expert «\($0.name)»" }
        names += ruleSets.filter(\.isProposed).map { "the rule set «\($0.name)»" }
        return names
    }
}
