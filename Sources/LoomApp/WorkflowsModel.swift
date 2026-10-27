import Foundation
import LoomAPI
import LoomCore
import LoomExtensions
import LoomWorkflows
import Observation

/// The Workflows tab's state (ADR-0017): the library — workflows, experts,
/// connectors, on disk under `<support>/workflows/` — and the runs, under
/// `<support>/workflow-runs/`. Running one is `AppModel`'s (WorkflowRunner.swift):
/// it needs the sessions, the PRs and claude.
@MainActor
@Observable
final class WorkflowsModel {
    let store: WorkflowLibraryStore
    let runStore: WorkflowRunStore
    /// Connector secrets: the Keychain, under `connector.<id>` — the same
    /// store as the extensions', its own namespace.
    @ObservationIgnored let secrets: SecretStore

    private(set) var workflows: [Workflow] = []
    private(set) var experts: [Expert] = []
    private(set) var connectors: [Connector] = []
    /// Newest first.
    private(set) var runs: [WorkflowRun] = []
    /// The workflow open in the editor.
    var selectedWorkflowID: UUID?
    /// The run whose progress the editor paints, when one is shown.
    var selectedRunID: UUID?
    /// Bumped on every library change: the editor reloads on it.
    private(set) var libraryGeneration = 0
    /// A connector test's answer, by connector.
    var connectorTestResults: [UUID: String] = [:]
    var connectorTesting: Set<UUID> = []

    /// Running runs' tasks — cancelled by Stop.
    @ObservationIgnored var runTasks: [UUID: Task<Void, Never>] = [:]

    /// What the Workflows tab shows beside its sidebar.
    enum Detail: Equatable {
        case workflow
        case run(UUID)
        case report(UUID)
        case expert(UUID)
        case connector(UUID)
    }
    var detail: Detail = .workflow

    /// The Run sheet, when it is asked for: which workflow, with what inputs
    /// already known (a PR's tab knows its PR).
    struct LaunchRequest: Identifiable, Equatable {
        let id = UUID()
        var workflowID: UUID?
        var inputs: RunInputs?
    }
    var launchRequest: LaunchRequest?
    /// A step's session the user asked to see — the tab opens it in Sessions.
    var sessionToOpen: SessionID?
    /// Bumped to bring the Workflows tab to the front (a PR's tab started a run).
    var revealRequest: UUID?
    /// The editor's page, kept across tab switches.
    @ObservationIgnored var editorHost: WorkflowEditorHost?

    init(supportDirectory: URL, secrets: SecretStore = KeychainSecretStore()) {
        store = WorkflowLibraryStore(directory: supportDirectory.appendingPathComponent("workflows"))
        runStore = WorkflowRunStore(directory: supportDirectory.appendingPathComponent("workflow-runs"))
        self.secrets = secrets
    }

    // MARK: Settings

    /// Steps running at once in one run.
    var maxConcurrent: Int {
        get { max(1, min(UserDefaults.standard.object(forKey: "loom.workflows.concurrency") as? Int ?? 3, 8)) }
        set { UserDefaults.standard.set(max(1, min(newValue, 8)), forKey: "loom.workflows.concurrency") }
    }

    /// The model a step runs on when neither it nor its expert names one.
    var defaultModel: String {
        get { UserDefaults.standard.string(forKey: "loom.workflows.defaultModel") ?? "sonnet" }
        set { UserDefaults.standard.set(newValue, forKey: "loom.workflows.defaultModel") }
    }

    // MARK: Loading

    /// Reads the library, seeding it with the built-ins the first time.
    func load() {
        if !store.exists {
            for expert in BuiltInWorkflows.experts { try? store.save(expert) }
            for connector in BuiltInWorkflows.connectors { try? store.save(connector) }
            try? store.save(BuiltInWorkflows.prReview())
        }
        reload()
        runs = runStore.load()
        // A run cut short by a quit is saved as such, once.
        for run in runs where run.status == .interrupted { try? runStore.save(run) }
        if selectedWorkflowID == nil { selectedWorkflowID = workflows.first?.id }
    }

