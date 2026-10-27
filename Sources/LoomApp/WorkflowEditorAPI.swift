import Foundation
import LoomAgents
import LoomAPI
import LoomCore
import LoomUI
import LoomWorkflows

/// What the workflow editor asks Loom, and what Loom tells it (ADR-0017).
/// The validator, the estimate and the files are Loom's: the page draws.
extension AppModel {

    /// The editor's page, made once and kept: switching the app's tabs
    /// must not reload it.
    func workflowEditorHost() -> WorkflowEditorHost {
        if let host = workflows.editorHost { return host }
        let host = WorkflowEditorHost { [weak self] text in
            guard let self else { return #"{"ok":false,"error":"Loom is closing."}"# }
            return await self.handleWorkflowEditorRequest(text)
        }
        workflows.editorHost = host
        host.load()
        return host
    }

    private static func reply(_ result: Any) -> String {
        let object: [String: Any] = ["ok": true, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            return #"{"ok":false,"error":"The answer could not be encoded."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func failure(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func handleWorkflowEditorRequest(_ text: String) async -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let method = object["method"] as? String else { return Self.failure("Not a request.") }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "state.get":
            return Self.reply(editorState().map { $0 as Any } ?? NSNull())
        case "workflow.save":
            guard case .workflow = workflows.detail, let current = workflows.workflow(workflows.selectedWorkflowID)
            else { return Self.failure("Nothing to save: a run is read only.") }
            guard let raw = params["workflow"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  var workflow = try? WorkflowJSON.decoder.decode(Workflow.self, from: data)
            else { return Self.failure("The workflow could not be read.") }
            guard workflow.id == current.id else { return Self.failure("Another workflow is open.") }
            workflow.createdAt = current.createdAt
            workflows.save(workflow)
            return Self.reply(validationJSON(workflow))
        case "run.request":
            workflows.launchRequest = WorkflowsModel.LaunchRequest(workflowID: workflows.selectedWorkflowID,
                                                                   inputs: nil)
            return Self.reply(NSNull())
        case "node.open":
            guard case .run(let runID) = workflows.detail, let nodeID = params["nodeID"] as? String,
                  let raw = workflows.run(runID)?.state.nodes[nodeID]?.sessionID,
                  let uuid = UUID(uuidString: raw) else { return Self.failure("That step has no session.") }
            workflows.sessionToOpen = SessionID(uuid)
            return Self.reply(NSNull())
        case "orchestrator.open":
            guard case .run(let runID) = workflows.detail,
                  let raw = workflows.run(runID)?.orchestratorSessionID,
                  let uuid = UUID(uuidString: raw) else { return Self.failure("This run has no orchestrator.") }
            workflows.sessionToOpen = SessionID(uuid)
            return Self.reply(NSNull())
        default:
            return Self.failure("Unknown method \(method).")
        }
    }

    // MARK: What the page is told

    private static func any<T: Encodable>(_ value: T) -> Any {
        guard let data = try? WorkflowJSON.encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    func validationJSON(_ workflow: Workflow) -> [String: Any] {
        let issues = WorkflowValidator.validate(workflow, experts: workflows.experts, connectors: workflows.connectors)
        let estimate = CostEstimate.estimate(workflow, experts: workflows.experts, defaultModel: workflows.defaultModel)
        return ["issues": issues.map { issue -> [String: Any] in
                    var item: [String: Any] = ["severity": issue.severity.rawValue, "message": issue.message]
                    if let node = issue.nodeID { item["nodeID"] = node }
                    return item
                },
                "estimate": ["runs": estimate.runs,
                             "lowUSD": estimate.lowUSD.map { $0 as Any } ?? NSNull(),
                             "highUSD": estimate.highUSD.map { $0 as Any } ?? NSNull()]]
    }

    /// Experts, connectors, skills, themes: what the inspector offers.
    func editorLibraryJSON() -> [String: Any] {
        let projectID = selectedProject ?? projects.first?.id
        let catalog = projectID.map { skills(forProject: $0) }
            ?? SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory, projectDirectory: nil)
        return [
            "experts": workflows.experts.map { ["id": $0.id.uuidString, "name": $0.name, "domain": $0.domain,
                                                "color": $0.color] },
            "connectors": workflows.connectors.map { ["id": $0.id.uuidString, "name": $0.name] },
            "skills": catalog.map { ["name": $0.name, "description": $0.description,
                                    "scope": $0.scope == .project ? "project" : "global"] },
            "themes": ThemeStore.shared.families.map(\.name),
            "templates": ArtifactRenderer.templates.map { ["id": $0.id, "name": $0.name] },
            "palette": Self.editorPalette(),
        ]
    }

    /// The app's palette, for the editor to wear.
    static func editorPalette() -> [String: Any] {
        let palette = ThemeStore.shared.palette
        let t = palette.tokens
        return ["background": t.background, "contentBackground": t.contentBackground, "surface": t.surface,
                "surfaceRaised": t.surfaceRaised, "cardBorder": t.cardBorder, "accent": t.accent,
                "accentText": t.accentText, "primaryText": t.primaryText, "secondaryText": t.secondaryText,
                "mutedText": t.mutedText, "danger": t.danger, "groupHeader": t.groupHeader,
                "stateWorking": t.stateWorking, "stateNeedsInput": t.stateNeedsInput, "stateIdle": t.stateIdle,
                "isLight": palette.isLight]
    }

    /// A run as the editor paints it: each step's status, pass and answer.
    func editorRunJSON(_ run: WorkflowRun) -> [String: Any] {
        let planner = WorkflowPlanner(run.workflow)
        var nodes: [String: Any] = [:]
        for (id, record) in run.state.nodes {
            var item: [String: Any] = ["status": record.status.rawValue, "pass": planner.pass(of: id, in: run.state)]
            if let error = record.error { item["error"] = error }
            if let text = record.text { item["text"] = text }
            if let cost = record.costUSD { item["costUSD"] = cost }
            if let session = record.sessionID { item["sessionID"] = session }
            if let output = record.output { item["output"] = Self.any(output) }
            // What the orchestrator did to it (ADR-0018), for its card.
            if record.reruns > 0 { item["reruns"] = record.reruns }
            if record.status == .done, record.output?["skipped"]?.truthy == true,
               run.messages.contains(where: { $0.kind == .skip && $0.to == id }) {
                item["skippedByOrchestrator"] = true
            }
            let asked = run.messages.filter { $0.kind == .question && $0.to == id }.count
            if asked > 0 { item["asked"] = asked }
            nodes[id] = item
        }
        var json: [String: Any] = ["id": run.id.uuidString, "status": run.status.rawValue, "nodes": nodes]
        if let session = run.orchestratorSessionID {
            json["orchestrator"] = ["sessionID": session, "interventions": run.interventions,
                                    "holding": workflows.holding.contains(run.id)]
        }
        return json
    }

    /// Everything the page needs for what the sidebar has selected: a
    /// workflow to edit, or a run to watch (read only).
    func editorState() -> [String: Any]? {
        var state = editorLibraryJSON()
        switch workflows.detail {
        case .run(let id), .report(let id):
            guard let run = workflows.run(id) else { return nil }
            state["workflow"] = Self.any(run.workflow)
            state["readOnly"] = true
            state["run"] = editorRunJSON(run)
            state.merge(validationJSON(run.workflow)) { $1 }
        default:
            guard let workflow = workflows.workflow(workflows.selectedWorkflowID) else { return nil }
            state["workflow"] = Self.any(workflow)
            state["readOnly"] = false
            state.merge(validationJSON(workflow)) { $1 }
        }
        return state
    }

    func emitEditorState() {
        guard let host = workflows.editorHost else { return }
        host.emit(["type": "state", "state": editorState().map { $0 as Any } ?? NSNull()])
    }

    func emitEditorLibrary() {
        workflows.editorHost?.emit(["type": "library", "library": editorLibraryJSON()])
    }

    func emitEditorRun() {
        guard case .run(let id) = workflows.detail, let run = workflows.run(id) else { return }
        workflows.editorHost?.emit(["type": "run", "run": editorRunJSON(run)])
    }

    // MARK: Connectors

    /// A run with this connector alone: the tools it brings, and for
    /// Atlassian who it signs in as.
    func testConnector(_ id: UUID) async {
        guard let connector = workflows.connector(id) else { return }
        guard let claude = claudePath else {
            workflows.connectorTestResults[id] = "claude was not found on this Mac."
            return
        }
        workflows.connectorTesting.insert(id)
        defer { workflows.connectorTesting.remove(id) }
        let wiring = ConnectorWiring.wire([connector]) { [workflows] connectorID, key in
            workflows.secret(key, of: connectorID)
        }
        if !wiring.missingSecrets.isEmpty {
            workflows.connectorTestResults[id] = "Missing secret(s): " + wiring.missingSecrets.joined(separator: ", ")
            return
        }
        let prompt = """
        List the tools the MCP server "\(connector.serverKey)" gives you: their names only, one per line. \
        If it is an Atlassian server, then call the tool that tells who the current user is and give their name. \
        If you have no tool from that server, say exactly: NO TOOLS.
        """
        let request = ClaudeOneShot.Request(prompt: prompt, model: "haiku", tools: .inherited, timeout: 120,
                                            mcpConfig: wiring.mcpConfig, strictMCPConfig: wiring.strict,
                                            allowedTools: wiring.toolPatterns)
        do {
            let result = try await ClaudeOneShot.run(request, executable: claude)
            workflows.connectorTestResults[id] = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            workflows.connectorTestResults[id] = String(describing: error)
        }
    }
}
