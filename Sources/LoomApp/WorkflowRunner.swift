import Foundation
import LoomAgents
import LoomAPI
import LoomCore
import LoomGit
import LoomUI
import LoomWorkflows

/// Runs a workflow (ADR-0017): prepares its inputs (the PR's worktree, the
/// Jira key), then lets the planner decide and executes what it says —
/// context loaders here, agents through `claude -p` or a Loom session, the
/// artifact last. A few steps at a time; every move saved to the run's file.
extension AppModel {

    /// What the steps of one run share, ready before the first step.
    struct PreparedRun: Sendable {
        var inputs: JSONValue
        /// Where the agents run: the PR's review worktree, else the project.
        var workdir: URL
        var pr: GitHubService.PullRequest?
        var projectID: ProjectID?
        /// The worktree checks out someone else's code (ADR-0014).
        var untrusted: Bool
    }

    enum StepOutcome: Sendable {
        case done(output: JSONValue?, text: String, cost: Double?, artifact: String? = nil, session: String? = nil)
        case failed(String)
    }

    // MARK: Start, stop

    /// Why a workflow cannot start with these inputs, or nil.
    func workflowLaunchProblem(_ workflow: Workflow, inputs: RunInputs) -> String? {
        let issues = WorkflowValidator.validate(workflow, experts: workflows.experts,
                                                connectors: workflows.connectors)
        if let error = issues.first(where: { $0.severity == .error }) {
            return "\(workflow.name): \(error.message)"
        }
        if claudePath == nil { return "claude was not found on this Mac." }
        let needsPR = workflow.nodes.contains {
            if case .context(let config) = $0.kind { return config.source == .pullRequest }
            return false
        }
        if inputs.prNumber != nil || needsPR || workflow.nodes.contains(where: {
            if case .context(let config) = $0.kind { return config.source == .repository }
            return false
        }) {
            guard inputs.projectID.flatMap({ project($0) }) != nil else { return "Choose the project the run works in." }
        }
        if needsPR, inputs.prNumber == nil, inputs.trigger != .jiraTicket {
            return "This workflow reads a pull request: give its number."
        }
        return nil
    }

    /// Starts a run; nil when it cannot (the reason is on the banner).
    @discardableResult
    func startWorkflowRun(_ workflowID: UUID, inputs: RunInputs) -> UUID? {
        guard let workflow = workflows.workflow(workflowID) else { return nil }
        if let problem = workflowLaunchProblem(workflow, inputs: inputs) {
            startupError = problem
            return nil
        }
        let planner = WorkflowPlanner(workflow)
        let run = WorkflowRun(workflow: workflow, experts: workflows.experts, connectors: workflows.connectors,
                              inputs: inputs, state: planner.initialState())
        workflows.record(run)
        workflows.selectedRunID = run.id
        workflows.log("Run of \(workflow.name) started (\(inputs.trigger.rawValue)).", run: run.id)
        workflows.runTasks[run.id] = Task { [weak self] in
            await self?.executeWorkflowRun(run.id)
        }
        return run.id
    }

    func stopWorkflowRun(_ id: UUID) {
        workflows.runTasks[id]?.cancel()
    }

    private func updateRun(_ id: UUID, _ change: (inout WorkflowRun) -> Void) {
        guard var run = workflows.run(id) else { return }
        change(&run)
        workflows.record(run)
    }

    // MARK: The loop

