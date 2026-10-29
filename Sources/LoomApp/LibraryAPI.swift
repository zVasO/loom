import Foundation
import LoomAgents
import LoomAPI
import LoomCore
import LoomGit
import LoomUI
import LoomWorkflows

/// The agents API's `library.*` methods (ADR-0020): an agent reads the
/// workflow library and the review schedules, and proposes changes. Every
/// save is a proposal — it never runs, never fires, until the person
/// validates it in Loom. Connectors stay read only; no method touches a session.
extension AppModel {

    func handleLibraryRequest(_ method: APIMethod, _ request: APIRequest, scope: APIScope) async throws -> APIResponse {
        let (by, sessionID) = proposer(scope)
        switch method {
        case .libraryReference:
            return .ok(request.id, APIToolContent(text: WorkflowReference.markdown()))

        case .libraryGet:
            return APIResponse(id: request.id, result: libraryJSON())

        case .libraryWorkflowGet:
            let params = try request.decodeParams(APILibraryRef.self)
            guard let id = UUID(uuidString: params.id), let workflow = workflows.workflow(id) else {
                throw APIError(code: .notFound, message: "no workflow \(params.id) (see loom_library_get)")
            }
            var shown = workflow
            shown.proposal = nil
            var object = Self.libraryJSONValue(shown).objectValue ?? [:]
            object["proposed"] = .bool(workflow.isProposed)
            return APIResponse(id: request.id, result: .object(object))

        case .libraryValidate:
            let workflow = try Self.decodeLibraryParam(Workflow.self, from: request, key: "workflow")
            return APIResponse(id: request.id, result: JSONValue.from(any: validationJSON(workflow)))

        case .libraryWorkflowSave:
            var workflow = try Self.decodeLibraryParam(Workflow.self, from: request, key: "workflow")
            guard workflow.nodes.count <= APILibraryLimits.stepsPerWorkflow else {
                throw APIError(code: .invalidParams, message: "\(APILibraryLimits.stepsPerWorkflow) steps at most")
            }
            let existing = workflows.workflow(workflow.id)
            try requireRoom(updating: existing?.isProposed == true)
            workflow.name = APILimits.sanitizedTitle(workflow.name).isEmpty ? "Workflow" : APILimits.sanitizedTitle(workflow.name)
            let saved = workflows.propose(workflow, by: by, session: sessionID)
            proposalSaved(by: by, session: sessionID, what: "the workflow «\(saved.name)»")
            if let sessionID, workflows.builder(ofSession: sessionID) != nil {
                workflows.setBuilderWorkflow(session: sessionID, saved.id)
                // The builder's workflow, on screen as it takes shape.
                workflows.selectedWorkflowID = saved.id
                workflows.detail = .workflow
            }
            if workflows.detail == .workflow, workflows.selectedWorkflowID == saved.id { emitEditorState() }
            var result = validationJSON(saved)
            result["id"] = saved.id.uuidString
            result["proposed"] = true
            result["changes"] = ProposalDiff.workflow(saved, previous: saved.proposal?.previous).map(\.text)
            result["next"] = "The person validates it in Loom (Workflows › To review) before it can run."
            return APIResponse(id: request.id, result: JSONValue.from(any: result))

        case .libraryBlockSave:
            let block = try Self.decodeLibraryParam(WorkflowBlock.self, from: request, key: "block")
            try requireRoom(updating: workflows.block(block.id)?.isProposed == true)
            let saved = workflows.propose(block, by: by, session: sessionID)
            proposalSaved(by: by, session: sessionID, what: "the block «\(saved.name)»")
            emitEditorLibrary()
            return APIResponse(id: request.id, result: .object([
                "id": .string(saved.id.uuidString), "proposed": .bool(true),
                "changes": .array(ProposalDiff.block(saved, previous: saved.proposal?.previous).map { .string($0.text) }),
            ]))

        case .libraryRuleSetSave:
            let ruleSet = try Self.decodeLibraryParam(RuleSet.self, from: request, key: "ruleSet")
            try requireRoom(updating: workflows.ruleSet(ruleSet.id)?.isProposed == true)
            let saved = workflows.propose(ruleSet, by: by, session: sessionID)
            proposalSaved(by: by, session: sessionID, what: "the rule set «\(saved.name)»")
            emitEditorLibrary()
            return APIResponse(id: request.id, result: .object(["id": .string(saved.id.uuidString),
                                                                "proposed": .bool(true)]))

        case .libraryExpertSave:
            let expert = try Self.decodeLibraryParam(Expert.self, from: request, key: "expert")
            try requireRoom(updating: workflows.expert(expert.id)?.isProposed == true)
            for id in expert.connectorIDs where workflows.connector(id) == nil {
                throw APIError(code: .invalidParams, message: "no connector \(id.uuidString): connectors are the person's to add")
            }
            let saved = workflows.propose(expert, by: by, session: sessionID)
            proposalSaved(by: by, session: sessionID, what: "the expert «\(saved.name)»")
            emitEditorLibrary()
            return APIResponse(id: request.id, result: .object([
                "id": .string(saved.id.uuidString), "proposed": .bool(true),
                "changes": .array(ProposalDiff.expert(saved, previous: saved.proposal?.previous).map { .string($0.text) }),
            ]))

        case .libraryScheduleSave:
            guard case .object(let fields)? = request.params["schedule"] else {
                throw APIError(code: .invalidParams, message: "schedule must be an object")
            }
            let existing = (fields["id"]?.stringValue).flatMap(UUID.init(uuidString:))
                .flatMap { id in reviewSchedules.schedules.first { $0.id == id } }
            try requireRoom(updating: existing?.isProposed == true)
            let schedule = try scheduleProposal(fields, existing: existing, by: by, session: sessionID)
            if let index = reviewSchedules.schedules.firstIndex(where: { $0.id == schedule.id }) {
                reviewSchedules.schedules[index] = schedule
            } else {
                reviewSchedules.schedules.append(schedule)
            }
            saveReviewSchedules()
            proposalSaved(by: by, session: sessionID, what: "the review schedule «\(schedule.name)»")
            return APIResponse(id: request.id, result: .object([
                "id": .string(schedule.id.uuidString), "proposed": .bool(true),
                "next": .string("It does not run until the person validates it (Settings › Scheduled reviews)."),
            ]))

        case .libraryRunRequest:
            let params = try request.decodeParams(APILibraryRunParams.self)
            guard let id = UUID(uuidString: params.workflowId), workflows.workflow(id) != nil else {
                throw APIError(code: .notFound, message: "no workflow \(params.workflowId)")
            }
            let projectID = params.projectId.flatMap(UUID.init(uuidString:)).map(ProjectID.init)
            if let projectID, project(projectID) == nil {
                throw APIError(code: .invalidParams, message: "no project \(params.projectId ?? "")")
            }
            let inputs = RunInputs(trigger: params.prNumber != nil ? .pullRequest : .manual, projectID: projectID,
                                   prNumber: params.prNumber, jiraKey: params.jiraKey,
                                   note: String((params.note ?? "").prefix(2_000)))
            workflows.launchRequest = WorkflowsModel.LaunchRequest(workflowID: id, inputs: inputs)
            workflows.revealRequest = UUID()
            return APIResponse(id: request.id, result: .object([
                "opened": .bool(true),
                "message": .string("The Run sheet is open in Loom: the person checks it and clicks Run."),
            ]))

        default:
            throw APIError(code: .unknownMethod, message: method.rawValue)
        }
    }

