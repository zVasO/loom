import AppKit
import LoomAgents
import LoomCore
import LoomUI
import LoomWorkflows
import SwiftUI

@MainActor
private func formTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
        .foregroundStyle(DefaultTheme.secondaryText)
}

@MainActor
private func formHint(_ text: String) -> some View {
    Text(text).themeFont(size: 11).foregroundStyle(DefaultTheme.mutedText).fixedSize(horizontal: false, vertical: true)
}

private struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(10)) { content }
            .padding(DefaultTheme.space(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            .themeShadow(.sm, radius: 10)
    }
}

private struct MonoEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var body: some View {
        TextEditor(text: $text)
            .themeFont(size: 11, design: .monospaced)
            .foregroundStyle(DefaultTheme.primaryText)
            .scrollContentBackground(.hidden)
            .padding(DefaultTheme.space(8))
            .frame(minHeight: minHeight)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.fieldBorder, lineWidth: 1))
            .themeShadow(.xs, radius: 6)
    }
}

/// `#RRGGBB` ⇄ the system colour picker.
private func hexString(_ color: Color) -> String {
    let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? .gray
    return String(format: "#%02X%02X%02X", Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255),
                  Int(resolved.blueComponent * 255))
}

// MARK: - Expert

/// An expert: its domain, its instructions, its skills, connectors and tools.
struct ExpertEditor: View {
    let model: AppModel
    let expertID: UUID
    @State private var draft: Expert?
    @State private var toolsText = ""

    private var workflows: WorkflowsModel { model.workflows }