    private func executeWorkflowRun(_ runID: UUID) async {
        defer { workflows.runTasks[runID] = nil }
        guard let initial = workflows.run(runID) else { return }
        let planner = WorkflowPlanner(initial.workflow)
        let prepared: PreparedRun
        do {
            prepared = try await prepareWorkflowRun(initial)
        } catch {
            finishRun(runID, status: .failed, error: Self.ghErrorText(error))
            return
        }
        let limit = workflows.maxConcurrent
        await withTaskGroup(of: (String, StepOutcome).self) { group in
            var running = Set<String>()
            while !Task.isCancelled {
                guard var state = workflows.run(runID)?.state else { break }
                // Start, conditions and loops decide at once, on what is known.
                var moved = true
                while moved {
                    moved = false
                    for id in planner.ready(state) where !running.contains(id) {
                        guard let node = planner.workflow.node(id) else { continue }
                        let context = TemplateRenderer.context(inputs: prepared.inputs, state: state,
                                                               planner: planner, for: id)
                        switch node.kind {
                        case .start:
                            planner.complete(id, output: prepared.inputs, text: "Run started", in: &state)
                            moved = true
                        case .condition:
                            planner.resolveCondition(id, in: &state, context: context)
                            workflows.log("\(node.title): \(state.branches[id]?.rawValue ?? "?")", run: runID)
                            moved = true
                        case .loop:
                            if planner.resolveLoop(id, in: &state, context: context) {
                                workflows.log("\(node.title): pass \((state.iterations[id] ?? 0) + 1)", run: runID)
                            }
                            moved = true
                        default:
                            break
                        }
                    }
                }
                for id in planner.ready(state) where !running.contains(id) && running.count < limit {
                    guard let node = planner.workflow.node(id) else { continue }
                    let context = TemplateRenderer.context(inputs: prepared.inputs, state: state,
                                                           planner: planner, for: id)
                    let pass = planner.pass(of: id, in: state)
                    planner.markRunning(id, in: &state)
                    running.insert(id)
                    workflows.log("\(node.title): started (pass \(pass))", run: runID)
                    group.addTask { [weak self] in
                        guard let self else { return (id, .failed("Loom is closing.")) }
                        return (id, await self.performStep(node, pass: pass, context: context, run: runID,
                                                           prepared: prepared))
                    }
                }
                updateRun(runID) { $0.state = state }
                if running.isEmpty { break }
                guard let next = await group.next() else { break }
                let (id, outcome) = next
                running.remove(id)
                updateRun(runID) { run in
                    switch outcome {
                    case .done(let output, let text, let cost, let artifact, let session):
                        planner.complete(id, output: output, text: text, costUSD: cost, in: &run.state)
                        if let session { run.state.nodes[id]?.sessionID = session }
                        run.costUSD += cost ?? 0
                        if let artifact { run.artifactPath = artifact }
                    case .failed(let message):
                        planner.fail(id, error: message, in: &run.state)
                    }
                }
                let title = planner.workflow.node(id)?.title ?? id
                switch outcome {
                case .done: workflows.log("\(title): done", run: runID)
                case .failed(let message): workflows.log("\(title): failed — \(message)", run: runID)
                }
            }
            if Task.isCancelled { group.cancelAll() }
        }
        guard let final = workflows.run(runID) else { return }
        if Task.isCancelled {
            finishRun(runID, status: .cancelled, error: "Stopped.")
        } else if planner.succeeded(final.state) {
            finishRun(runID, status: .succeeded, error: nil)
        } else {
            let failed = final.state.nodes.first { $0.value.status == .failed }
            let title = failed.flatMap { planner.workflow.node($0.key)?.title } ?? "A step"
            finishRun(runID, status: .failed, error: failed.map { "\(title): \($0.value.error ?? "failed")" })
        }
    }

    private func finishRun(_ id: UUID, status: WorkflowRun.Status, error: String?) {
        updateRun(id) { run in
            run.status = status
            run.error = error
            run.finishedAt = Date()
            for (node, record) in run.state.nodes where record.status == .running || record.status == .waitingOnUser {
                run.state.nodes[node]?.status = .failed
                run.state.nodes[node]?.error = status == .cancelled ? "Stopped." : "The run ended."
            }
        }
        workflows.log("Run \(status.rawValue)\(error.map { ": \($0)" } ?? "")", run: id)
        guard let run = workflows.run(id) else { return }
        let body: String
        switch status {
        case .succeeded: body = "\(run.subject) · terminé" + (run.artifactPath != nil ? " — le rapport est prêt" : "")
        case .cancelled: body = "\(run.subject) · arrêté"
        default: body = "\(run.subject) · échec : \(error ?? "")"
        }
        postAutoReviewNotification(title: run.workflow.name, body: body, id: "loom.workflow.\(id)")
    }

    // MARK: Preparation

