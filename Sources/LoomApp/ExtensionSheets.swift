import LoomCore
import LoomExtensions
import LoomPersistence
import LoomUI
import SwiftUI

/// What an extension asked to launch, shown in full before anything starts
/// (ADR-0010, ADR-0011). The prompt came from outside — a ticket written by
/// someone else — so it is editable, and the sheet says where it came from.
struct ExtensionLaunchSheet: View {
    let model: AppModel
    let request: PendingExtensionLaunch

    @State private var projectID: ProjectID?
    @State private var placement: AppModel.LaunchPlacement = .projectFolder
    @State private var title = ""
    @State private var prompt = ""
    @State private var badges: [String] = []
    @State private var launching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(DefaultTheme.accent)
                Text("\(request.extensionName) wants to start a session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
            }
            Text("Nothing starts until you press Launch. The prompt comes from the extension — read it before claude does.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)

            field("PROJECT") {
                Picker("", selection: $projectID) {
                    Text("Choose a project").tag(ProjectID?.none)
                    ForEach(model.projects, id: \.id) { project in
                        Text(project.name).tag(ProjectID?.some(project.id))
                    }
                }
                .labelsHidden()
                .onChange(of: projectID) { placement = model.defaultPlacement(for: projectID) }
            }

            field("WHERE IT WORKS") {
                Picker("", selection: $placement) {
                    Label("Project folder", systemImage: "folder").tag(AppModel.LaunchPlacement.projectFolder)
                    Label("New worktree", systemImage: "arrow.triangle.branch").tag(AppModel.LaunchPlacement.newWorktree)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.isGitRepository(projectID))
            }

            field("TITLE") {
                TextField("Session title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            if !badges.isEmpty {
                field("BADGES") {
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.self) { badge in
                            Button {
                                badges.removeAll { $0 == badge }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(badge).font(.system(size: 11, weight: .medium))
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .foregroundStyle(DefaultTheme.primaryText)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(DefaultTheme.surfaceRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Remove this badge")
                        }
                    }
                }
            }

            field("PROMPT") {
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 280)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            }

            HStack {
                GhostButton("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                AccentButton(launching ? "Launching…" : "Launch", systemImage: "play.fill") { launch() }
                    .disabled(!canLaunch)
                    .opacity(canLaunch ? 1 : 0.5)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(DefaultTheme.background)
        .onAppear(perform: prefill)
    }

    private var canLaunch: Bool {
        !launching && projectID != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prefill() {
        let params = request.params
        let proposed = params.projectId.flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
        projectID = model.projects.contains { $0.id == proposed } ? proposed
            : (model.selectedProject ?? model.projects.first?.id)
        switch params.placement {
        case "worktree": placement = .newWorktree
        case "folder": placement = .projectFolder
        default: placement = model.defaultPlacement(for: projectID)
        }
        title = params.title ?? ""
        prompt = params.prompt
        badges = SessionRecord.normalizedBadges(params.badges ?? [])
    }

    private func launch() {
        guard canLaunch else { return }
        launching = true
        let placement = model.isGitRepository(projectID) ? self.placement : .projectFolder
        Task {
            let id = await model.launchFromExtension(prompt: prompt, projectID: projectID, placement: placement,
                                                     title: title, badges: badges)
            finish(id)
        }
    }

    private func finish(_ id: SessionID?) {
        model.extensions.finishLaunch(BridgeLaunchResult(launched: id != nil,
                                                         sessionId: id?.rawValue.uuidString))
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            content()
        }
    }
}

/// Before an extension is installed, linked, or given more than it had: what
/// it will be able to reach, in plain words. Its own storage and its Keychain
/// secrets need no consent — they reach nothing but itself.
struct ExtensionConsentSheet: View {
    let request: ExtensionConsentRequest
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: request.manifest.icon ?? "puzzlepiece.extension")
                    .font(.system(size: 20))
                    .foregroundStyle(DefaultTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Text("\(request.manifest.id) · v\(request.manifest.version)"
                         + (request.manifest.author.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
            }
            if let description = request.manifest.description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(request.permissions.isEmpty ? "IT ASKS FOR NOTHING BEYOND ITS OWN PAGE" : "IT WILL BE ABLE TO")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(DefaultTheme.secondaryText)
                ForEach(request.permissions.summary, id: \.self) { line in
                    Label(line, systemImage: "checkmark.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                Label("Keep its own settings, and secrets in your Keychain", systemImage: "key")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))

            Text("An extension runs in its own sandboxed web view: it cannot read your files, your terminals or your browser's cookies, and it reaches the network only through the hosts above.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)

            HStack {
                GhostButton("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                AccentButton(approveTitle, systemImage: "checkmark", action: onApprove)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(DefaultTheme.background)
    }

    private var heading: String {
        switch request.kind {
        case .install: return "Install \(request.manifest.name)?"
        case .link: return "Link \(request.manifest.name) for development?"
        case .update: return "\(request.manifest.name) asks for more"
        }
    }

    private var approveTitle: String {
        switch request.kind {
        case .install: return "Install"
        case .link: return "Link"
        case .update: return "Allow"
        }
    }
}