    // MARK: Proposals waiting on the person

    struct ProposalItem: Identifiable {
        var ref: WorkflowsModel.ProposalRef
        var kind: String
        var title: String
        var by: String
        var at: Date
        var changes: [ProposalDiff.Change]
        var id: String { "\(ref)" }
    }

    /// Every proposal, oldest first: library items and review schedules.
    var pendingProposals: [ProposalItem] {
        var items: [ProposalItem] = []
        for item in workflows.workflows {
            guard let proposal = item.proposal else { continue }
            items.append(ProposalItem(ref: .workflow(item.id), kind: "Workflow", title: item.name, by: proposal.by,
                                      at: proposal.at, changes: ProposalDiff.workflow(item, previous: proposal.previous)))
        }
        for item in workflows.blocks {
            guard let proposal = item.proposal else { continue }
            items.append(ProposalItem(ref: .block(item.id), kind: "Block", title: item.name, by: proposal.by,
                                      at: proposal.at, changes: ProposalDiff.block(item, previous: proposal.previous)))
        }
        for item in workflows.experts {
            guard let proposal = item.proposal else { continue }
            items.append(ProposalItem(ref: .expert(item.id), kind: "Expert", title: item.name, by: proposal.by,
                                      at: proposal.at, changes: ProposalDiff.expert(item, previous: proposal.previous)))
        }
        for item in workflows.ruleSets {
            guard let proposal = item.proposal else { continue }
            items.append(ProposalItem(ref: .ruleSet(item.id), kind: "Rules", title: item.name, by: proposal.by,
                                      at: proposal.at, changes: ProposalDiff.ruleSet(item, previous: proposal.previous)))
        }
        for item in proposedReviewSchedules {
            guard let proposal = item.proposal else { continue }
            items.append(ProposalItem(ref: .schedule(item.id), kind: "Schedule", title: item.name, by: proposal.by,
                                      at: proposal.at, changes: scheduleChanges(item, previous: proposal.previous)))
        }
        return items.sorted { $0.at < $1.at }
    }