    private func prepareWorkflowRun(_ run: WorkflowRun) async throws -> PreparedRun {
        let inputs = run.inputs
        let repoURL = projectRepo(inputs.projectID)
        var workdir = repoURL ?? workflows.folder(for: run.id)
        var prObject: [String: JSONValue] = [:]
        var pr: GitHubService.PullRequest?
        var untrusted = false
        var body = ""
        if let number = inputs.prNumber, let repoURL, let projectID = inputs.projectID {
            guard let fetched = try await GitHubService().pullRequest(number, repo: nil, in: repoURL) else {
                throw GitHubService.GitHubError.commandFailed(arguments: [], stderr: "PR #\(number) was not found.")
            }
            pr = fetched
            let checkout = try await GitHubService().syncPRWorktree(number, repo: repoURL,
                                                                    readOnly: reviewWorktreesReadOnly)
            workdir = checkout.path
            untrusted = true
            body = await prDetail(number, in: projectID, refresh: true)?.body ?? ""
            prObject = [
                "number": .number(Double(number)), "title": .string(fetched.title), "url": .string(fetched.url),
                "author": .string(fetched.author), "base": .string(fetched.baseBranch.isEmpty ? "main" : fetched.baseBranch),
                "head": .string(fetched.branch), "body": .string(body),
                "additions": .number(Double(fetched.additions)), "deletions": .number(Double(fetched.deletions)),
                "changedFiles": .number(Double(fetched.changedFiles)),
                "labels": .array(fetched.labels.map { .string($0.name) }),
                "headSHA": .string(fetched.headSHA),
            ]
        }
        try? FileManager.default.createDirectory(at: workflows.folder(for: run.id), withIntermediateDirectories: true)
        let key = (inputs.jiraKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0.uppercased() }
            ?? pr.flatMap { JiraKey.detect(in: [$0.title, $0.branch, body]) }
        if let key, inputs.jiraKey != key {
            updateRun(run.id) { $0.inputs.jiraKey = key }
        }
        let projectName = project(inputs.projectID)?.name ?? ""
        let object: [String: JSONValue] = [
            "pr": .object(prObject),
            "ticket": .object(["key": .string(key ?? "")]),
            "repo": .object(["name": .string(projectName), "path": .string(workdir.path),
                             "github": .string(inputs.projectID.flatMap { repoName(for: $0) } ?? "")]),
            "run": .object(["id": .string(run.id.uuidString), "workflow": .string(run.workflow.name),
                            "note": .string(inputs.note)]),
        ]
        return PreparedRun(inputs: .object(object), workdir: workdir, pr: pr, projectID: inputs.projectID,
                           untrusted: untrusted)
    }

    // MARK: Steps

    private func performStep(_ node: WorkflowNode, pass: Int, context: JSONValue, run runID: UUID,
                             prepared: PreparedRun) async -> StepOutcome {
        guard let run = workflows.run(runID) else { return .failed("The run is gone.") }
        switch node.kind {
        case .context(let config):
            switch config.source {
            case .pullRequest: return await loadPullRequestContext(prepared)
            case .repository: return await loadRepositoryContext(prepared)
            case .jiraTicket: return await loadTicketContext(config, run: run, context: context)
            }
        case .agent(let config):
            return await performAgent(node, config: config, pass: pass, context: context, run: run, prepared: prepared)
        case .artifact(let config):
            return await writeArtifact(config, run: run, context: context, prepared: prepared)
        case .start, .condition, .loop:
            return .done(output: nil, text: "", cost: nil)
        }
    }

    private func loadPullRequestContext(_ prepared: PreparedRun) async -> StepOutcome {
        guard let pr = prepared.pr, let projectID = prepared.projectID else {
            return .done(output: .object(["available": .bool(false)]), text: "No pull request for this run.", cost: nil)
        }
        let detail = await prDetail(pr.number, in: projectID)
        let diff = await prDiff(pr.number, baseBranch: pr.baseBranch, in: projectID)
        let files = DiffParser.parse(diff.diff)
        let conversation = (detail?.comments ?? []).suffix(30).map { "@\($0.author): \($0.body)" }
        let reviews = (detail?.reviews ?? []).map { "@\($0.author): \($0.state)" + ($0.body.isEmpty ? "" : " — \($0.body)") }
        let output: JSONValue = .object([
            "available": .bool(true),
            "title": .string(pr.title), "url": .string(pr.url), "body": .string(detail?.body ?? ""),
            "files": .array(files.map { .string($0.path) }),
            "fileStats": .array(files.map { .object(["path": .string($0.path),
                                                      "additions": .number(Double($0.additions)),
                                                      "deletions": .number(Double($0.deletions))]) }),
            "conversation": .array(conversation.map { .string($0) }),
            "reviews": .array(reviews.map { .string($0) }),
            "checks": .array(pr.checks.map { .object(["name": .string($0.name), "state": .string($0.state.rawValue)]) }),
        ])
        var text = "# PR #\(pr.number) — \(pr.title)\n@\(pr.author), \(pr.branch) → \(pr.baseBranch), "
            + "+\(pr.additions) −\(pr.deletions) in \(pr.changedFiles) files\n\n## Description\n"
            + ((detail?.body ?? "").isEmpty ? "(none)" : detail!.body)
        text += "\n\n## Files\n" + files.map { "- \($0.path) (+\($0.additions) −\($0.deletions))" }.joined(separator: "\n")
        if !conversation.isEmpty { text += "\n\n## Conversation\n" + conversation.joined(separator: "\n") }
        if !reviews.isEmpty { text += "\n\n## Reviews\n" + reviews.joined(separator: "\n") }
        if !pr.checks.isEmpty {
            text += "\n\n## Checks\n" + pr.checks.map { "- \($0.name): \($0.state.rawValue)" }.joined(separator: "\n")
        }
        if let error = diff.error { text += "\n\n(The diff could not be loaded: \(error))" }
        return .done(output: output, text: text, cost: nil)
    }

