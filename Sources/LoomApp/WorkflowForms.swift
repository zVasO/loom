import AppKit
import LoomAgents
import LoomCore
import LoomUI
import LoomWorkflows
import SwiftUI

@MainActor
private func formTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .kerning(0.8)
        .foregroundStyle(DefaultTheme.secondaryText)
}

@MainActor
private func formHint(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(DefaultTheme.mutedText).fixedSize(horizontal: false, vertical: true)
}

private struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }
}

private struct MonoEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DefaultTheme.primaryText)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
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
                    .padding(28)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            draft = workflows.expert(expertID)
            toolsText = (draft?.allowedTools ?? []).joined(separator: "\n")
        }
        .onChange(of: draft) {
            if let draft { workflows.save(draft) }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Expert, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: keyPath] }, set: { draft?[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private func content(_ expert: Expert) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ColorPicker("", selection: Binding(get: { AppModel.color(hex: expert.color) },
                                                   set: { draft?.color = hexString($0) }), supportsOpacity: false)
                    .labelsHidden()
                TextField("Name", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .bold))
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
                            Text(skill.name).font(.system(size: 12, weight: .semibold))
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
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
                    .padding(28)
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
        VStack(alignment: .leading, spacing: 18) {
            TextField("Name", text: Binding(get: { connector.name }, set: { draft?.name = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text(Self.kindLabel(connector.kind) + " · tools as mcp__\(connector.serverKey)__…")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(DefaultTheme.secondaryText)
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
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(DefaultTheme.primaryText)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
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
            .font(.system(size: 12, design: .monospaced))
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
                .font(.system(size: 12, design: .monospaced))
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
                .font(.system(size: 12, design: .monospaced))
            formHint("As `claude mcp list` names it. For Atlassian: claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse, then /mcp in a session to sign in. Steps using it see your other servers too; only this one's tools are allowed.")
        }
    }

    @ViewBuilder
    private func secretsSection(_ connector: Connector) -> some View {
        formTitle("Secrets")
        formHint("Kept in the Keychain on this Mac, never in the workflow's file nor in an export.")
        ForEach(secretKeys(connector), id: \.self) { key in
            HStack(spacing: 8) {
                Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 170, alignment: .leading)
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
        HStack(spacing: 8) {
            TextField("NEW_SECRET_NAME", text: $newSecretKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
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

    private var workflows: WorkflowsModel { model.workflows }

    private var inputs: RunInputs {
        let pr = Int(prText.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        let key = jiraKey.trimmingCharacters(in: .whitespaces)
        let trigger: Trigger = request.inputs?.trigger ?? (pr != nil ? .pullRequest : key.isEmpty ? .manual : .jiraTicket)
        return RunInputs(trigger: trigger, projectID: projectID, prNumber: pr,
                         jiraKey: key.isEmpty ? nil : key.uppercased(), note: note)
    }

    var body: some View {
        let workflow = workflows.workflow(workflowID)
        let problem = workflow.flatMap { model.workflowLaunchProblem($0, inputs: inputs) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Run a workflow").font(.system(size: 17, weight: .bold))
            Picker("Workflow", selection: $workflowID) {
                ForEach(workflows.workflows) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Project", selection: $projectID) {
                Text("None").tag(ProjectID?.none)
                ForEach(model.projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("Pull request number", text: $prText)
            TextField("Jira key — found in the PR when empty", text: $jiraKey)
            TextField("A note for the steps ({{run.note}})", text: $note)
            if let workflow {
                let estimate = CostEstimate.estimate(workflow, experts: workflows.experts,
                                                     defaultModel: workflows.defaultModel)
                Text(estimateText(estimate))
                    .font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
            }
            if let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(DefaultTheme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    guard let workflowID, let runID = model.startWorkflowRun(workflowID, inputs: inputs) else { return }
                    workflows.detail = .run(runID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workflow == nil || problem != nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            workflowID = request.workflowID ?? workflows.selectedWorkflowID ?? workflows.workflows.first?.id
            projectID = request.inputs?.projectID ?? model.selectedProject ?? model.projects.first?.id
            if let number = request.inputs?.prNumber { prText = "\(number)" }
            jiraKey = request.inputs?.jiraKey ?? ""
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