    func scheduleChanges(_ new: ReviewSchedule, previous old: ReviewSchedule?) -> [ProposalDiff.Change] {
        let days = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let when = String(format: "%02d:%02d", new.hour, new.minute) + " on "
            + new.weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { days[$0] }.joined(separator: ", ")
        let slices = new.targets.map { target in
            (project(target.projectID)?.name ?? "a project") + ": " + target.query + " (≤ \(target.limit))"
        }
        let workflow = new.workflowID.flatMap { workflows.workflow($0)?.name } ?? "the built-in review"
        var changes = [ProposalDiff.Change((old == nil ? "New schedule, " : "Now ") + when + (new.enabled ? "" : " (off)"),
                                           flagged: true)]
        changes += slices.map { ProposalDiff.Change("Reviews " + $0) }
        changes.append(ProposalDiff.Change("With " + workflow + " — each PR it picks runs it, unattended."))
        return changes
    }

    func validateProposal(_ ref: WorkflowsModel.ProposalRef) {
        if case .schedule(let id) = ref { validateReviewSchedule(id) } else { workflows.validate(ref) }
        emitEditorState()
    }

    func revertProposal(_ ref: WorkflowsModel.ProposalRef) {
        if case .schedule(let id) = ref { revertReviewSchedule(id) } else { workflows.revert(ref) }
        emitEditorState()
    }

    /// Where the person reads a proposal in full.
    func openProposal(_ ref: WorkflowsModel.ProposalRef) {
        switch ref {
        case .workflow(let id):
            workflows.selectedWorkflowID = id
            workflows.detail = .workflow
            emitEditorState()
        case .block(let id):
            workflows.detail = .workflow
            workflows.editorHost?.emit(["type": "editBlock", "id": id.uuidString])
        case .expert(let id): workflows.detail = .expert(id)
        case .ruleSet(let id): workflows.detail = .ruleSet(id)
        case .schedule: workflows.settingsRequest = UUID()
        }
    }

    // MARK: The workflow builder