    private func loadRepositoryContext(_ prepared: PreparedRun) async -> StepOutcome {
        let root = prepared.workdir
        let skipped: Set<String> = [".git", "node_modules", "vendor", ".build", "build", "dist", "var",
                                    ".loom-review", ".loom-guard-hooks", "Pods", ".idea"]
        let tree = await Task.detached { () -> [String] in
            let fm = FileManager.default
            var lines: [String] = []
            let top = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            for name in top where !skipped.contains(name) && lines.count < 200 {
                var isDirectory: ObjCBool = false
                _ = fm.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory)
                lines.append(isDirectory.boolValue ? name + "/" : name)
                guard isDirectory.boolValue else { continue }
                let inner = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted()
                for child in inner.prefix(25) { lines.append("  " + child) }
                if inner.count > 25 { lines.append("  … \(inner.count - 25) more") }
            }
            return lines
        }.value
        let readmeURL = ["README.md", "readme.md", "README", "README.rst"].map { root.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let readme = readmeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { String($0.prefix(6000)) } ?? ""
        var touched: [String] = []
        if let pr = prepared.pr, let projectID = prepared.projectID {
            touched = DiffParser.parse(await prDiff(pr.number, baseBranch: pr.baseBranch, in: projectID).diff).map(\.path)
        }
        let output: JSONValue = .object([
            "path": .string(root.path), "tree": .array(tree.map { .string($0) }),
            "readme": .string(readme), "touched": .array(touched.map { .string($0) }),
        ])
        var text = "Repository checked out at \(root.path)\n\n## Tree\n" + tree.joined(separator: "\n")
        if !touched.isEmpty { text += "\n\n## Touched by the PR\n" + touched.map { "- " + $0 }.joined(separator: "\n") }
        if !readme.isEmpty { text += "\n\n## README (start)\n" + readme }
        return .done(output: output, text: text, cost: nil)
    }

    static let ticketFields: [OutputField] = [
        OutputField("found", .boolean, "false when the ticket could not be read."),
        OutputField("key", .text),
        OutputField("summary", .text, "The ticket's title."),
        OutputField("status", .text, required: false),
        OutputField("description", .text, "The description, as Markdown."),
        OutputField("acceptanceCriteria", .list, "Strings: each acceptance criterion, from the description or its own field."),
        OutputField("comments", .list, "Strings \"author: text\", the last ten.", required: false),
        OutputField("links", .list, "Strings: linked tickets and pages.", required: false),
    ]

