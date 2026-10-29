import Foundation
import LoomAgents
import LoomAPI
import LoomCore
import LoomWorkflows

/// The steps ADR-0019 adds to a run: a person's decision, an agent run once
/// per item of a list, a shell command. Each answers a verdict its links
/// may follow.
extension AppModel {

    // MARK: A person decides

    /// The step waits for the person: a notification, a banner on the run,
    /// their answer as the verdict. Past its deadline, the last option (the
    /// refusal) counts.
    func awaitApproval(_ node: WorkflowNode, config: ApprovalConfig, context: JSONValue,
                       run: WorkflowRun) async -> StepOutcome {
        let question = TemplateRenderer.render(config.question, context: context).text
        let options = config.cleanOptions
        guard let fallback = options.last else { return .failed("The step offers no answer.") }
        let pending = WorkflowsModel.PendingApproval(runID: run.id, step: node.id, title: node.title,
                                                     question: question, options: options)
        workflows.approvalDecisions[pending.id] = nil
        workflows.pendingApprovals.removeAll { $0.id == pending.id }
        workflows.pendingApprovals.append(pending)
        updateRun(run.id) { $0.state.nodes[node.id]?.status = .waitingOnUser }
        workflows.log("\(node.title): waiting for your decision", run: run.id)
        postAutoReviewNotification(title: "\(run.workflow.name) — à toi de décider",
                                   body: "\(run.subject) · \(question)", id: "loom.workflow.\(run.id).\(node.id)")
        defer { workflows.pendingApprovals.removeAll { $0.id == pending.id } }

        let clock = ContinuousClock()
        let deadline = config.timeoutHours.map { clock.now + .seconds(max(60, $0 * 3600)) }
        while !Task.isCancelled {
            if let decision = workflows.approvalDecisions.removeValue(forKey: pending.id) {
                updateRun(run.id) { $0.state.nodes[node.id]?.status = .running }
                let comment = decision.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                let output: JSONValue = .object(["verdict": .string(decision.option), "comment": .string(comment),
                                                 "by": .string("you")])
                return .done(output: output, text: "You answered «\(decision.option)»"
                             + (comment.isEmpty ? "." : ": \(comment)"), cost: nil)
            }
            if let deadline, clock.now >= deadline {
                return .done(output: .object(["verdict": .string(fallback), "comment": .string(""),
                                              "by": .string("timeout")]),
                             text: "No answer in time: «\(fallback)».", cost: nil)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return .failed("Stopped.")
    }

    // MARK: For each item

    /// The step's agent once per item, headless, a few at a time; the
    /// answers gathered, the verdict the worst of theirs.
    func performForEach(_ node: WorkflowNode, config: ForEachConfig, pass: Int, context: JSONValue,
                        run: WorkflowRun, prepared: PreparedRun) async -> StepOutcome {
        let list: [JSONValue]
        switch JSONPath.lookup(config.items, in: context) {
        case .array(let items)?: list = items
        case .string(let text)?:
            list = text.split(whereSeparator: \.isNewline).map { .string(String($0)) }
        case nil, .null?: list = []
        case let other?: list = [other]
        }
        let items = Array(list.prefix(config.itemLimit))
        guard !items.isEmpty else {
            return .done(output: .object(["results": .array([]), "count": .number(0), "failed": .number(0)]),
                         text: "No item in \(config.items).", cost: nil)
        }
        if list.count > items.count {
            workflows.log("\(node.title): \(list.count) items, the first \(items.count) only", run: run.id)
        }
        let base = context.objectValue ?? [:]
        let contexts = items.indices.map { index -> JSONValue in
            var itemContext = base
            itemContext["item"] = items[index]
            itemContext["index"] = .number(Double(index + 1))
            return .object(itemContext)
        }
        let outcomes = await withTaskGroup(of: (Int, StepOutcome).self) { group -> [Int: StepOutcome] in
            var next = 0
            var done: [Int: StepOutcome] = [:]
            while next < items.count {
                if next >= config.concurrencyLimit {
                    guard let finished = await group.next() else { break }
                    done[finished.0] = finished.1
                    if Task.isCancelled { break }
                }
                let index = next
                let scoped = contexts[index]
                group.addTask { [weak self] in
                    guard let self else { return (index, .failed("Loom is closing.")) }
                    return (index, await self.performAgent(node, config: config.agent, pass: pass, context: scoped,
                                                           run: run, prepared: prepared, headlessOnly: true))
                }
                next += 1
            }
            for await finished in group { done[finished.0] = finished.1 }
            return done
        }
        var results: [JSONValue] = []
        var verdicts: [JSONValue] = []
        var lines: [String] = []
        var failed = 0
        var cost = 0.0
        for index in items.indices {
            let label = items[index].plainText.prefix(120)
            switch outcomes[index] {
            case .done(let output, let text, let spent, _, _, _)?:
                cost += spent ?? 0
                results.append(output ?? .object(["text": .string(text)]))
                let verdict = output?["verdict"]?.plainText
                if let verdict { verdicts.append(.string(verdict)) }
                lines.append("\(index + 1). \(label)" + (verdict.map { " → \($0)" } ?? "")
                             + (output?["verdictReason"].map { ": \($0.plainText)" } ?? ""))
            case .failed(let message)?:
                failed += 1
                results.append(.object(["error": .string(message)]))
                lines.append("\(index + 1). \(label) → failed: \(message)")
            case nil:
                failed += 1
                results.append(.object(["error": .string("Stopped.")]))
            }
        }
        if failed == items.count { return .failed("Every item failed: \(lines.first ?? "")") }
        var output: [String: JSONValue] = [
            "items": .array(items), "results": .array(results), "verdicts": .array(verdicts),
            "count": .number(Double(items.count)), "failed": .number(Double(failed)),
        ]
        let options = BlockResolver.effective(config.agent, blocks: run.blocks).verdict?.cleanOptions ?? []
        if let worst = VerdictConfig.worst(verdicts.map(\.plainText), options: options) {
            output["verdict"] = .string(worst)
        }
        return .done(output: .object(output), text: lines.joined(separator: "\n"), cost: cost)
    }

    // MARK: A command

    /// What a command learns of the run: never in its line, always here.
    static func commandEnvironment(run: WorkflowRun, prepared: PreparedRun, folder: URL) -> [String: String] {
        var environment = ["LOOM_RUN_ID": run.id.uuidString, "LOOM_RUN_FOLDER": folder.path,
                           "LOOM_REPO_PATH": prepared.workdir.path, "LOOM_WORKFLOW": run.workflow.name]
        if let pr = prepared.pr {
            environment["LOOM_PR_NUMBER"] = String(pr.number)
            environment["LOOM_PR_BASE"] = pr.baseBranch.isEmpty ? "main" : pr.baseBranch
            environment["LOOM_PR_HEAD"] = pr.branch
            environment["LOOM_PR_HEAD_SHA"] = pr.headSHA
        }
        if let key = run.inputs.jiraKey, !key.isEmpty { environment["LOOM_TICKET"] = key }
        return environment
    }

    /// The line in the run's folder (the PR's worktree, read only): its exit
    /// code is the verdict, `pass` or `fail`.
    func runCommand(_ config: CommandConfig, run: WorkflowRun, prepared: PreparedRun) async -> StepOutcome {
        let folder = workflows.folder(for: run.id)
        let request = CommandRunner.Request(
            command: config.command, workingDirectory: prepared.workdir, timeout: TimeInterval(config.timeoutLimit),
            environment: Self.commandEnvironment(run: run, prepared: prepared, folder: folder))
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(request)
        } catch {
            return .failed(String(describing: error))
        }
        if result.timedOut { return .failed("No end in \(config.timeoutLimit) s: the command was stopped.") }
        let pass = config.passCodes.contains(Int(result.exitCode))
        let verdict = pass ? "pass" : "fail"
        var text = "exit \(result.exitCode) — \(verdict)"
        let errors = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let printed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !printed.isEmpty { text += "\n\n" + printed }
        if !errors.isEmpty { text += "\n\n" + errors }
        if !pass, prepared.untrusted,
           errors.localizedCaseInsensitiveContains("read-only file system")
            || errors.localizedCaseInsensitiveContains("permission denied") {
            text += "\n\n(The PR's worktree is read only: write to $LOOM_RUN_FOLDER instead.)"
        }
        return .done(output: .object(["exitCode": .number(Double(result.exitCode)), "verdict": .string(verdict),
                                      "stdout": .string(result.stdout), "stderr": .string(result.stderr)]),
                     text: text, cost: nil)
    }
}
