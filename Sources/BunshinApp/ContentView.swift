import BunshinAgents
import BunshinCore
import BunshinGit
import BunshinPersistence
import BunshinTerminal
import BunshinUI
import BunshinWeb
import SwiftUI

// Structure de la référence validée : navbar custom (Projects / Sessions / +),
// vue Projects en colonne centrée, vue Sessions en sidebar groupée + détail.

enum MainTab {
    case projects, sessions
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: MainTab = .projects
    @State private var selected: SessionID?
    @State private var browserShown = false
    @State private var paletteShown = false
    @State private var paletteQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            navbar
            Divider().overlay(DefaultTheme.cardBorder)
            switch tab {
            case .projects: ProjectsView(model: model, onOpenSessions: { project in
                model.selectedProject = project
                tab = .sessions
            }, onNewSession: { project in
                createSession(in: project)
            })
            case .sessions: SessionsView(model: model, selected: $selected,
                                         onNewSession: { project in
                                             createSession(in: project)
                                         })
            }
        }
        .background(DefaultTheme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .sheet(isPresented: $browserShown) {
            BrowserPanelView(onVisit: { url, title in model.recordVisit(url: url, title: title) })
                .frame(minWidth: 960, minHeight: 640)
        }
        .sheet(isPresented: $paletteShown) { palette }
        .alert("Démarrage incomplet", isPresented: .constant(model.startupError != nil)) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.startupError ?? "")
        }
    }

    // MARK: - Barre de navigation

    private var navbar: some View {
        HStack(spacing: 10) {
            // Espace des feux tricolores (barre de titre masquée).
            Spacer().frame(width: 70)
            Text("分身").font(.system(size: 17)).foregroundStyle(DefaultTheme.accent)
            Text("Bunshin").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text("beta")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DefaultTheme.secondaryText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(DefaultTheme.surfaceRaised, in: Capsule())

            Spacer().frame(width: 18)
            NavTab("Projects", isActive: tab == .projects) { tab = .projects }
            NavTab("Sessions", isActive: tab == .sessions) { tab = .sessions }
            Button {
                createSession(in: model.selectedProject)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DefaultTheme.accentText)
                    .frame(width: 26, height: 26)
                    .background(DefaultTheme.accent, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Spacer()

            GhostButton(systemImage: "globe") { browserShown = true }
            Button {
                paletteShown = true
            } label: {
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(DefaultTheme.background)
    }

    // MARK: - Palette ⌘K

    private var palette: some View {
        VStack(spacing: 0) {
            TextField("Aller à une session…", text: $paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(14)
            Divider().overlay(DefaultTheme.cardBorder)
            List(paletteMatches, id: \.self) { title in
                Text(title)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .contentShape(Rectangle())
                    .onTapGesture { openFromPalette(title) }
                    .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 260)
        }
        .frame(minWidth: 520)
        .background(DefaultTheme.surface)
        .onSubmit {
            if let first = paletteMatches.first { openFromPalette(first) }
        }
    }

    private var allSessionTitles: [(title: String, id: SessionID)] {
        model.sessions.map { ($0.title, $0.id) }
            + model.interruptedSessions.map { ($0.title, $0.id) }
            + model.historySessions.map { ($0.title, $0.id) }
    }

    private var paletteMatches: [String] {
        CommandPalette.rank(query: paletteQuery, in: allSessionTitles.map(\.title))
    }

    /// Le + de la référence : une session claude démarre immédiatement,
    /// l'objectif se tape dans le terminal.
    private func createSession(in projectID: ProjectID?) {
        Task {
            if let id = await model.launchSession(in: projectID) {
                selected = id
                tab = .sessions
            }
        }
    }

    private func openFromPalette(_ title: String) {
        if let match = allSessionTitles.first(where: { $0.title == title }) {
            selected = match.id
            tab = .sessions
        }
        paletteShown = false
        paletteQuery = ""
    }
}

// MARK: - Vue Projects (référence : « Your Projects », colonne centrée)

struct ProjectsView: View {
    let model: AppModel
    let onOpenSessions: (ProjectID) -> Void
    let onNewSession: (ProjectID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tes projets")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Text("\(model.projects.count) projet\(model.projects.count > 1 ? "s" : "")")
                            .font(.system(size: 13))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    Spacer()
                    AccentButton("Ajouter un projet", systemImage: "plus") { pickProject() }
                }

                if model.projects.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.projects, id: \.id) { project in
                            ProjectRow(project: project, model: model,
                                       onOpen: { onOpenSessions(project.id) },
                                       onNewSession: { onNewSession(project.id) })
                        }
                    }
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .frame(maxWidth: .infinity)
        }
        .background(DefaultTheme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("分身").font(.system(size: 44)).foregroundStyle(DefaultTheme.accent)
            Text("Ajoute ton premier projet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text("Un dossier local — s'il contient un repo Git, chaque session\ntravaillera isolée sur son propre worktree.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
                .multilineTextAlignment(.center)
            if model.claudePath == nil {
                VStack(spacing: 4) {
                    Label("Claude Code introuvable", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                    Text("npm install -g @anthropic-ai/claude-code")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.addProject(at: url) }
        }
    }
}

/// Carte projet de la référence : dossier orange, nom, chemin mono, méta.
struct ProjectRow: View {
    let project: ProjectRecord
    let model: AppModel
    let onOpen: () -> Void
    let onNewSession: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 15))
                .foregroundStyle(DefaultTheme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(project.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
                HStack(spacing: 14) {
                    if let date = model.lastActivity(for: project.id) {
                        MonoTag(relative(date), systemImage: "clock", color: DefaultTheme.secondaryText)
                    }
                    if let branch = project.defaultBranch {
                        MonoTag(branch, systemImage: "arrow.triangle.branch")
                    }
                    let active = model.activeCount(for: project.id)
                    if active > 0 {
                        MonoTag("\(active) active", systemImage: "circle.fill",
                                color: DefaultTheme.badgeColor(for: .working))
                    }
                    let total = model.sessionCount(for: project.id)
                    if total > 0 {
                        MonoTag("\(total) session\(total > 1 ? "s" : "")",
                                systemImage: "square.grid.2x2", color: DefaultTheme.secondaryText)
                    }
                }
                .padding(.top, 3)
            }
            Spacer()
            if hovered {
                AccentButton("Nouvelle session", systemImage: "plus") { onNewSession() }
            }
        }
        .padding(16)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(hovered ? DefaultTheme.accent.opacity(0.5) : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Ouvrir dans le Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Vue Sessions (référence : sidebar groupée + détail)

struct SessionsView: View {
    let model: AppModel
    @Binding var selected: SessionID?
    let onNewSession: (ProjectID) -> Void
    @State private var renameTarget: SessionID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DefaultTheme.cardBorder)
            if let selected {
                SessionDetailView(model: model, sessionID: selected)
                    .id(selected)
            } else {
                VStack(spacing: 8) {
                    Text("Aucune session ouverte")
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text("Choisis-en une à gauche, ou ⌘K")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DefaultTheme.contentBackground)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.projects, id: \.id) { project in
                    let items = model.sessions.filter { $0.projectID == project.id }
                    let interrupted = model.interruptedSessions.filter { $0.projectID == project.id }
                    if !items.isEmpty || !interrupted.isEmpty {
                        projectGroup(project, items: items, interrupted: interrupted)
                    }
                }
                let orphans = model.sessions.filter { model.project($0.projectID) == nil }
                if !orphans.isEmpty {
                    groupHeader("Sans projet", projectID: nil)
                    ForEach(orphans) { item in sessionCard(item) }
                }
                if !model.historySessions.isEmpty {
                    groupHeader("Historique", projectID: nil)
                    ForEach(model.historySessions.prefix(12), id: \.id) { record in
                        historyCard(record)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(DefaultTheme.background)
        .alert("Renommer la session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") {
                if let target = renameTarget { model.renameSession(target, to: renameText) }
                renameTarget = nil
            }
            Button("Annuler", role: .cancel) { renameTarget = nil }
        }
    }

    @ViewBuilder
    private func projectGroup(_ project: ProjectRecord, items: [AppModel.SessionItem],
                              interrupted: [SessionRecord]) -> some View {
        groupHeader(project.name.uppercased(), projectID: project.id)
        ForEach(items) { item in sessionCard(item) }
        ForEach(interrupted, id: \.id) { record in interruptedCard(record) }
    }

    private func groupHeader(_ title: String, projectID: ProjectID?) -> some View {
        HStack {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DefaultTheme.mutedText)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            Spacer()
            if let projectID {
                Button {
                    onNewSession(projectID)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func sessionCard(_ item: AppModel.SessionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if let branch = item.branch {
                MonoTag(branch, systemImage: "arrow.triangle.branch",
                        color: DefaultTheme.secondaryText)
            }
            StatusLabel(item.state)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(selected == item.id ? DefaultTheme.accent : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selected = item.id }
        .contextMenu {
            Button("Renommer…") {
                renameText = item.title
                renameTarget = item.id
            }
            Button("Archiver") { Task { await model.archiveSession(item.id) } }
        }
    }

    private func interruptedCard(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            StatusLabel(.interrupted)
            Button("Reprendre") {
                Task { await model.resumeSession(record) }
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .tint(DefaultTheme.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func historyCard(_ record: SessionRecord) -> some View {
        HStack(spacing: 8) {
            Circle().fill(DefaultTheme.badgeColor(for: record.state)).frame(width: 5, height: 5)
            Text(record.title)
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contextMenu {
            Button("Archiver") { Task { await model.archiveSession(record.id) } }
        }
    }
}

// MARK: - Détail de session (référence : fil d'Ariane + terminal + actions)

struct SessionDetailView: View {
    let model: AppModel
    let sessionID: SessionID
    @State private var surface: TerminalSurface?
    @State private var input = ""
    @State private var gitShown = false
    @State private var gitData: AppModel.GitPanelData?
    @State private var skills: [SkillEntry] = []

    /// Le helper est actif tant qu'on tape le nom du skill (« /dep… ») ;
    /// dès un espace, on est dans les arguments — Entrée envoie.
    private var skillHelperActive: Bool {
        input.hasPrefix("/") && !input.contains(" ")
    }

    private var skillSuggestions: [SkillEntry] {
        let query = String(input.dropFirst())
        let ranked = CommandPalette.rank(query: query, in: skills.map(\.name))
        return ranked.prefix(8).compactMap { name in skills.first { $0.name == name } }
    }

    private var item: AppModel.SessionItem? {
        model.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider().overlay(DefaultTheme.cardBorder)
            if let surface {
                HSplitView {
                    GeometryReader { proxy in
                        TerminalScreenView(screen: surface.screen)
                            // TRM-02 : la vue annonce sa grille au PTY ; le task(id:)
                            // s'annule à chaque changement de taille — debounce gratuit
                            // pendant le redimensionnement de la fenêtre.
                            .task(id: proxy.size) {
                                try? await Task.sleep(for: .milliseconds(80))
                                guard !Task.isCancelled else { return }
                                let grid = TerminalMetrics.grid(fitting: proxy.size)
                                surface.resize(cols: grid.cols, rows: grid.rows)
                            }
                    }
                    .background(DefaultTheme.contentBackground)
                    if gitShown { gitPanel }
                }
                inputBar(surface)
                    .task { await surface.attached() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DefaultTheme.contentBackground)
        .task { surface = await model.surface(for: sessionID) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 10) {
            Text(model.project(item?.projectID)?.name ?? "Session")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("/").foregroundStyle(DefaultTheme.mutedText)
            Text(item?.title ?? "Session")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if let branch = item?.branch {
                MonoTag(branch, systemImage: "arrow.triangle.branch")
            }
            if let state = item?.state {
                StatusLabel(state)
            }
            Spacer()
            GhostButton("Git", systemImage: "arrow.triangle.branch") {
                gitShown.toggle()
                if gitShown { Task { gitData = await model.gitPanel(for: sessionID) } }
            }
            GhostButton("Stop", systemImage: "stop.circle", role: .destructive) {
                Task { await model.stopSession(sessionID) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(DefaultTheme.background)
    }

    private func inputBar(_ surface: TerminalSurface) -> some View {
        VStack(spacing: 6) {
            if skillHelperActive && !skillSuggestions.isEmpty {
                skillHelper
            }
            TextField("Répondre à l'agent…  (/ pour les skills)", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DefaultTheme.primaryText)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                .onChange(of: input) { _, newValue in
                    if newValue.hasPrefix("/") && skills.isEmpty {
                        skills = model.skills(for: sessionID)
                    }
                }
                .onSubmit {
                    if skillHelperActive, let first = skillSuggestions.first {
                        input = "/" + first.name + " "
                    } else {
                        surface.send(input + "\r")
                        input = ""
                    }
                }
        }
        .padding(10)
        .background(DefaultTheme.background)
    }

    /// SKL-01 : les skills visibles par l'agent dans ce worktree, projet devant.
    private var skillHelper: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(skillSuggestions, id: \.name) { skill in
                Button {
                    input = "/" + skill.name + " "
                } label: {
                    HStack(spacing: 8) {
                        Text("/" + skill.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DefaultTheme.accent)
                        Text(skill.description)
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(skill.scope == .project ? "projet" : "global")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(skill.scope == .project ? DefaultTheme.accent : DefaultTheme.mutedText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DefaultTheme.surfaceRaised, in: Capsule())
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private var gitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Modifications")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton(systemImage: "arrow.clockwise") {
                    Task { gitData = await model.gitPanel(for: sessionID) }
                }
            }
            if let gitData {
                if gitData.changes.isEmpty {
                    Text("Worktree propre").font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                } else {
                    ForEach(gitData.changes, id: \.path) { change in
                        MonoTag(change.path, systemImage: symbol(for: change.kind),
                                color: DefaultTheme.secondaryText)
                    }
                    ScrollView {
                        Text(gitData.diff)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DefaultTheme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Pas de worktree pour cette session")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: 420)
        .background(DefaultTheme.background)
    }

    private func symbol(for kind: FileChange.Kind) -> String {
        switch kind {
        case .modified: "pencil"
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .untracked: "questionmark"
        }
    }
}