    private func loadTicketContext(_ config: ContextConfig, run: WorkflowRun, context: JSONValue) async -> StepOutcome {
        let key = JSONPath.lookup("ticket.key", in: context)?.plainText ?? ""
        guard !key.isEmpty else {
            return .done(output: .object(["found": .bool(false), "key": .string("")]),
                         text: "No Jira ticket for this run.", cost: nil)
        }
        let connectors = config.connectorIDs.compactMap { id in run.connectors.first { $0.id == id } }
        let wiring = ConnectorWiring.wire(connectors) { [workflows] id, key in workflows.secret(key, of: id) }
        if !wiring.missingSecrets.isEmpty {
            return .failed("Missing secret(s): " + wiring.missingSecrets.joined(separator: ", "))
        }
        let prompt = """
        Read the Jira ticket \(key) with the Atlassian tools: its summary, status, description, acceptance criteria (a field of their own, or a list in the description), its last comments and its links. Read only; never change the ticket. Keep the description's meaning; Markdown is fine.

        \(OutputSchema.instructions(for: Self.ticketFields))
        """
        let result = await runHeadless(prompt: prompt, fields: Self.ticketFields,
                                       appendSystemPrompt: "You read Jira tickets through MCP tools and report them faithfully.",
                                       wiring: wiring, allowedTools: [], model: workflows.defaultModel,
                                       workdir: nil, timeout: 300)
        guard case .done(let output, _, let cost, _, _) = result else { return result }
        var text = ""
        if let object = output?.objectValue {
            text = "# \(key) — \(object["summary"]?.plainText ?? "")\n"
            if let status = object["status"]?.plainText, !status.isEmpty { text += "Status: \(status)\n" }
            text += "\n" + (object["description"]?.plainText ?? "")
            if let criteria = object["acceptanceCriteria"], !criteria.isEmpty {
                text += "\n\n## Acceptance criteria\n" + criteria.plainText
            }
            if let comments = object["comments"], !comments.isEmpty { text += "\n\n## Comments\n" + comments.plainText }
        }
        return .done(output: output, text: text, cost: cost)
    }