    private func reload() {
        workflows = store.loadWorkflows().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        experts = store.loadExperts().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        connectors = store.loadConnectors().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        libraryGeneration += 1
    }

    func workflow(_ id: UUID?) -> Workflow? { workflows.first { $0.id == id } }
    func expert(_ id: UUID?) -> Expert? { experts.first { $0.id == id } }
    func connector(_ id: UUID?) -> Connector? { connectors.first { $0.id == id } }
    func run(_ id: UUID?) -> WorkflowRun? { runs.first { $0.id == id } }

    /// The last run of a workflow, for the library's row.
    func lastRun(of workflowID: UUID) -> WorkflowRun? { runs.first { $0.workflow.id == workflowID } }

    // MARK: Workflows

    @discardableResult
    func createWorkflow(name: String = "Nouveau workflow") -> Workflow {
        var workflow = Workflow(name: uniqueName(name),
                                nodes: [WorkflowNode(id: "start", title: "Démarrage",
                                                     position: Position(x: 0, y: 200),
                                                     kind: .start(StartConfig()))])
        workflow.updatedAt = Date()
        save(workflow)
        selectedWorkflowID = workflow.id
        return workflow
    }

    func save(_ workflow: Workflow) {
        var workflow = workflow
        workflow.updatedAt = Date()
        try? store.save(workflow)
        reload()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var workflow = workflow(id), !trimmed.isEmpty, trimmed != workflow.name else { return }
        workflow.name = trimmed
        save(workflow)
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Workflow? {
        guard var copy = workflow(id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " (copie)")
        copy.createdAt = Date()
        save(copy)
        selectedWorkflowID = copy.id
        return copy
    }

    func deleteWorkflow(_ id: UUID) {
        store.deleteWorkflow(id)
        if selectedWorkflowID == id { selectedWorkflowID = nil }
        reload()
        if selectedWorkflowID == nil { selectedWorkflowID = workflows.first?.id }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(workflows.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: Import / export

    func exportBundle(_ id: UUID) throws -> Data {
        guard let workflow = workflow(id) else { throw CocoaError(.fileNoSuchFile) }
        return try WorkflowBundle.make(workflow, experts: experts, connectors: connectors).encoded()
    }

    /// A bundle (or a bare workflow) becomes a new workflow; its experts and
    /// connectors join the library unless the library already has them.
    @discardableResult
    func importBundle(_ data: Data) throws -> Workflow {
        let bundle = try WorkflowBundle.decode(data)
        for expert in bundle.experts where self.expert(expert.id) == nil { try? store.save(expert) }
        for connector in bundle.connectors where self.connector(connector.id) == nil { try? store.save(connector) }
        var workflow = bundle.workflow
        if self.workflow(workflow.id) != nil { workflow.id = UUID() }
        workflow.name = uniqueName(workflow.name)
        save(workflow)
        selectedWorkflowID = workflow.id
        return workflow
    }

    // MARK: Experts

    func save(_ expert: Expert) {
        try? store.save(expert)
        reload()
    }

    @discardableResult
    func createExpert() -> Expert {
        let expert = Expert(name: "Nouvel expert", domain: "",
                            systemPrompt: "You are an expert in … Stay in your domain. Write in French.")
        save(expert)
        return expert
    }

    func deleteExpert(_ id: UUID) {
        store.deleteExpert(id)
        reload()
    }

    // MARK: Connectors

    func save(_ connector: Connector) {
        try? store.save(connector)
        reload()
    }

    @discardableResult
    func addConnector(_ connector: Connector) -> Connector {
        var connector = connector
        if self.connector(connector.id) != nil { connector.id = UUID() }
        save(connector)
        return connector
    }

    func deleteConnector(_ id: UUID) {
        try? secrets.deleteAll(for: Self.secretNamespace(id))
        store.deleteConnector(id)
        reload()
    }

    static func secretNamespace(_ id: UUID) -> String { "connector.\(id.uuidString)" }

    func secret(_ key: String, of connector: UUID) -> String? {
        (try? secrets.secret(key, for: Self.secretNamespace(connector))) ?? nil
    }

    func hasSecret(_ key: String, of connector: UUID) -> Bool {
        !(secret(key, of: connector) ?? "").isEmpty
    }

    func setSecret(_ value: String, _ key: String, of connector: UUID) {
        if value.isEmpty {
            try? secrets.deleteSecret(key, for: Self.secretNamespace(connector))
        } else {
            try? secrets.setSecret(value, key, for: Self.secretNamespace(connector))
        }
        libraryGeneration += 1
    }

    // MARK: Runs

    func record(_ run: WorkflowRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        try? runStore.save(run)
    }

    func deleteRun(_ id: UUID) {
        guard run(id)?.status.isActive != true else { return }
        runs.removeAll { $0.id == id }
        runStore.delete(id)
        if selectedRunID == id { selectedRunID = nil }
    }

    func log(_ line: String, run id: UUID) {
        runStore.log(line, run: id)
    }

    /// Where a run keeps its files: answers of visible steps, the artifact.
    func folder(for run: UUID) -> URL { runStore.folder(for: run) }

    // MARK: Orchestrator (ADR-0018)

    /// Runs waiting for their orchestrator: before the report, or before
    /// ending on a failure.
    var holding: Set<UUID> = []
    /// What the orchestrator asked of a run's loop, read between two steps.
    @ObservationIgnored var wakes: Set<UUID> = []
    @ObservationIgnored var stopRequests: [UUID: String] = [:]
    @ObservationIgnored var proceedRequests: Set<UUID> = []
    /// Lines for the orchestrator, typed together once its session is idle.
    @ObservationIgnored var pendingEvents: [UUID: [OrchestratorPrompt.Event]] = [:]
    @ObservationIgnored var eventDeliveries: [UUID: Task<Void, Never>] = [:]
    /// Questions being answered: one at a time per step.
    @ObservationIgnored var asking: Set<String> = []

    /// A session's part in a run: the newest run naming it as its
    /// orchestrator or as one of its steps' sessions.
    struct SessionPart {
        var runID: UUID
        var role: APIWorkflowRole
        /// The step, for a step's session.
        var step: String?
    }

    func part(of session: SessionID) -> SessionPart? {
        let id = session.rawValue.uuidString.lowercased()
        for run in runs {
            if run.orchestratorSessionID?.lowercased() == id {
                return SessionPart(runID: run.id, role: .orchestrator, step: nil)
            }
            if let step = run.step(ofSession: id) {
                return SessionPart(runID: run.id, role: .step, step: step)
            }
        }
        return nil
    }

    /// The run's loop looks at the orchestrator's requests now, not after
    /// the step it waits on.
    func wake(_ run: UUID) { wakes.insert(run) }

    /// Consumes a wake-up.
    func takeWake(_ run: UUID) -> Bool { wakes.remove(run) != nil }

    /// The Sessions tab's WORKFLOWS section: each run with an orchestrator or
    /// a visible step, newest first, its sessions in order — the
    /// orchestrator, then the steps as the workflow lists them.
    struct SessionGroup: Identifiable, Equatable {
        var id: UUID
        var title: String
        var isActive: Bool
        var orchestrator: SessionID?
        var steps: [SessionID]
    }

    var sessionGroups: [SessionGroup] {
        runs.compactMap { run -> SessionGroup? in
            let orchestrator = run.orchestratorSessionID.flatMap(UUID.init(uuidString:)).map(SessionID.init)
            let steps = run.stepSessionIDs.compactMap { UUID(uuidString: $0).map(SessionID.init) }
            guard orchestrator != nil || !steps.isEmpty else { return nil }
            return SessionGroup(id: run.id, title: "\(run.workflow.name) · \(run.subject)",
                                isActive: run.status.isActive, orchestrator: orchestrator, steps: steps)
        }
    }
}
