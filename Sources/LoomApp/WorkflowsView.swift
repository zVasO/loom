import AppKit
import LoomCore
import LoomUI
import LoomWeb
import LoomWorkflows
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Workflows tab (ADR-0017, ADR-0021): on the left the workflows, their
/// runs, and — folded — what they are made of (experts, rule sets,
/// connectors); beside it the templates to start from, the React Flow
/// editor, a run as the list of its steps (or on its graph), its report, or
/// an expert's or a connector's form.
struct WorkflowsView: View {
    let model: AppModel
    /// Opens a step's session in the Sessions tab.
    let onOpenSession: (SessionID) -> Void

    private var workflows: WorkflowsModel { model.workflows }
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var query = ""
    @State private var message: String?
    /// Experts, rules and connectors: what workflows are made of, folded
    /// until someone wants to look under the hood.
    @AppStorage("loom.workflows.libraryOpen") private var libraryOpen = false
    /// A watched run shows as a list of steps, or on the graph.
    @AppStorage("loom.workflows.runAsGraph") private var runAsGraph = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
                .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DefaultTheme.contentBackground)
        }
        .sheet(item: Binding(get: { workflows.launchRequest }, set: { workflows.launchRequest = $0 })) { request in
            WorkflowLaunchSheet(model: model, request: request)
        }
        .onChange(of: workflows.selectedWorkflowID) { model.emitEditorState() }
        .onChange(of: workflows.detail) { model.emitEditorState() }
        .onChange(of: workflows.libraryGeneration) { model.emitEditorLibrary() }
        .onChange(of: watchedRunState) { model.emitEditorRun() }
        .onReceive(NotificationCenter.default.publisher(for: .loomThemeChanged)) { _ in model.emitEditorLibrary() }
    }

    /// What the editor repaints when a watched run moves.
    /// What the editor paints of a run: its steps, and what the orchestrator did.
    private struct WatchedRun: Equatable {
        var state: RunState
        var messages: Int
        var holding: Bool
    }

    private var watchedRunState: WatchedRun? {
        guard case .run(let id) = workflows.detail, let run = workflows.run(id) else { return nil }
        return WatchedRun(state: run.state, messages: run.messages.count, holding: workflows.holding.contains(id))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DefaultTheme.space(6)) {
                AppIcon("magnifyingglass", size: 13).foregroundStyle(DefaultTheme.mutedText)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                    .themeFont(size: 12)
            }
            .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(7))
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .padding(DefaultTheme.space(12))
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DefaultTheme.space(16)) {
                    proposalsSection
                    workflowsSection
                    runsSection
                    librarySection
                }
                .padding(DefaultTheme.space(12))
            }
            Divider().overlay(DefaultTheme.cardBorder)
            settingsFooter
        }
    }

    private func header<Trailing: View>(_ title: String, systemImage: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: DefaultTheme.space(6)) {
            AppIcon(systemImage, size: 11)
            Text(title).themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
            Spacer()
            trailing()
        }
        .foregroundStyle(DefaultTheme.mutedText)
        .padding(.horizontal, DefaultTheme.space(2))
    }

    private func matches(_ text: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// What agents proposed (ADR-0020): nothing of it runs before you validate.
    @ViewBuilder
    private var proposalsSection: some View {
        let items = model.pendingProposals
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
                header("TO REVIEW · \(items.count)", systemImage: "checkmark.seal") { EmptyView() }
                Text("Proposed by agents: none of it runs or fires before you validate it.")
                    .themeFont(size: 10).foregroundStyle(DefaultTheme.mutedText)
                ForEach(items) { item in
                    proposalRow(item)
                }
            }
        }
    }

    private func proposalRow(_ item: AppModel.ProposalItem) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
            HStack(spacing: DefaultTheme.space(6)) {
                Text(item.kind.uppercased())
                    .themeFont(size: 9, weight: .bold, kerning: 0.6)
                    .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                Text(item.title).themeFont(size: 12, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText).lineLimit(1)
            }
            Text("by \(item.by) · " + item.at.formatted(.relative(presentation: .named)))
                .themeFont(size: 10).foregroundStyle(DefaultTheme.mutedText).lineLimit(1)
            ForEach(Array(item.changes.prefix(5).enumerated()), id: \.offset) { _, change in
                Text((change.flagged ? "⚠︎ " : "· ") + change.text)
                    .themeFont(size: 10)
                    .foregroundStyle(change.flagged ? DefaultTheme.danger : DefaultTheme.secondaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if item.changes.count > 5 {
                Text("… \(item.changes.count - 5) more").themeFont(size: 10).foregroundStyle(DefaultTheme.mutedText)
            }
            HStack(spacing: DefaultTheme.space(6)) {
                AccentButton("Validate", systemImage: "checkmark") { model.validateProposal(item.ref) }
                GhostButton("Revert", systemImage: "arrow.uturn.backward") { model.revertProposal(item.ref) }
                    .help("Back to the version you validated — or delete what the agent created")
                GhostButton("Open", systemImage: "eye") { model.openProposal(item.ref) }
            }
            .controlSize(.small)
        }
        .padding(DefaultTheme.space(9))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.badgeColor(for: .needsInput).opacity(0.5), lineWidth: 1))
    }

    private var workflowsSection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            header("WORKFLOWS", systemImage: "point.3.connected.trianglepath.dotted") {
                Menu {
                    Section("From a template") {
                        ForEach(WorkflowTemplates.all) { template in
                            Button(template.name) { customize(template) }
                        }
                    }
                    Button("Browse the templates…") { workflows.detail = .gallery }
                    Divider()
                    Button("✦ Create with AI…") { Task { await model.startWorkflowBuilder() } }
                    Button("Blank workflow") {
                        workflows.createWorkflow()
                        workflows.detail = .workflow
                    }
                    Button("Import…") { importWorkflow() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New workflow: from a template, with AI, blank, or imported")
            }
            if let message {
                Text(message).themeFont(size: 11).foregroundStyle(DefaultTheme.danger)
            }
            if workflows.workflows.isEmpty {
                Button { workflows.detail = .gallery } label: {
                    Text("No workflow yet — start from a template.")
                        .themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(workflows.workflows.filter { matches($0.name, $0.summary, $0.tags.joined(separator: " ")) }) { workflow in
                workflowRow(workflow)
            }
        }
    }

    private func workflowRow(_ workflow: Workflow) -> some View {
        let selected = workflows.selectedWorkflowID == workflow.id && workflows.detail == .workflow
        let last = workflows.lastRun(of: workflow.id)
        return HStack(alignment: .top, spacing: DefaultTheme.space(8)) {
            Circle().fill(AppModel.color(hex: workflow.color)).frame(width: 8, height: 8).padding(.top, DefaultTheme.space(5))
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                if renaming == workflow.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .themeFont(size: 12, weight: .semibold)
                        .onSubmit { commitRename(workflow.id) }
                        .onExitCommand { renaming = nil }
                } else {
                    HStack(spacing: DefaultTheme.space(6)) {
                        Text(workflow.name)
                            .themeFont(size: 12, weight: .semibold)
                            .foregroundStyle(DefaultTheme.primaryText)
                            .lineLimit(1)
                        if workflow.isProposed { ProposedTag() }
                    }
                }
                if !workflow.summary.isEmpty {
                    Text(workflow.summary).themeFont(size: 10).foregroundStyle(DefaultTheme.secondaryText).lineLimit(2)
                }
                HStack(spacing: DefaultTheme.space(6)) {
                    Text(workflow.workspace == .worktree ? "own branch" : "\(max(0, workflow.nodes.count - 1)) steps")
                    if let last {
                        Text("·")
                        Text(RunStatusLabel.text(last.status) + " " + last.startedAt.formatted(.relative(presentation: .named)))
                    }
                }
                .themeFont(size: 10)
                .foregroundStyle(DefaultTheme.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DefaultTheme.space(9)).padding(.vertical, DefaultTheme.space(7))
        .background(selected ? DefaultTheme.surfaceRaised : DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
            .stroke(selected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(workflow) }
        .onTapGesture {
            workflows.selectedWorkflowID = workflow.id
            workflows.detail = .workflow
        }
        .contextMenu {
            Button("Run…") { workflows.launchRequest = .init(workflowID: workflow.id, inputs: nil) }
            Button("✦ Improve with AI…") { Task { await model.startWorkflowBuilder(improving: workflow.id) } }
            Button("Rename") { startRename(workflow) }
            Button("Duplicate") {
                workflows.duplicate(workflow.id)
                workflows.detail = .workflow
            }
            Button("Export…") { exportWorkflow(workflow) }
            Divider()
            Button("Delete", role: .destructive) { workflows.deleteWorkflow(workflow.id) }
        }
    }

    private func startRename(_ workflow: Workflow) {
        renameText = workflow.name
        renaming = workflow.id
    }

    private func commitRename(_ id: UUID) {
        workflows.rename(id, to: renameText)
        renaming = nil
        // The editor holds the workflow it shows: it must take the new
        // name, or its next save would write the old one back.
        if workflows.selectedWorkflowID == id { model.emitEditorState() }
    }

    /// Templates (ADR-0021): into the library, then the Run sheet or the editor.
    private func run(_ template: WorkflowTemplate) {
        guard let workflow = workflows.useTemplate(template) else { return }
        workflows.detail = .workflow
        workflows.launchRequest = .init(workflowID: workflow.id, inputs: nil)
    }

    private func customize(_ template: WorkflowTemplate) {
        guard workflows.useTemplate(template) != nil else { return }
        workflows.detail = .workflow
    }

    /// What workflows are made of — experts, rule sets, connectors — behind
    /// one fold: a template brings its own, most people never open it.
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(12)) {
            Button { libraryOpen.toggle() } label: {
                HStack(spacing: DefaultTheme.space(6)) {
                    AppIcon(libraryOpen ? "chevron.down" : "chevron.right", size: 10)
                    Text("LIBRARY").themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
                    Text("\(workflows.experts.count) experts · \(workflows.ruleSets.count) rules · \(workflows.connectors.count) connectors")
                        .themeFont(size: 10)
                    Spacer()
                }
                .foregroundStyle(DefaultTheme.mutedText)
                .padding(.horizontal, DefaultTheme.space(2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Experts, rule sets and connectors: what the steps of your workflows use")
            if libraryOpen || !query.trimmingCharacters(in: .whitespaces).isEmpty {
                expertsSection
                rulesSection
                connectorsSection
            }
        }
    }

    private var expertsSection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            header("EXPERTS", systemImage: "person.crop.circle.badge.checkmark") {
                HoverIconButton(systemImage: "plus", help: "New expert") {
                    let expert = workflows.createExpert()
                    workflows.detail = .expert(expert.id)
                }
            }
            ForEach(workflows.experts.filter { matches($0.name, $0.domain) }) { expert in
                simpleRow(title: expert.name, subtitle: expert.domain, color: expert.color,
                          selected: workflows.detail == .expert(expert.id)) {
                    workflows.detail = .expert(expert.id)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        workflows.deleteExpert(expert.id)
                        if workflows.detail == .expert(expert.id) { workflows.detail = .workflow }
                    }
                }
            }
        }
    }

    /// Rule sets to tick on blocks, steps and links (ADR-0019).
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            header("RULES", systemImage: "list.bullet.rectangle") {
                HoverIconButton(systemImage: "plus", help: "New rule set") {
                    let ruleSet = workflows.createRuleSet()
                    workflows.detail = .ruleSet(ruleSet.id)
                    model.emitEditorLibrary()
                }
            }
            ForEach(workflows.ruleSets.filter { matches($0.name, $0.rules.joined(separator: " ")) }) { ruleSet in
                simpleRow(title: ruleSet.name, subtitle: "\(ruleSet.rules.filter { !$0.isEmpty }.count) rule(s)",
                          color: nil, selected: workflows.detail == .ruleSet(ruleSet.id)) {
                    workflows.detail = .ruleSet(ruleSet.id)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        workflows.deleteRuleSet(ruleSet.id)
                        model.emitEditorLibrary()
                        if workflows.detail == .ruleSet(ruleSet.id) { workflows.detail = .workflow }
                    }
                }
            }
        }
    }

    private var connectorsSection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            header("CONNECTORS", systemImage: "cable.connector") {
                Menu {
                    Button("Atlassian — the server in your Claude Code") { addConnector(.atlassianRemote()) }
                    Button("Atlassian — mcp-atlassian with an API token") { addConnector(.atlassianStdio()) }
                    Divider()
                    Button("MCP server — a command") {
                        addConnector(Connector(name: "New server", kind: .mcpStdio(command: "", args: [], env: [:])))
                    }
                    Button("MCP server — over HTTP") {
                        addConnector(Connector(name: "New server", kind: .mcpHTTP(url: "https://", headers: [:])))
                    }
                    Button("MCP server — already in your Claude Code") {
                        addConnector(Connector(name: "New server", kind: .claudeConfigured(server: "")))
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a connector")
            }
            ForEach(workflows.connectors.filter { matches($0.name) }) { connector in
                simpleRow(title: connector.name, subtitle: ConnectorEditor.kindLabel(connector.kind), color: nil,
                          selected: workflows.detail == .connector(connector.id)) {
                    workflows.detail = .connector(connector.id)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        workflows.deleteConnector(connector.id)
                        if workflows.detail == .connector(connector.id) { workflows.detail = .workflow }
                    }
                }
            }
        }
    }

    private func addConnector(_ connector: Connector) {
        let added = workflows.addConnector(connector)
        workflows.detail = .connector(added.id)
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            header("RUNS", systemImage: "clock.arrow.circlepath") { EmptyView() }
            if workflows.runs.isEmpty {
                Text("No run yet.").themeFont(size: 11).foregroundStyle(DefaultTheme.mutedText)
            }
            ForEach(workflows.runs.prefix(40).filter { matches($0.workflow.name, $0.subject) }) { run in
                runRow(run)
            }
        }
    }

    private func runRow(_ run: WorkflowRun) -> some View {
        let selected: Bool = {
            switch workflows.detail {
            case .run(let id), .report(let id): return id == run.id
            default: return false
            }
        }()
        return HStack(alignment: .top, spacing: DefaultTheme.space(8)) {
            Image(systemName: RunStatusLabel.symbol(run.status))
                .font(.system(size: 11))
                .foregroundStyle(RunStatusLabel.color(run.status))
                .frame(width: 14)
                .padding(.top, DefaultTheme.space(1))
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                // What it was about first: two runs of one workflow differ by their task.
                Text(run.subject == "Manual run" ? run.workflow.name : run.subject)
                    .themeFont(size: 12, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText).lineLimit(1)
                Text(run.subject == "Manual run" ? run.subject : run.workflow.name)
                    .themeFont(size: 10).foregroundStyle(DefaultTheme.secondaryText).lineLimit(1)
                if let worktree = run.worktree {
                    Text(worktree.branch + (run.changes.map { " · " + $0.summary } ?? ""))
                        .themeFont(size: 10, design: .monospaced)
                        .foregroundStyle(DefaultTheme.branch).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: DefaultTheme.space(6)) {
                    Text(run.startedAt.formatted(.relative(presentation: .named)))
                    if run.costUSD > 0 { Text(String(format: "%.2f $", run.costUSD)) }
                    if !workflows.approvals(of: run.id).isEmpty {
                        Text("· your decision").foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                    }
                }
                .themeFont(size: 10)
                .foregroundStyle(DefaultTheme.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DefaultTheme.space(9)).padding(.vertical, DefaultTheme.space(7))
        .background(selected ? DefaultTheme.surfaceRaised : DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
            .stroke(selected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { workflows.detail = .run(run.id) }
        .contextMenu {
            if run.artifactPath != nil { Button("Open the report") { workflows.detail = .report(run.id) } }
            if run.status.isActive { Button("Stop") { model.stopWorkflowRun(run.id) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workflows.folder(for: run.id)]) }
            if !run.status.isActive {
                Divider()
                Button("Delete", role: .destructive) {
                    workflows.deleteRun(run.id)
                    if selected { workflows.detail = .workflow }
                }
            }
        }
    }

    private func simpleRow(title: String, subtitle: String, color: String?, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: DefaultTheme.space(8)) {
            if let color { Circle().fill(AppModel.color(hex: color)).frame(width: 8, height: 8) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).themeFont(size: 12, weight: .semibold).foregroundStyle(DefaultTheme.primaryText).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).themeFont(size: 10).foregroundStyle(DefaultTheme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DefaultTheme.space(9)).padding(.vertical, DefaultTheme.space(6))
        .background(selected ? DefaultTheme.surfaceRaised : DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
            .stroke(selected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private var settingsFooter: some View {
        HStack(spacing: DefaultTheme.space(10)) {
            Stepper(value: Binding(get: { workflows.maxConcurrent }, set: { workflows.maxConcurrent = $0 }), in: 1...8) {
                Text("\(workflows.maxConcurrent) at once").themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
            }
            .fixedSize()
            .help("Steps of one run running at the same time")
            Spacer()
            Picker("", selection: Binding(get: { workflows.defaultModel }, set: { workflows.defaultModel = $0 })) {
                Text("Opus").tag("opus")
                Text("Sonnet").tag("sonnet")
                Text("Haiku").tag("haiku")
            }
            .labelsHidden()
            .fixedSize()
            .help("The model of a step whose expert names none")
        }
        .padding(DefaultTheme.space(12))
    }

    // MARK: Import / export

    private func exportWorkflow(_ workflow: Workflow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = workflow.name.replacingOccurrences(of: "/", with: "-") + ".loom-workflow.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try workflows.exportBundle(workflow.id).write(to: url, options: .atomic)
            message = nil
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importWorkflow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try workflows.importBundle(Data(contentsOf: url))
            workflows.detail = .workflow
            message = nil
        } catch {
            message = "This file is not a Loom workflow."
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch workflows.detail {
        case .gallery:
            gallery
        case .workflow:
            if workflows.workflow(workflows.selectedWorkflowID) == nil {
                gallery
            } else {
                editor
            }
        case .run(let id):
            if let run = workflows.run(id) {
                VStack(spacing: 0) {
                    RunHeader(model: model, run: run, asGraph: $runAsGraph)
                    ForEach(workflows.approvals(of: run.id)) { approval in
                        ApprovalBanner(model: model, approval: approval).id(approval.id)
                    }
                    Divider().overlay(DefaultTheme.cardBorder)
                    if runAsGraph {
                        editor
                    } else {
                        RunTimelineView(model: model, run: run).id(run.id)
                    }
                }
            }
        case .report(let id):
            if let run = workflows.run(id), let path = run.artifactPath {
                VStack(spacing: 0) {
                    RunHeader(model: model, run: run, asGraph: $runAsGraph)
                    Divider().overlay(DefaultTheme.cardBorder)
                    ArtifactWebView(url: URL(fileURLWithPath: path))
                }
            }
        case .expert(let id):
            ExpertEditor(model: model, expertID: id).id(id)
        case .connector(let id):
            ConnectorEditor(model: model, connectorID: id).id(id)
        case .ruleSet(let id):
            RuleSetEditor(model: model, ruleSetID: id).id(id)
                .onDisappear { model.emitEditorLibrary() }
        }
    }

    private var editor: some View {
        ExtensionWebView(webView: model.workflowEditorHost().webView)
            .onAppear { model.emitEditorState() }
    }

    private var gallery: some View {
        WorkflowGalleryView(model: model, onRun: run(_:), onCustomize: customize(_:), onImport: importWorkflow)
    }
}

// MARK: - Run status

@MainActor
enum RunStatusLabel {
    static func text(_ status: WorkflowRun.Status) -> String {
        switch status {
        case .running: "running"
        case .succeeded: "done"
        case .failed: "failed"
        case .cancelled: "stopped"
        case .interrupted: "interrupted"
        }
    }

    static func symbol(_ status: WorkflowRun.Status) -> String {
        switch status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        case .interrupted: "exclamationmark.circle"
        }
    }

    static func color(_ status: WorkflowRun.Status) -> Color {
        switch status {
        case .running: DefaultTheme.badgeColor(for: .working)
        case .succeeded: DefaultTheme.badgeColor(for: .idle)
        case .failed: DefaultTheme.danger
        case .cancelled, .interrupted: DefaultTheme.mutedText
        }
    }
}

/// Above a watched run: where it stands, and what can be done with it.
private struct RunHeader: View {
    let model: AppModel
    let run: WorkflowRun
    /// The run as its graph rather than as the list of its steps.
    @Binding var asGraph: Bool
    @State private var logShown = false

    var body: some View {
        let workflows = model.workflows
        HStack(spacing: DefaultTheme.space(10)) {
            Image(systemName: RunStatusLabel.symbol(run.status)).foregroundStyle(RunStatusLabel.color(run.status))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(run.workflow.name) · \(run.subject)")
                    .themeFont(size: 13, weight: .semibold).foregroundStyle(DefaultTheme.primaryText)
                Text(subtitle).themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText).lineLimit(2)
            }
            Spacer()
            if workflows.holding.contains(run.id) {
                Text("Waiting for the orchestrator")
                    .themeFont(size: 11, weight: .medium).foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
            }
            if run.status.isActive {
                ProgressView().controlSize(.small)
                GhostButton("Stop", systemImage: "stop.fill") { model.stopWorkflowRun(run.id) }
            }
            if let raw = run.orchestratorSessionID, let uuid = UUID(uuidString: raw) {
                GhostButton("Orchestrator", systemImage: "person.wave.2") {
                    workflows.sessionToOpen = SessionID(uuid)
                }
                .help("Open the run's orchestrator in Sessions: talk to it there")
            }
            if workflows.detail == .report(run.id) {
                GhostButton("Steps", systemImage: "list.bullet") { workflows.detail = .run(run.id) }
                GhostButton("Open in browser", systemImage: "safari") {
                    if let path = run.artifactPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            } else {
                GhostButton(asGraph ? "Steps" : "Graph",
                            systemImage: asGraph ? "list.bullet" : "point.3.connected.trianglepath.dotted") {
                    asGraph.toggle()
                }
                .help(asGraph ? "The run as a list: each step, its verdict, its answer"
                      : "The run on the workflow's graph")
                if run.artifactPath != nil {
                    AccentButton("Report", systemImage: "doc.richtext") { workflows.detail = .report(run.id) }
                }
            }
            GhostButton("Log", systemImage: "text.alignleft") { logShown.toggle() }
                .popover(isPresented: $logShown) {
                    ScrollView {
                        Text((try? String(contentsOf: workflows.folder(for: run.id).appendingPathComponent("log.txt"),
                                          encoding: .utf8)) ?? "No log yet.")
                            .themeFont(size: 11, design: .monospaced)
                            .textSelection(.enabled)
                            .padding(DefaultTheme.space(12))
                    }
                    .frame(width: 560, height: 360)
                }
            HoverIconButton(systemImage: "folder", help: "Reveal the run's folder in the Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([workflows.folder(for: run.id)])
            }
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(9))
        .background(DefaultTheme.background)
    }

    private var subtitle: String {
        var parts = ["started " + run.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let end = run.finishedAt {
            let seconds = Int(end.timeIntervalSince(run.startedAt))
            parts.append("\(seconds / 60) min \(seconds % 60) s")
        }
        if run.costUSD > 0 { parts.append(String(format: "%.2f $", run.costUSD)) }
        if run.workflow.orchestrator != nil, run.interventions > 0 {
            parts.append("\(run.interventions) intervention(s) of the orchestrator")
        }
        if let error = run.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}

/// A run's report, as written: its own folder, the theme's fonts.
struct ArtifactWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url?.standardizedFileURL != url.standardizedFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

/// "proposed": an agent's change awaiting your validation (ADR-0020).
struct ProposedTag: View {
    var body: some View {
        Text("proposed")
            .themeFont(size: 9, weight: .bold)
            .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
            .padding(.horizontal, DefaultTheme.space(5)).padding(.vertical, DefaultTheme.space(1))
            .overlay(Capsule().stroke(DefaultTheme.badgeColor(for: .needsInput).opacity(0.6), lineWidth: 1))
            .help("Proposed by an agent: validate it in To review before it can run")
    }
}