    /// The expert's instructions with the skills of the step and of the expert.
    private func agentInstructions(expert: Expert?, skills: [String], workdir: URL) -> String {
        var parts: [String] = []
        if let prompt = expert?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        let names = Array(Set((expert?.skills ?? []) + skills)).sorted()
        if !names.isEmpty {
            let catalog = SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory,
                                             projectDirectory: workdir.appendingPathComponent(".claude/skills"))
            for name in names {
                guard let entry = catalog.first(where: { $0.name == name }), let path = entry.path,
                      let content = try? String(contentsOf: path, encoding: .utf8) else { continue }
                parts.append("## Skill: \(name)\nApply this skill in this step.\n\n\(content)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func performAgent(_ node: WorkflowNode, config: AgentConfig, pass: Int, context: JSONValue,
                              run: WorkflowRun, prepared: PreparedRun) async -> StepOutcome {
        let expert = config.expertID.flatMap { id in run.experts.first { $0.id == id } }
        let connectorIDs = (expert?.connectorIDs ?? []) + config.connectorIDs
        let connectors = connectorIDs.compactMap { id in run.connectors.first { $0.id == id } }
        let wiring = ConnectorWiring.wire(connectors) { [workflows] id, key in workflows.secret(key, of: id) }
        if !wiring.missingSecrets.isEmpty {
            return .failed("Missing secret(s): " + wiring.missingSecrets.joined(separator: ", "))
        }
        let rendered = TemplateRenderer.render(config.prompt, context: context).text
        let instructions = agentInstructions(expert: expert, skills: config.skills, workdir: prepared.workdir)
        let model = config.model ?? expert?.model ?? workflows.defaultModel
        let schema = OutputSchema.instructions(for: config.output)
        switch config.mode {
        case .headless:
            let prompt = schema.isEmpty ? rendered : rendered + "\n\n" + schema
            return await runHeadless(prompt: prompt, fields: config.output, appendSystemPrompt: instructions,
                                     wiring: wiring, allowedTools: expert?.allowedTools ?? Expert.readOnlyTools,
                                     model: model, workdir: prepared.workdir,
                                     timeout: TimeInterval(max(60, config.timeoutSeconds)))
        case .visible:
            let file = workflows.folder(for: run.id).appendingPathComponent("answers/\(node.id)-\(pass).json")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            let prompt = rendered + "\n\n" + (schema.isEmpty ? "Write your answer as a JSON object {\"text\": \"…\"}." : schema)
                + "\n\nAs your very last step, write that JSON object to the file `\(file.path)`, then say so in one line."
            let title = "\(run.workflow.name) · \(node.title)" + (pass > 1 ? " · passe \(pass)" : "")
            var badges = ["workflow"]
            if let expert { badges.append("expert:" + expert.name.lowercased().replacingOccurrences(of: " ", with: "-")) }
            guard let session = await launchWorkflowSession(directory: prepared.workdir, projectID: prepared.projectID,
                                                             title: title, badges: badges, prompt: prompt,
                                                             instructions: instructions, untrusted: prepared.untrusted)
            else { return .failed(startupError ?? "The step's session could not start.") }
            updateRun(run.id) { $0.state.nodes[node.id]?.sessionID = session.rawValue.uuidString }
            let fields = config.output
            let outcome = await awaitSessionReport(session, file: file,
                                                   timeout: .seconds(max(1800, config.timeoutSeconds * 3)),
                                                   handsOver: false) { text -> JSONValue? in
                if fields.isEmpty {
                    return LenientJSON.objectData(in: text).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                        .map(JSONValue.from(any:))
                }
                return try? OutputSchema.parse(text, fields: fields).get()
            }
            switch outcome {
            case .report(let output):
                return .done(output: output, text: output["text"]?.plainText ?? output.plainText, cost: nil,
                             session: session.rawValue.uuidString)
            case .noReport: return .failed("The session ended its turn without writing its answer.")
            case .ended: return .failed("The session ended before answering.")
            case .timedOut: return .failed("No answer in time.")
            case .needsYou: return .failed("The session waits for you.")
            }
        }
    }

    /// `claude -p` for one step: the answer parsed against its fields, asked
    /// again once when it does not fit.
    private func runHeadless(prompt: String, fields: [OutputField], appendSystemPrompt: String,
                             wiring: ConnectorWiring, allowedTools: [String], model: String,
                             workdir: URL?, timeout: TimeInterval) async -> StepOutcome {
        guard let claude = claudePath else { return .failed("claude was not found on this Mac.") }
        var request = ClaudeOneShot.Request(
            prompt: prompt, model: model, tools: .inherited, timeout: timeout, workingDirectory: workdir,
            appendSystemPrompt: appendSystemPrompt, mcpConfig: wiring.mcpConfig, strictMCPConfig: wiring.strict,
            allowedTools: allowedTools + wiring.toolPatterns)
        var cost = 0.0
        for attempt in 0..<2 {
            let result: ClaudeOneShot.Result
            do {
                result = try await ClaudeOneShot.run(request, executable: claude)
            } catch {
                return .failed(String(describing: error))
            }
            cost += result.costUSD ?? 0
            if fields.isEmpty { return .done(output: nil, text: result.text, cost: cost) }
            switch OutputSchema.parse(result.text, fields: fields) {
            case .success(let output):
                return .done(output: output, text: Self.readable(output), cost: cost)
            case .failure(let error):
                guard attempt == 0 else { return .failed("The answer did not fit its fields: \(error)") }
                request.prompt = prompt + "\n\nYour previous answer could not be used: \(error) "
                    + "Answer again with the JSON object only.\n\nYour previous answer:\n" + String(result.text.prefix(4000))
            }
        }
        return .failed("No usable answer.")
    }

    /// A step's answer as the next prompts read it: its fields, one by one.
    static func readable(_ output: JSONValue) -> String {
        guard let object = output.objectValue else { return output.plainText }
        return object.keys.sorted().map { key in
            let value = object[key]!.plainText
            return value.contains("\n") ? "\(key):\n\(value)" : "\(key): \(value)"
        }.joined(separator: "\n")
    }

    // MARK: Artifact

    /// A Loom theme's colours, by role, for a document (ADR-0017).
    static func artifactPalette(theme name: String, dark: Bool) -> ArtifactPalette {
        let store = ThemeStore.shared
        let family = name == "current" ? store.family(named: store.globalFamilyName) : store.family(named: name)
        let resolved = family ?? store.family(named: store.globalFamilyName) ?? ThemeFamily.loom
        let tokens = dark ? resolved.dark : resolved.light
        let document = resolved.document
        func nonEmpty(_ value: String?) -> String? {
            value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let fontsURL = nonEmpty(document?.fontsURL).flatMap { ThemeDocumentStyle.isAllowedFontsURL($0) ? $0 : nil }
        return ArtifactPalette(
            isDark: dark, bg: tokens.background, card: tokens.surface, bgSubtle: tokens.surfaceRaised,
            bgWarm: tokens.contentBackground, line: tokens.cardBorder, brand: tokens.groupHeader,
            link: tokens.accent, onLink: tokens.accentText, fg1: tokens.primaryText, fg2: tokens.secondaryText,
            fg3: tokens.mutedText, statusBlock: tokens.danger, statusFix: tokens.stateNeedsInput,
            statusOK: tokens.stateIdle,
            fontSans: nonEmpty(document?.fontSans) ?? ArtifactPalette.defaultSans,
            fontMono: nonEmpty(document?.fontMono) ?? ArtifactPalette.defaultMono,
            fontsURL: fontsURL ?? (document == nil || nonEmpty(document?.fontSans) == nil ? ArtifactPalette.defaultFontsURL : nil),
            radius: nonEmpty(document?.radius) ?? "16px",
            logoSVG: nonEmpty(document?.logoSVG), extraCSS: nonEmpty(document?.extraCSS))
    }

    /// The data a report reads: the run's context, its steps, how it went.
    static func artifactData(title: String, run: WorkflowRun, context: JSONValue) -> JSONValue {
        var object = context.objectValue ?? [:]
        object["title"] = .string(title)
        object["workflow"] = .string(run.workflow.name)
        object["nodes"] = .array(run.workflow.nodes.map { node in
            .object(["id": .string(node.id), "title": .string(node.title), "type": .string(node.kind.type.rawValue),
                     "status": .string(run.state.status(node.id).rawValue)])
        })
        let passes = 1 + (run.state.iterations.values.max() ?? 0)
        var runObject: [String: JSONValue] = [
            "id": .string(run.id.uuidString), "startedAt": .string(ISO8601DateFormatter().string(from: run.startedAt)),
            "finishedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "costUSD": .number(run.costUSD), "passes": .number(Double(passes)),
        ]
        if let note = context["run"]?["note"] { runObject["note"] = note }
        object["run"] = .object(runObject)
        return .object(object)
    }

    private func writeArtifact(_ config: ArtifactConfig, run: WorkflowRun, context: JSONValue,
                               prepared: PreparedRun) async -> StepOutcome {
        let title = TemplateRenderer.render(config.title, context: context).text
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? run.workflow.name : title
        let data = Self.artifactData(title: resolvedTitle, run: run, context: context)
        let html = ArtifactRenderer.html(template: config.template, title: resolvedTitle,
                                         palette: Self.artifactPalette(theme: config.theme, dark: config.dark),
                                         data: data)
        let url = workflows.folder(for: run.id).appendingPathComponent("artifact.html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed("The report could not be written: \(error.localizedDescription)")
        }
        var note = "Report written."
        if config.importToPRTab, let pr = prepared.pr, let projectID = prepared.projectID,
           let report = Self.reviewReport(from: context) {
            openPRTabInBackground(pr, in: projectID)
            let counts = await importReviewReport(report, pr: pr, in: projectID)
            note += " PR tab: \(counts.anchored) pending comment(s), \(counts.unanchored) in the summary."
        }
        return .done(output: .object(["path": .string(url.path)]), text: note, cost: nil, artifact: url.path)
    }

    /// The consolidated review a run produced — the latest step answering
    /// with a verdict and findings — as the PR tab imports one.
    static func reviewReport(from context: JSONValue) -> AutoReviewReport? {
        guard let steps = context["steps"]?.objectValue else { return nil }
        let candidates = steps.values.compactMap(\.objectValue).filter { $0["verdict"] != nil && $0["findings"]?.arrayValue != nil }
        guard let step = candidates.first else { return nil }
        let verdictText = step["verdict"]?.plainText.lowercased() ?? ""
        let verdict: AutoReviewReport.Verdict = verdictText.contains("approve") ? .approve
            : verdictText.contains("request") || verdictText.contains("change") ? .requestChanges : .comment
        let comments = (step["findings"]?.arrayValue ?? []).compactMap { finding -> AutoReviewReport.Comment? in
            guard let object = finding.objectValue, let path = object["path"]?.plainText, !path.isEmpty,
                  let line = object["line"]?.numberValue, line > 0 else { return nil }
            var body = "**\(object["title"]?.plainText ?? "Finding")**"
            if let detail = object["detail"]?.plainText, !detail.isEmpty { body += "\n\n" + detail }
            if let suggestion = object["suggestion"]?.plainText, !suggestion.isEmpty { body += "\n\n" + suggestion }
            return AutoReviewReport.Comment(path: path, firstLine: Int(line), lastLine: Int(line), body: body)
        }
        return AutoReviewReport(verdict: verdict, summary: step["summary"]?.plainText ?? "", comments: comments)
    }

    /// The PR's tab, opened pinned without taking the screen.
    func openPRTabInBackground(_ pr: GitHubService.PullRequest, in projectID: ProjectID) {
        prTabs.openInBackground(pr, in: projectID)
        savePRTabs()
    }
}