    var body: some View {
        ScrollView {
            if let draft {
                content(draft)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(DefaultTheme.space(28))
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            draft = workflows.expert(expertID)
            toolsText = (draft?.allowedTools ?? []).joined(separator: "\n")
        }
        .onChange(of: draft) {
            // Validating is a button of its own: an edit keeps a proposal a proposal.
            if var draft {
                draft.proposal = workflows.expert(expertID)?.proposal
                workflows.save(draft)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Expert, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: keyPath] }, set: { draft?[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private func content(_ expert: Expert) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(18)) {
            HStack(spacing: DefaultTheme.space(10)) {
                ColorPicker("", selection: Binding(get: { AppModel.color(hex: expert.color) },
                                                   set: { draft?.color = hexString($0) }), supportsOpacity: false)
                    .labelsHidden()
                TextField("Name", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .themeFont(size: 21, weight: .bold)
                    .foregroundStyle(DefaultTheme.primaryText)
            }
            FormCard {
                formTitle("Domain")
                TextField("PHP, Symfony, security…", text: binding(\.domain)).textFieldStyle(.roundedBorder)
                formTitle("Model")
                TextField("opus, sonnet, haiku, or a model id — empty: the workflows' default",
                          text: Binding(get: { expert.model ?? "" },
                                        set: { draft?.model = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            FormCard {
                formTitle("Instructions")
                formHint("Appended to claude's system prompt in every step this expert runs: who it is, what it looks at, what it leaves to others. English reads best; ask for the answers' language here.")
                MonoEditor(text: binding(\.systemPrompt), minHeight: 200)
            }
            FormCard {
                formTitle("Skills")
                formHint("Injected into each of its steps — a step can add more.")
                let catalog = skillCatalog
                if catalog.isEmpty {
                    formHint("No skill found in ~/.claude/skills or the selected project.")
                }
                ForEach(catalog, id: \.name) { skill in
                    Toggle(isOn: Binding(get: { expert.skills.contains(skill.name) }, set: { on in
                        if on { draft?.skills.append(skill.name) } else { draft?.skills.removeAll { $0 == skill.name } }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name).themeFont(size: 12, weight: .semibold)
                            if !skill.description.isEmpty {
                                Text(skill.description).themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            FormCard {
                formTitle("Connectors")
                if workflows.connectors.isEmpty { formHint("No connector yet: add one in the sidebar.") }
                ForEach(workflows.connectors) { connector in
                    Toggle(connector.name, isOn: Binding(get: { expert.connectorIDs.contains(connector.id) }, set: { on in
                        if on { draft?.connectorIDs.append(connector.id) } else { draft?.connectorIDs.removeAll { $0 == connector.id } }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
            FormCard {
                HStack {
                    formTitle("Tools it may use")
                    Spacer()
                    GhostButton("Read-only set", systemImage: "arrow.counterclockwise") {
                        toolsText = Expert.readOnlyTools.joined(separator: "\n")
                    }
                }
                formHint("Claude Code permission rules, one per line (Read, Bash(git diff:*), mcp__server__*…). A headless step has nobody to answer a prompt: what is not here is refused. Its connectors' tools are added on their own.")
                MonoEditor(text: $toolsText, minHeight: 140)
                    .onChange(of: toolsText) {
                        draft?.allowedTools = toolsText.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            }
            GhostButton("Delete this expert", systemImage: "trash", role: .destructive) {
                workflows.deleteExpert(expertID)
                workflows.detail = .workflow
            }
        }
    }

    private var skillCatalog: [SkillEntry] {
        if let project = model.selectedProject { return model.skills(forProject: project) }
        return SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory, projectDirectory: nil)
    }
}

// MARK: - Connector

/// A connector: the server, its secrets (the Keychain), a test.
struct ConnectorEditor: View {
    let model: AppModel
    let connectorID: UUID
    @State private var draft: Connector?
    @State private var argsText = ""
    @State private var envText = ""
    @State private var secretValues: [String: String] = [:]
    @State private var newSecretKey = ""

    private var workflows: WorkflowsModel { model.workflows }

    static func kindLabel(_ kind: ConnectorKind) -> String {
        switch kind {
        case .mcpStdio: "MCP · command"
        case .mcpHTTP: "MCP · HTTP"
        case .claudeConfigured(let server): "Claude Code · \(server.isEmpty ? "?" : server)"
        }
    }

    var body: some View {
        ScrollView {
            if let draft {
                content(draft)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(DefaultTheme.space(28))
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: load)
        .onChange(of: draft) {
            if let draft { workflows.save(draft) }
        }
    }

    private func load() {
        draft = workflows.connector(connectorID)
        switch draft?.kind {
        case .mcpStdio(_, let args, let env)?:
            argsText = args.joined(separator: "\n")
            envText = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
        case .mcpHTTP(_, let headers)?:
            envText = headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
        default:
            break
        }
    }

    private static func pairs(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Every secret key the connector names or declares.
    private func secretKeys(_ connector: Connector) -> [String] {
        var keys = connector.secretKeys
        switch connector.kind {
        case .mcpStdio(let command, let args, let env):
            keys += ([command] + args + Array(env.values)).flatMap(SecretReference.keys(in:))
        case .mcpHTTP(let url, let headers):
            keys += ([url] + Array(headers.values)).flatMap(SecretReference.keys(in:))
        case .claudeConfigured:
            break
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func content(_ connector: Connector) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(18)) {
            TextField("Name", text: Binding(get: { connector.name }, set: { draft?.name = $0 }))
                .textFieldStyle(.plain)
                .themeFont(size: 21, weight: .bold)
                .foregroundStyle(DefaultTheme.primaryText)
            Text(Self.kindLabel(connector.kind) + " · tools as mcp__\(connector.serverKey)__…")
                .themeFont(size: 11, design: .monospaced).foregroundStyle(DefaultTheme.secondaryText)
            if !connector.notes.isEmpty { formHint(connector.notes) }
            FormCard { serverFields(connector) }
            if case .claudeConfigured = connector.kind {} else {
                FormCard { secretsSection(connector) }
            }
            FormCard {
                HStack {
                    formTitle("Test")
                    Spacer()
                    if workflows.connectorTesting.contains(connectorID) { ProgressView().controlSize(.small) }
                    GhostButton("Run a test", systemImage: "bolt.horizontal") {
                        Task { await model.testConnector(connectorID) }
                    }
                    .disabled(workflows.connectorTesting.contains(connectorID))
                }
                formHint("A short claude run with this connector alone: the tools it brings, and who Atlassian says you are.")
                if let result = workflows.connectorTestResults[connectorID] {
                    Text(result)
                        .themeFont(size: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .foregroundStyle(DefaultTheme.primaryText)
                        .padding(DefaultTheme.space(8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                }
            }
            GhostButton("Delete this connector", systemImage: "trash", role: .destructive) {
                workflows.deleteConnector(connectorID)
                workflows.detail = .workflow
            }
        }
    }

    @ViewBuilder
    private func serverFields(_ connector: Connector) -> some View {
        switch connector.kind {
        case .mcpStdio(let command, let args, let env):
            formTitle("Command")
            TextField("/opt/homebrew/bin/uvx", text: Binding(get: { command }, set: {
                draft?.kind = .mcpStdio(command: $0, args: args, env: env)
            }))
            .textFieldStyle(.roundedBorder)
            .themeFont(size: 12, design: .monospaced)
            formTitle("Arguments, one per line")
            MonoEditor(text: $argsText, minHeight: 70)
                .onChange(of: argsText) {
                    let lines = argsText.split(whereSeparator: \.isNewline).map(String.init)
                    if case .mcpStdio(let command, _, let env)? = draft?.kind {
                        draft?.kind = .mcpStdio(command: command, args: lines, env: env)
                    }
                }
            formTitle("Environment, KEY=value per line")
            formHint("Write {{secret:NAME}} for a value kept in the Keychain.")
            MonoEditor(text: $envText, minHeight: 90)
                .onChange(of: envText) {
                    if case .mcpStdio(let command, let args, _)? = draft?.kind {
                        draft?.kind = .mcpStdio(command: command, args: args, env: Self.pairs(envText, separator: "="))
                    }
                }
        case .mcpHTTP(let url, let headers):
            formTitle("URL")
            TextField("https://…", text: Binding(get: { url }, set: { draft?.kind = .mcpHTTP(url: $0, headers: headers) }))
                .textFieldStyle(.roundedBorder)
                .themeFont(size: 12, design: .monospaced)
            formTitle("Headers, Name: value per line")
            formHint("Write {{secret:NAME}} for a value kept in the Keychain — Authorization: Bearer {{secret:TOKEN}}.")
            MonoEditor(text: $envText, minHeight: 90)
                .onChange(of: envText) {
                    if case .mcpHTTP(let url, _)? = draft?.kind {
                        draft?.kind = .mcpHTTP(url: url, headers: Self.pairs(envText, separator: ":"))
                    }
                }
        case .claudeConfigured(let server):
            formTitle("Server name in your Claude Code")
            TextField("atlassian", text: Binding(get: { server }, set: { draft?.kind = .claudeConfigured(server: $0) }))
                .textFieldStyle(.roundedBorder)
                .themeFont(size: 12, design: .monospaced)
            formHint("As `claude mcp list` names it. For Atlassian: claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse, then /mcp in a session to sign in. Steps using it see your other servers too; only this one's tools are allowed.")
        }
    }

    @ViewBuilder
    private func secretsSection(_ connector: Connector) -> some View {
        formTitle("Secrets")
        formHint("Kept in the Keychain on this Mac, never in the workflow's file nor in an export.")
        ForEach(secretKeys(connector), id: \.self) { key in
            HStack(spacing: DefaultTheme.space(8)) {
                Text(key).themeFont(size: 12, design: .monospaced).frame(width: 170, alignment: .leading)
                SecureField(workflows.hasSecret(key, of: connectorID) ? "•••••• (set — type to replace)" : "not set",
                            text: Binding(get: { secretValues[key] ?? "" }, set: { secretValues[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                GhostButton("Save") {
                    workflows.setSecret(secretValues[key] ?? "", key, of: connectorID)
                    secretValues[key] = nil
                    if !(draft?.secretKeys.contains(key) ?? true) { draft?.secretKeys.append(key) }
                }
                .disabled((secretValues[key] ?? "").isEmpty)
                if workflows.hasSecret(key, of: connectorID) {
                    HoverIconButton(systemImage: "xmark", help: "Forget this secret") {
                        workflows.setSecret("", key, of: connectorID)
                    }
                }
            }
        }
        HStack(spacing: DefaultTheme.space(8)) {
            TextField("NEW_SECRET_NAME", text: $newSecretKey)
                .textFieldStyle(.roundedBorder)
                .themeFont(size: 12, design: .monospaced)
                .frame(width: 220)
            GhostButton("Add", systemImage: "plus") {
                let key = newSecretKey.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !(draft?.secretKeys.contains(key) ?? true) else { return }
                draft?.secretKeys.append(key)
                newSecretKey = ""
            }
        }
    }
}

// MARK: - Launch

/// The Run sheet: which workflow, on what (project, PR, Jira key), at what cost.
struct WorkflowLaunchSheet: View {
    let model: AppModel
    let request: WorkflowsModel.LaunchRequest
    @Environment(\.dismiss) private var dismiss
    @State private var workflowID: UUID?
    @State private var projectID: ProjectID?
    @State private var prText = ""
    @State private var jiraKey = ""
    @State private var note = ""
    @State private var task = ""
    @FocusState private var taskFocused: Bool

    private var workflows: WorkflowsModel { model.workflows }

    private var inputs: RunInputs {
        let pr = Int(prText.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        let key = jiraKey.trimmingCharacters(in: .whitespaces)
        let trigger: Trigger = request.inputs?.trigger ?? (pr != nil ? .pullRequest : key.isEmpty ? .manual : .jiraTicket)
        return RunInputs(trigger: trigger, projectID: projectID, prNumber: pr,
                         jiraKey: key.isEmpty ? nil : key.uppercased(), note: note,
                         task: task.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the sheet asks for depends on what the workflow reads: a task,
    /// a pull request, a ticket — never fields it would not use.
    private struct Asks {
        var task = false
        var pullRequest = false
        var ticket = false
        var note = false

        init(_ workflow: Workflow?) {
            guard let workflow else { return }
            let paths = workflow.templates.flatMap(TemplateRenderer.paths(in:))
            task = workflow.asksForTask
            note = paths.contains("run.note")
            let readsTicket = workflow.nodes.contains {
                if case .context(let config) = $0.kind { return config.source == .jiraTicket }
                return false
            }
            if workflow.workspace == .project {
                pullRequest = workflow.readsPullRequest || workflow.triggers.contains(.pullRequest)
                    || paths.contains { $0.hasPrefix("pr.") }
                ticket = readsTicket || workflow.triggers.contains(.jiraTicket) || paths.contains { $0.hasPrefix("ticket.") }
            }
            // A workflow that asks for nothing still takes a note: something to tell its steps.
            if !task, !pullRequest, !ticket { note = true }
        }
    }

    var body: some View {
        let workflow = workflows.workflow(workflowID)
        let asks = Asks(workflow)
        let problem = workflow.flatMap { model.workflowLaunchProblem($0, inputs: inputs) }
        VStack(alignment: .leading, spacing: DefaultTheme.space(14)) {
            VStack(alignment: .leading, spacing: DefaultTheme.space(5)) {
                Text(workflow.map { "Run «\($0.name)»" } ?? "Run a workflow")
                    .themeFont(size: 17, weight: .bold)
                    .foregroundStyle(DefaultTheme.primaryText)
                if let workflow {
                    if !workflow.summary.isEmpty {
                        Text(workflow.summary)
                            .themeFont(size: 12).foregroundStyle(DefaultTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(WorkflowOutline(workflow, experts: workflows.experts, blocks: workflows.blocks).oneLine)
                        .themeFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(DefaultTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if request.workflowID == nil || workflow == nil {
                Picker("Workflow", selection: $workflowID) {
                    ForEach(workflows.workflows) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if asks.task {
                VStack(alignment: .leading, spacing: DefaultTheme.space(5)) {
                    formTitle("The task")
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $task)
                            .themeFont(size: 13)
                            .foregroundStyle(DefaultTheme.primaryText)
                            .scrollContentBackground(.hidden)
                            .focused($taskFocused)
                            .padding(DefaultTheme.space(8))
                        if task.isEmpty {
                            Text(taskPlaceholder(for: workflow))
                                .themeFont(size: 13)
                                .foregroundStyle(DefaultTheme.mutedText)
                                .padding(.horizontal, DefaultTheme.space(13)).padding(.vertical, DefaultTheme.space(8))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 118, maxHeight: 220)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                        .stroke(taskFocused ? DefaultTheme.accent.opacity(0.7) : DefaultTheme.fieldBorder, lineWidth: 1))
                    .themeShadow(.xs, radius: 6)
                    formHint("As you would tell a colleague: what is wanted, where, and how to know it is done.")
                }
            }
            Picker("Project", selection: $projectID) {
                Text("None").tag(ProjectID?.none)
                ForEach(model.projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            if asks.pullRequest {
                TextField("Pull request number", text: $prText)
            }
            if asks.ticket {
                TextField("Jira key — found in the PR when empty", text: $jiraKey)
            }
            if asks.note {
                TextField("A note for the steps ({{run.note}})", text: $note)
            }
            if let workflow {
                HStack(alignment: .firstTextBaseline, spacing: DefaultTheme.space(8)) {
                    WorkspaceTag(workspace: workflow.workspace)
                    Text(workspaceLine(workflow))
                        .themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let estimate = CostEstimate.estimate(workflow, experts: workflows.experts,
                                                     defaultModel: workflows.defaultModel, blocks: workflows.blocks)
                Text(estimateText(estimate))
                    .themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
            }
            if let problem {
                Text(problem).themeFont(size: 11).foregroundStyle(DefaultTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    guard let workflowID, let runID = model.startWorkflowRun(workflowID, inputs: inputs) else { return }
                    workflows.detail = .run(runID)
                    dismiss()
                }
                // ⌘↵: Return alone is a new line in the task.
                .keyboardShortcut(.return, modifiers: asks.task ? .command : [])
                .disabled(workflow == nil || problem != nil)
                .help(asks.task ? "Run (⌘↵)" : "Run (↵)")
            }
        }
        .padding(DefaultTheme.space(22))
        .frame(width: 520)
        .onAppear {
            workflowID = request.workflowID ?? workflows.selectedWorkflowID ?? workflows.workflows.first?.id
            projectID = request.inputs?.projectID ?? model.selectedProject ?? model.projects.first?.id
            if let number = request.inputs?.prNumber { prText = "\(number)" }
            jiraKey = request.inputs?.jiraKey ?? ""
            note = request.inputs?.note ?? ""
            task = request.inputs?.task ?? ""
            taskFocused = true
        }
    }

    /// The example a template gives for its task, else a plain invitation.
    private func taskPlaceholder(for workflow: Workflow?) -> String {
        let example = WorkflowTemplates.all.first { $0.name == workflow?.name }?.taskPlaceholder ?? ""
        return example.isEmpty ? "What should be done?" : example
    }

    /// Where the run will work, said before it starts.
    private func workspaceLine(_ workflow: Workflow) -> String {
        let project = model.project(projectID)?.name ?? "the project"
        switch workflow.workspace {
        case .worktree:
            let slug = inputs.taskSlug.isEmpty ? AppModel.slug(from: workflow.name) : inputs.taskSlug
            return "Works in a new worktree of \(project), on the branch loom/\(slug). "
                + "Your folder is left alone; nothing is pushed."
        case .project:
            if inputs.prNumber != nil { return "Reads the pull request in its read-only checkout." }
            return "Works in \(project)'s folder, as its steps' experts allow — by default they only read."
        }
    }

    private func estimateText(_ estimate: CostEstimate) -> String {
        var text = "At most \(estimate.runs) claude run\(estimate.runs == 1 ? "" : "s")"
        if let low = estimate.lowUSD, let high = estimate.highUSD {
            text += String(format: " · about %.2f – %.2f $", low, high)
        }
        return text + " — an order of magnitude."
    }
}

// MARK: - Rule sets (ADR-0019)

/// Named rules to tick on a block, a step or a link: one per line.
struct RuleSetEditor: View {
    let model: AppModel
    let ruleSetID: UUID
    @State private var draft: RuleSet?

    private var workflows: WorkflowsModel { model.workflows }

    var body: some View {
        ScrollView {
            if let draft {
                VStack(alignment: .leading, spacing: DefaultTheme.space(18)) {
                    TextField("Name", text: Binding(get: { draft.name }, set: { self.draft?.name = $0 }))
                        .textFieldStyle(.plain)
                        .themeFont(size: 21, weight: .bold)
                        .foregroundStyle(DefaultTheme.primaryText)
                    FormCard {
                        formTitle("Rules")
                        formHint("One rule per line. Tick this set on a block, a step or a link in the editor: its rules join that step's system prompt, under where they come from.")
                        ForEach(Array(draft.rules.enumerated()), id: \.offset) { index, _ in
                            HStack(spacing: DefaultTheme.space(8)) {
                                Text("\(index + 1).").themeFont(size: 12, design: .monospaced)
                                    .foregroundStyle(DefaultTheme.mutedText)
                                TextField("Cite path:line for every finding.", text: Binding(
                                    get: { self.draft?.rules[safe: index] ?? "" },
                                    set: { if self.draft?.rules.indices.contains(index) == true { self.draft?.rules[index] = $0 } }))
                                    .textFieldStyle(.roundedBorder)
                                HoverIconButton(systemImage: "minus.circle", help: "Remove this rule") {
                                    if self.draft?.rules.indices.contains(index) == true { self.draft?.rules.remove(at: index) }
                                }
                            }
                        }
                        GhostButton("Add a rule", systemImage: "plus") { self.draft?.rules.append("") }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(DefaultTheme.space(28))
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { draft = workflows.ruleSet(ruleSetID) }
        .onChange(of: draft) {
            if var draft {
                draft.proposal = workflows.ruleSet(ruleSetID)?.proposal
                workflows.save(draft)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - A person decides (ADR-0019)

/// The question a run waits on, with a comment and one button per answer.
struct ApprovalBanner: View {
    let model: AppModel
    let approval: WorkflowsModel.PendingApproval
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            HStack(spacing: DefaultTheme.space(6)) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                Text("\(approval.title) — your decision").themeFont(size: 12, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
            }
            Text(approval.question).themeFont(size: 12).foregroundStyle(DefaultTheme.primaryText)
                .textSelection(.enabled)
            HStack(spacing: DefaultTheme.space(8)) {
                TextField("A comment for the next steps (optional)", text: $comment)
                    .textFieldStyle(.roundedBorder)
                ForEach(Array(approval.options.enumerated()), id: \.offset) { index, option in
                    if index == 0 {
                        AccentButton(option, systemImage: "checkmark") {
                            model.workflows.decide(approval, option: option, comment: comment)
                        }
                    } else {
                        GhostButton(option, systemImage: "arrow.uturn.backward") {
                            model.workflows.decide(approval, option: option, comment: comment)
                        }
                    }
                }
            }
        }
        .padding(DefaultTheme.space(12))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.badgeColor(for: .needsInput).opacity(0.6)))
        .themeShadow(.sm, radius: 10)
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(8))
    }
}
