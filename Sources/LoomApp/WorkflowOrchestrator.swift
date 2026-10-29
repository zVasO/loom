import Foundation
import LoomAgents
import LoomAPI
import LoomCore
import LoomWorkflows

/// A workflow run's orchestrator (ADR-0018): a visible session launched with
/// the run, told what happens as it happens, and the agents API's
/// `workflow.*` methods through which it reads, questions and steers the
/// run's steps. The run's loop stays the one that runs steps: a rerun or a
/// skip changes the run's state here, then wakes the loop.
extension AppModel {

    // MARK: The session

    func launchOrchestrator(_ runID: UUID, prepared: PreparedRun) async {
        guard let run = workflows.run(runID), let config = run.workflow.orchestrator else { return }
        let expert = config.expertID.flatMap { id in run.experts.first { $0.id == id } }
        let workflowInstructions = TemplateRenderer.render(config.instructions, context: prepared.inputs).text
        let instructions = [OrchestratorPrompt.rules, expert?.systemPrompt ?? "", workflowInstructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let model = config.model ?? expert?.model
        let brief = OrchestratorPrompt.brief(workflow: run.workflow, experts: run.experts, subject: run.subject,
                                             note: run.inputs.note, instructions: "",
                                             budget: config.interventionLimit, rerunsPerStep: config.rerunLimit,
                                             reviewBeforeArtifact: config.reviewBeforeArtifact)
        let title = "\(run.workflow.name) · \(run.subject) · orchestrator"
        guard let session = await launchWorkflowSession(directory: prepared.workdir, projectID: prepared.projectID,
                                                         title: title, badges: ["workflow", "orchestrator"],
                                                         prompt: brief, instructions: instructions,
                                                         untrusted: prepared.untrusted, role: .orchestrator,
                                                         model: model)
        else {
            workflows.log("Orchestrator: could not start (\(startupError ?? "unknown")); the run goes on without it.",
                          run: runID)
            return
        }
        updateRun(runID) { run in
            run.orchestratorSessionID = session.rawValue.uuidString
            run.orchestratorInstructions = instructions
            run.orchestratorModel = model
        }
        workflows.log("Orchestrator: session \(session.rawValue.uuidString)", run: runID)
    }

    func orchestratorSession(_ runID: UUID) -> SessionID? {
        workflows.run(runID)?.orchestratorSessionID.flatMap(UUID.init(uuidString:)).map(SessionID.init)
    }

    /// Its session is there and has not ended.
    func orchestratorIsAlive(_ runID: UUID) -> Bool {
        guard let id = orchestratorSession(runID), let state = sessions.first(where: { $0.id == id })?.state
        else { return false }
        return Self.isLive(state)
    }

    private static func isLive(_ state: SessionState) -> Bool {
        switch state {
        case .draft, .starting, .working, .needsInput, .idle: return true
        case .completed, .failed, .interrupted, .archived: return false
        }
    }

    // MARK: Telling it what happens

    /// Queues lines for the orchestrator; they are typed together once its
    /// session is idle — never in the middle of its turn.
    func notifyOrchestrator(_ runID: UUID, _ events: [OrchestratorPrompt.Event]) {
        guard !events.isEmpty, orchestratorSession(runID) != nil else { return }
        workflows.pendingEvents[runID, default: []] += events
        guard workflows.eventDeliveries[runID] == nil else { return }
        workflows.eventDeliveries[runID] = Task { [weak self] in
            await self?.deliverOrchestratorEvents(runID)
            self?.workflows.eventDeliveries[runID] = nil
        }
    }

    private func deliverOrchestratorEvents(_ runID: UUID) async {
        while !Task.isCancelled, !(workflows.pendingEvents[runID] ?? []).isEmpty {
            guard let session = orchestratorSession(runID), await awaitIdle(session, timeout: .seconds(1800)) else {
                workflows.pendingEvents[runID] = nil
                return
            }
            let events = workflows.pendingEvents.removeValue(forKey: runID) ?? []
            guard !events.isEmpty else { return }
            let text = OrchestratorPrompt.message(for: events)
            guard await submitWhenReady(text, to: session) else {
                workflows.pendingEvents[runID] = nil
                return
            }
            updateRun(runID) { $0.messages.append(RunMessage(kind: .event, from: RunMessage.loom,
                                                              to: RunMessage.orchestrator, text: text)) }
            // Its turn starts: the next lines wait for it to end.
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Until the session is idle (true), or gone, or the time is up (false).
    func awaitIdle(_ session: SessionID, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            guard let state = sessions.first(where: { $0.id == session })?.state, Self.isLive(state) else {
                return false
            }
            if state == .idle { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: The run's loop waiting for it

    /// Returns once the orchestrator asked something of the run.
    func awaitWake(_ runID: UUID) async {
        while !Task.isCancelled {
            if workflows.takeWake(runID) { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// A checkpoint: the orchestrator is told, and the run waits for a move
    /// (a rerun, a skip, proceed, stop), the end of its turn without one, or
    /// fifteen minutes.
    func holdForOrchestrator(_ runID: UUID, _ checkpoint: OrchestratorPrompt.Checkpoint) async {
        guard let session = orchestratorSession(runID) else { return }
        workflows.holding.insert(runID)
        defer { workflows.holding.remove(runID) }
        switch checkpoint {
        case .beforeReport: workflows.log("Waiting for the orchestrator before the report.", run: runID)
        case .failure(let step): workflows.log("Waiting for the orchestrator: \(step) failed.", run: runID)
        }
        notifyOrchestrator(runID, [.checkpoint(reason: checkpoint)])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(900)
        var deliveredAt: ContinuousClock.Instant?
        var sawWorking = false
        while clock.now < deadline, !Task.isCancelled {
            if workflows.proceedRequests.remove(runID) != nil {
                _ = workflows.takeWake(runID)
                return
            }
            if workflows.stopRequests[runID] != nil || workflows.takeWake(runID) { return }
            if deliveredAt == nil, (workflows.pendingEvents[runID] ?? []).isEmpty {
                deliveredAt = clock.now
            }
            if let deliveredAt {
                guard let state = sessions.first(where: { $0.id == session })?.state, Self.isLive(state) else { return }
                switch state {
                case .working, .starting: sawWorking = true
                case .idle where sawWorking || clock.now - deliveredAt > .seconds(90):
                    workflows.log("The orchestrator ended its turn: the run goes on.", run: runID)
                    return
                default: break
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        workflows.log("No answer from the orchestrator in 15 minutes: the run goes on.", run: runID)
    }

    // MARK: The agents API

    func handleWorkflowRequest(_ method: APIMethod, _ request: APIRequest, scope: APIScope) async throws -> APIResponse {
        guard case .session(let session) = scope else {
            throw APIError(code: .forbidden, message: "\(method.rawValue) answers a workflow session's own token only")
        }
        guard let part = workflows.part(of: session), let run = workflows.run(part.runID) else {
            throw APIError(code: .forbidden, message: "this session is not part of a workflow run")
        }
        guard part.role.allows(method) else {
            throw APIError(code: .forbidden, message: method == .workflowMessage
                           ? "only a step's session writes to the orchestrator"
                           : "\(method.rawValue) is the run's orchestrator's")
        }
        let planner = WorkflowPlanner(run.workflow)
        switch method {
        case .workflowGet:
            return .ok(request.id, apiWorkflowState(run, planner: planner))

        case .workflowStepRead:
            let params = try request.decodeParams(APIWorkflowStepRef.self)
            let (node, record) = try step(params.step, in: run)
            let earlier = run.state.history[node.id] ?? []
            if let pass = params.pass, pass >= 1, pass <= earlier.count {
                let output = earlier[pass - 1]
                return .ok(request.id, APIWorkflowAnswer(step: node.id, pass: pass, status: "done", output: output,
                                                         text: Self.readable(output)))
            }
            var recent: [String]?
            if let raw = record.sessionID, let uuid = UUID(uuidString: raw) {
                let native = await manager?.nativeSessionID(of: SessionID(uuid)) ?? SessionID(uuid)
                recent = Array(ClaudeNativeSessions.assistantTexts(for: native).suffix(3))
            }
            return .ok(request.id, APIWorkflowAnswer(step: node.id, pass: planner.pass(of: node.id, in: run.state),
                                                     status: record.status.rawValue, output: record.output,
                                                     text: record.text, error: record.error, recentMessages: recent))

        case .workflowStepAsk:
            let params = try request.decodeParams(APIWorkflowAskParams.self)
            let message = try Self.cleanWorkflowText(params.message, field: "message")
            let (node, record) = try step(params.step, in: run)
            guard case .agent(let config) = node.kind else {
                throw APIError(code: .invalidParams, message: "\(node.id) is not an agent: nothing to ask")
            }
            guard record.status == .done || record.status == .failed else {
                throw APIError(code: .conflict, message: "\(node.id) has not answered yet (\(record.status.rawValue))")
            }
            try spend(run)
            let key = "\(run.id.uuidString)/\(node.id)"
            guard workflows.asking.insert(key).inserted else {
                throw APIError(code: .conflict, message: "\(node.id) is already answering a question")
            }
            defer { workflows.asking.remove(key) }
            updateRun(run.id) { run in
                run.interventions += 1
                run.messages.append(RunMessage(kind: .question, from: RunMessage.orchestrator, to: node.id, text: message))
            }
            workflows.log("Orchestrator asks \(node.title): \(message.prefix(200))", run: run.id)
            let answer: String
            if let raw = record.sessionID, let uuid = UUID(uuidString: raw) {
                answer = try await askVisibleStep(SessionID(uuid), message: message)
            } else if let conversation = record.claudeSessionID {
                answer = try await askHeadlessStep(node, config: config, conversation: conversation, message: message,
                                                   run: run.id)
            } else {
                throw APIError(code: .unavailable, message: "\(node.id) kept no conversation to resume")
            }
            updateRun(run.id) { run in
                run.messages.append(RunMessage(kind: .answer, from: node.id, to: RunMessage.orchestrator, text: answer))
            }
            return .ok(request.id, APIWorkflowAck(message: "\(node.id) answered.",
                                                  interventionsLeft: workflows.run(run.id)?.interventionsLeft ?? 0,
                                                  answer: answer))

        case .workflowStepRerun:
            let params = try request.decodeParams(APIWorkflowRerunParams.self)
            let instructions = try Self.cleanWorkflowText(params.instructions, field: "instructions")
            try requireActive(run)
            let (node, _) = try step(params.step, in: run)
            try spend(run)
            var state = run.state
            do {
                try planner.rerun(node.id, instructions: instructions,
                                  limit: run.workflow.orchestrator?.rerunLimit ?? 0, in: &state)
            } catch let error as WorkflowPlanner.InterventionError {
                throw APIError(code: .conflict, message: error.description)
            }
            updateRun(run.id) { run in
                run.state = state
                run.interventions += 1
                run.messages.append(RunMessage(kind: .rerun, from: RunMessage.orchestrator, to: node.id, text: instructions))
            }
            workflows.log("Orchestrator reruns \(node.title): \(instructions.prefix(200))", run: run.id)
            workflows.wake(run.id)
            let after = planner.downstream(of: node.id).count
            return .ok(request.id, APIWorkflowAck(
                message: "\(node.id) runs again" + (after > 0 ? ", then the \(after) step(s) after it." : "."),
                interventionsLeft: workflows.run(run.id)?.interventionsLeft ?? 0))

        case .workflowStepSkip:
            let params = try request.decodeParams(APIWorkflowSkipParams.self)
            let reason = try Self.cleanWorkflowText(params.reason ?? "", field: "reason", allowEmpty: true)
            try requireActive(run)
            let (node, _) = try step(params.step, in: run)
            try spend(run)
            var state = run.state
            do {
                try planner.skip(node.id, reason: reason, in: &state)
            } catch let error as WorkflowPlanner.InterventionError {
                throw APIError(code: .conflict, message: error.description)
            }
            updateRun(run.id) { run in
                run.state = state
                run.interventions += 1
                run.messages.append(RunMessage(kind: .skip, from: RunMessage.orchestrator, to: node.id, text: reason))
            }
            workflows.log("Orchestrator skips \(node.title)" + (reason.isEmpty ? "" : ": \(reason)"), run: run.id)
            workflows.wake(run.id)
            return .ok(request.id, APIWorkflowAck(message: "\(node.id) is skipped.",
                                                  interventionsLeft: workflows.run(run.id)?.interventionsLeft ?? 0))

        case .workflowStop:
            let params = try request.decodeParams(APIWorkflowReasonParams.self)
            let reason = try Self.cleanWorkflowText(params.reason ?? "", field: "reason", allowEmpty: true)
            try requireActive(run)
            workflows.stopRequests[run.id] = reason
            workflows.wake(run.id)
            updateRun(run.id) { run in
                run.messages.append(RunMessage(kind: .stop, from: RunMessage.orchestrator, to: RunMessage.loom, text: reason))
            }
            return .ok(request.id, APIWorkflowAck(message: "The run stops.", interventionsLeft: run.interventionsLeft))

        case .workflowProceed:
            let params = try request.decodeParams(APIWorkflowReasonParams.self)
            let reason = try Self.cleanWorkflowText(params.reason ?? "", field: "reason", allowEmpty: true)
            guard workflows.holding.contains(run.id) else {
                throw APIError(code: .conflict, message: "Loom is not waiting for you: nothing to proceed with")
            }
            workflows.proceedRequests.insert(run.id)
            workflows.wake(run.id)
            updateRun(run.id) { run in
                run.messages.append(RunMessage(kind: .proceed, from: RunMessage.orchestrator, to: RunMessage.loom,
                                               text: reason))
            }
            return .ok(request.id, APIWorkflowAck(message: "The run goes on.", interventionsLeft: run.interventionsLeft))

        case .workflowMessage:
            let params = try request.decodeParams(APIWorkflowMessageParams.self)
            let text = try Self.cleanWorkflowText(params.text, field: "text")
            guard run.orchestratorSessionID != nil else {
                throw APIError(code: .unavailable, message: "this run has no orchestrator")
            }
            let sent = run.messages.filter { $0.kind == .fromStep }.count
            guard sent < Self.stepMessagesPerRun else {
                throw APIError(code: .conflict, message: "the steps already wrote \(sent) messages in this run, the limit")
            }
            let stepID = part.step ?? "step"
            let title = run.workflow.node(stepID)?.title ?? stepID
            updateRun(run.id) { run in
                run.messages.append(RunMessage(kind: .fromStep, from: stepID, to: RunMessage.orchestrator, text: text))
            }
            workflows.log("\(title) writes to the orchestrator: \(text.prefix(200))", run: run.id)
            notifyOrchestrator(run.id, [.fromStep(id: stepID, title: title, text: text)])
            return .ok(request.id, APIWorkflowAck(message: "Sent: the orchestrator reads it when its turn ends.",
                                                  interventionsLeft: run.interventionsLeft))

        default:
            throw APIError(code: .unknownMethod, message: method.rawValue)
        }
    }

    static let stepMessagesPerRun = 30

    func apiWorkflowState(_ run: WorkflowRun, planner: WorkflowPlanner) -> APIWorkflowState {
        let steps = run.workflow.nodes.map { node -> APIWorkflowStep in
            let record = run.state.nodes[node.id] ?? NodeRecord()
            var expert: String?
            var mode: String?
            if case .agent(let config) = node.kind {
                expert = config.expertID.flatMap { id in run.experts.first { $0.id == id }?.name }
                mode = config.mode.rawValue
            }
            let settled = record.status == .done || record.status == .failed
            let askable = node.kind.type == .agent && settled && (record.sessionID != nil || record.claudeSessionID != nil)
            return APIWorkflowStep(id: node.id, title: node.title, type: node.kind.type.rawValue,
                                   status: record.status.rawValue, pass: planner.pass(of: node.id, in: run.state),
                                   expert: expert, mode: mode, sessionId: record.sessionID,
                                   hasAnswer: record.output != nil || !(record.text ?? "").isEmpty,
                                   askable: askable, reruns: record.reruns, error: record.error)
        }
        return APIWorkflowState(runId: run.id.uuidString, workflow: run.workflow.name, subject: run.subject,
                                status: run.status.rawValue, waitingForYou: workflows.holding.contains(run.id),
                                interventionsLeft: run.interventionsLeft,
                                rerunsPerStep: run.workflow.orchestrator?.rerunLimit ?? 0,
                                costUSD: run.costUSD, steps: steps)
    }

    private func step(_ id: String, in run: WorkflowRun) throws -> (WorkflowNode, NodeRecord) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard let node = run.workflow.node(trimmed) else {
            throw APIError(code: .notFound, message: "no step \(trimmed) in this run (see loom_workflow_get)")
        }
        return (node, run.state.nodes[node.id] ?? NodeRecord())
    }

    private func spend(_ run: WorkflowRun) throws {
        guard run.interventionsLeft > 0 else {
            throw APIError(code: .conflict, message: "your budget of interventions is spent "
                           + "(\(run.workflow.orchestrator?.interventionLimit ?? 0)): say what you would have done")
        }
    }

    private func requireActive(_ run: WorkflowRun) throws {
        guard run.status.isActive, workflows.runTasks[run.id] != nil else {
            throw APIError(code: .conflict, message: "the run is over (\(run.status.rawValue))")
        }
    }

    /// What the orchestrator or a step wrote, before it is typed into a
    /// terminal or a prompt: printable, bounded, not empty.
    static func cleanWorkflowText(_ raw: String, field: String, allowEmpty: Bool = false) throws -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
        let printable = String(scalars)
        let text = printable.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !allowEmpty {
            throw APIError(code: .invalidParams, message: "\(field) must not be empty")
        }
        guard text.count <= APIWorkflowLimits.messageMaxLength else {
            throw APIError(code: .invalidParams,
                           message: "\(field) is too long (\(APIWorkflowLimits.messageMaxLength) characters at most)")
        }
        return text
    }

    // MARK: Questions

    /// Typed into the step's session once it is idle; its answer is what it
    /// says until the end of that turn, read in its transcript.
    private func askVisibleStep(_ session: SessionID, message: String) async throws -> String {
        guard await awaitIdle(session, timeout: .seconds(240)) else {
            throw APIError(code: .unavailable, message: "the step's session is closed or busy: open it in Sessions")
        }
        let native = await manager?.nativeSessionID(of: session) ?? session
        let offset = ClaudeNativeSessions.size(for: native)
        guard await submitWhenReady("[Question from the workflow's orchestrator]\n" + message, to: session) else {
            throw APIError(code: .unavailable, message: "the question could not be typed into the step's session")
        }
        let clock = ContinuousClock()
        let sentAt = clock.now
        var sawWorking = false
        var waitsOnPerson = false
        while clock.now - sentAt < .seconds(330), !Task.isCancelled {
            guard let state = sessions.first(where: { $0.id == session })?.state, Self.isLive(state) else { break }
            if state == .working { sawWorking = true }
            if state == .needsInput, sawWorking {
                waitsOnPerson = true
                break
            }
            if state == .idle, sawWorking || clock.now - sentAt > .seconds(20) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        // The transcript's last lines land a beat after the turn ends.
        try? await Task.sleep(for: .seconds(1))
        let texts = ClaudeNativeSessions.assistantTexts(for: native, after: offset)
        var answer = texts.suffix(4).joined(separator: "\n\n")
        if answer.isEmpty { answer = "(The step said nothing in its session yet.)" }
        if waitsOnPerson { answer += "\n\n(The step now waits for the person in its session.)" }
        return answer
    }

    /// `claude -p --resume` in the step's conversation, as the step ran:
    /// its expert, its tools, its connectors, its folder.
    private func askHeadlessStep(_ node: WorkflowNode, config raw: AgentConfig, conversation: String, message: String,
                                 run runID: UUID) async throws -> String {
        guard let claude = claudePath else { throw APIError(code: .unavailable, message: "claude was not found") }
        guard let run = workflows.run(runID) else { throw APIError(code: .notFound, message: "the run is gone") }
        let config = BlockResolver.effective(raw, blocks: run.blocks)
        let expert = config.expertID.flatMap { id in run.experts.first { $0.id == id } }
        let connectors = ((expert?.connectorIDs ?? []) + config.connectorIDs)
            .compactMap { id in run.connectors.first { $0.id == id } }
        let wiring = ConnectorWiring.wire(connectors) { [workflows] id, key in workflows.secret(key, of: id) }
        let workdir = run.workingDirectory.map { URL(fileURLWithPath: $0) } ?? projectRepo(run.inputs.projectID)
        let request = ClaudeOneShot.Request(
            prompt: "[Question from the workflow's orchestrator]\n" + message
                + "\n\nAnswer in prose, briefly; no JSON this time.",
            model: config.model ?? expert?.model ?? workflows.defaultModel, tools: .inherited, timeout: 540,
            workingDirectory: workdir,
            appendSystemPrompt: agentInstructions(expert: expert, skills: config.skills,
                                                  workdir: workdir ?? workflows.folder(for: runID)),
            mcpConfig: wiring.mcpConfig, strictMCPConfig: wiring.strict,
            allowedTools: (expert?.allowedTools ?? Expert.readOnlyTools) + wiring.toolPatterns,
            resume: conversation)
        let result: ClaudeOneShot.Result
        do {
            result = try await ClaudeOneShot.run(request, executable: claude)
        } catch {
            throw APIError(code: .unavailable, message: "the step could not answer: \(error)")
        }
        updateRun(runID) { run in
            run.costUSD += result.costUSD ?? 0
            if let id = result.sessionID { run.state.nodes[node.id]?.claudeSessionID = id }
        }
        return result.text
    }
}