    /// "Create with AI" / "Improve with AI": a visible session that builds
    /// with the person through the library tools, filed under Sessions ›
    /// Workflows. What it saves waits in To review.
    func startWorkflowBuilder(improving workflowID: UUID? = nil) async {
        let projectID = selectedProject ?? projects.first?.id
        let directory = projectRepo(projectID) ?? workflows.store.root
        let workflow = workflowID.flatMap { workflows.workflow($0) }
        let title = workflow.map { "Improve «\($0.name)»" } ?? "Workflow builder"
        guard let session = await launchWorkflowSession(directory: directory, projectID: projectID, title: title,
                                                         badges: ["workflow", "builder"],
                                                         prompt: BuilderPrompt.opening(improving: workflow),
                                                         instructions: BuilderPrompt.instructions, untrusted: false)
        else { return }
        workflows.addBuilder(session: session.rawValue.uuidString, workflowID: workflowID)
        workflows.sessionToOpen = session
    }

    // MARK: Helpers

    /// Who proposes: the session's title, or the CLI under the global token.
    private func proposer(_ scope: APIScope) -> (String, String?) {
        switch scope {
        case .session(let id):
            let title = sessions.first { $0.id == id }?.title ?? allRecords.first { $0.id == id }?.title ?? "a session"
            return (APILimits.sanitizedTitle(title), id.rawValue.uuidString)
        case .global:
            return ("loom CLI", nil)
        }
    }

    /// Bounded: a runaway agent fills a list, not the disk.
    private func requireRoom(updating: Bool) throws {
        guard !updating else { return }
        let pending = workflows.libraryProposalCount + proposedReviewSchedules.count
        guard pending < APILibraryLimits.pendingProposals else {
            throw APIError(code: .conflict, message: "\(pending) proposals already wait on the person: ask them to "
                           + "review those first (Workflows › To review)")
        }
    }

    /// The first proposal of a session tells the person once.
    private func proposalSaved(by: String, session: String?, what: String) {
        let key = session ?? "cli"
        guard workflows.notifiedProposers.insert(key).inserted else { return }
        postAutoReviewNotification(title: "Loom — to review", body: "\(by) proposes \(what).",
                                   id: "loom.proposal.\(key)")
    }

    static func decodeLibraryParam<T: Decodable>(_ type: T.Type, from request: APIRequest, key: String) throws -> T {
        guard let value = request.params[key], case .object = value else {
            throw APIError(code: .invalidParams, message: "\(key) must be a JSON object")
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_000_000 else { throw APIError(code: .invalidParams, message: "\(key) is too large") }
        do {
            return try WorkflowJSON.decoder.decode(type, from: data)
        } catch {
            throw APIError(code: .invalidParams, message: "\(key) could not be read: \(error)")
        }
    }

    static func libraryJSONValue<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? WorkflowJSON.encoder.encode(value),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
        return JSONValue.from(any: any)
    }

    /// A schedule from an agent's fields — lenient: what it leaves out keeps
    /// its value, or the default.
    private func scheduleProposal(_ fields: [String: JSONValue], existing: ReviewSchedule?, by: String,
                                  session: String?) throws -> ReviewSchedule {
        var schedule = existing ?? ReviewSchedule(name: "Reviews", targets: [])
        schedule.proposal = nil
        if let name = fields["name"]?.stringValue {
            let clean = APILimits.sanitizedTitle(name)
            schedule.name = clean.isEmpty ? "Reviews" : clean
        }
        if case .bool(let enabled)? = fields["enabled"] { schedule.enabled = enabled }
        if let hour = fields["hour"]?.numberValue { schedule.hour = min(max(Int(hour), 0), 23) }
        if let minute = fields["minute"]?.numberValue { schedule.minute = min(max(Int(minute), 0), 59) }
        if case .array(let days)? = fields["weekdays"] {
            schedule.weekdays = Set(days.compactMap { $0.numberValue.map(Int.init) }.filter { (1...7).contains($0) })
        }
        if fields.keys.contains("workflowID") || fields.keys.contains("workflowId") {
            let raw = (fields["workflowID"] ?? fields["workflowId"])?.stringValue
            if let raw, !raw.isEmpty {
                guard let id = UUID(uuidString: raw), workflows.workflow(id) != nil else {
                    throw APIError(code: .invalidParams, message: "no workflow \(raw)")
                }
                schedule.workflowID = id
            } else {
                schedule.workflowID = nil
            }
        }
        if case .array(let targets)? = fields["targets"] {
            schedule.targets = try targets.prefix(10).map { target in
                guard let object = target.objectValue,
                      let raw = (object["projectID"] ?? object["projectId"])?.stringValue,
                      let uuid = UUID(uuidString: raw), project(ProjectID(uuid)) != nil else {
                    throw APIError(code: .invalidParams, message: "each target needs the projectID of a Loom project")
                }
                return ReviewScheduleTarget(projectID: ProjectID(uuid),
                                            query: String((object["query"]?.stringValue ?? PRFilter.needsReview.query).prefix(500)),
                                            limit: Int(object["limit"]?.numberValue ?? 5))
            }
        }
        let timeChanged = existing.map { $0.hour != schedule.hour || $0.minute != schedule.minute
            || $0.weekdays != schedule.weekdays } ?? true
        if timeChanged { schedule.armedAt = Date() }
        return ReviewSchedule.proposing(schedule, over: existing, by: by, sessionID: session)
    }

    /// `library.get`: what exists, without secrets nor the versions before.
    func libraryJSON() -> JSONValue {
        func plain<T: Encodable & Proposable>(_ item: T) -> JSONValue {
            var copy = item
            copy.proposal = nil
            var object = Self.libraryJSONValue(copy).objectValue ?? [:]
            object["proposed"] = .bool(item.isProposed)
            return .object(object)
        }
        let projectID = selectedProject ?? projects.first?.id
        let catalog = projectID.map { skills(forProject: $0) }
            ?? SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory, projectDirectory: nil)
        let object: [String: JSONValue] = [
            "workflows": .array(workflows.workflows.map { workflow in
                .object(["id": .string(workflow.id.uuidString), "name": .string(workflow.name),
                         "summary": .string(workflow.summary), "tags": .array(workflow.tags.map(JSONValue.string)),
                         "steps": .number(Double(workflow.nodes.count)), "proposed": .bool(workflow.isProposed)])
            }),
            "experts": .array(workflows.experts.map(plain)),
            "blocks": .array(workflows.blocks.map(plain)),
            "ruleSets": .array(workflows.ruleSets.map(plain)),
            "connectors": .array(workflows.connectors.map { connector in
                .object(["id": .string(connector.id.uuidString), "name": .string(connector.name),
                         "kind": .string(ConnectorEditor.kindLabel(connector.kind))])
            }),
            "schedules": .array(reviewSchedules.schedules.map { schedule in
                .object(["id": .string(schedule.id.uuidString), "name": .string(schedule.name),
                         "enabled": .bool(schedule.enabled), "hour": .number(Double(schedule.hour)),
                         "minute": .number(Double(schedule.minute)),
                         "weekdays": .array(schedule.weekdays.sorted().map { .number(Double($0)) }),
                         "targets": .array(schedule.targets.map { target in
                             .object(["projectID": .string(target.projectID.rawValue.uuidString),
                                      "query": .string(target.query), "limit": .number(Double(target.limit))])
                         }),
                         "workflowID": schedule.workflowID.map { .string($0.uuidString) } ?? .null,
                         "proposed": .bool(schedule.isProposed)])
            }),
            "projects": .array(projects.map { project in
                .object(["id": .string(project.id.rawValue.uuidString), "name": .string(project.name)])
            }),
            "skills": .array(catalog.map { .string($0.name) }),
            "themes": .array(ThemeStore.shared.families.map { .string($0.name) }),
            "reportTemplates": .array(ArtifactRenderer.templates.map { .string($0.id) }),
            "proposalsWaiting": .number(Double(workflows.libraryProposalCount + proposedReviewSchedules.count)),
        ]
        return .object(object)
    }
}
