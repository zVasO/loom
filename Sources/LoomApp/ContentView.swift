import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomTerminal
import LoomUI
import LoomWeb
import SwiftUI

// Structure de la référence validée : navbar custom (Projects / Sessions / +),
// vue Projects en colonne centrée, vue Sessions en sidebar groupée + détail.

enum MainTab {
    case projects, sessions
}

/// Le détail de la vue Sessions : une session… ou le navigateur, en onglet
/// comme les autres (WEB-03).
enum DetailSelection: Hashable {
    case session(SessionID)
    case webPane(UUID)
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: MainTab = .projects
    @State private var selected: DetailSelection?
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
            }, onOpenSession: { id in
                selected = .session(id)
                tab = .sessions
            })
            case .sessions: SessionsView(model: model, selected: $selected,
                                         onVisit: { url, title in model.recordVisit(url: url, title: title) },
                                         onNewSession: { project in
                                             createSession(in: project)
                                         },
                                         onShowProject: { project in
                                             if let project { model.selectedProject = project }
                                             tab = .projects
                                         })
            }
        }
        .background(DefaultTheme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .task {
            // Reproduction autonome (diagnostic) : LOOM_AUTOTEST=1 simule le
            // clic « + » deux secondes après le lancement — même chemin de code.
            guard ProcessInfo.processInfo.environment["LOOM_AUTOTEST"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1))
            NSApp.windows.first?.setFrame(NSRect(x: 40, y: 40, width: 1500, height: 950),
                                          display: true)
            try? await Task.sleep(for: .seconds(1))
            createSession(in: model.projects.first?.id)
            // La frappe passe par le VRAI chemin (fenêtre → premier répondant →
            // PTY) : le dump doit montrer « salut » dans le champ de l'agent.
            try? await Task.sleep(for: .seconds(8))
            if let win = NSApp.windows.first {
                let touches: [(String, UInt16)] = [("s", 1), ("a", 0), ("l", 37), ("u", 32), ("t", 17)]
                for (char, code) in touches {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: win.windowNumber, context: nil,
                                                 characters: char, charactersIgnoringModifiers: char,
                                                 isARepeat: false, keyCode: code)
                    if let event { win.sendEvent(event) }
                }
            }
            try? await Task.sleep(for: .seconds(3))
            if case .session(let id) = selected, let s = await model.surface(for: id) {
                let text = s.screen.lines
                    .map { String($0.cells.map(\.character)) }
                    .joined(separator: "\n")
                try? text.write(toFile: "/tmp/loom-screen-dump.txt",
                                atomically: true, encoding: .utf8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewSession)) { _ in
            createSession(in: model.selectedProject)
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
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 15))
                .foregroundStyle(DefaultTheme.accent)
            Text("Loom").font(.system(size: 14, weight: .semibold))
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
                    .hoverBrightness()
            }
            .buttonStyle(.plain)

            Spacer()

            GhostButton(systemImage: "globe") {
                // WEB-03 : le navigateur naît DANS la pile de la session courante.
                var parent: SessionID?
                if case .session(let id) = selected { parent = id }
                let pane = model.openBrowserPane(for: parent)
                tab = .sessions
                selected = .webPane(pane)
            }
            Button {
                paletteShown = true
            } label: {
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    .hoverBrightness(0.1)
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
                selected = .session(id)
                tab = .sessions
            }
        }
    }

    private func openFromPalette(_ title: String) {
        if let match = allSessionTitles.first(where: { $0.title == title }) {
            selected = .session(match.id)
            tab = .sessions
        }
        paletteShown = false
        paletteQuery = ""
    }
}

// MARK: - Vue Projects (référence : sidebar de projets + détail — objectif → session)

struct ProjectsView: View {
    let model: AppModel
    let onOpenSessions: (ProjectID) -> Void
    let onNewSession: (ProjectID) -> Void
    let onOpenSession: (SessionID) -> Void
    @State private var goal = ""
    @FocusState private var goalFocused: Bool
    @State private var draggedProject: ProjectID?
    @State private var removalTarget: ProjectRecord?
    @State private var projectTab: ProjectTab = .overview
    @State private var skillFilter: SkillFilter = .all
    @State private var viewedDocument: ViewedDocument?

    struct ViewedDocument: Equatable {
        var title: String
        var path: URL
        var content: String
        var isText: Bool
    }

    enum SkillFilter: String, CaseIterable {
        case all = "Tous", global = "Global", project = "Projet"
    }
    @State private var filesPath = ""
    @State private var gitData: AppModel.ProjectGitData?

    enum ProjectTab: String, CaseIterable {
        case overview = "Overview", git = "Git", files = "Files"
        case skills = "Skills", rules = "Rules"
    }

    private var current: ProjectRecord? {
        model.projects.first { $0.id == model.selectedProject } ?? model.projects.first
    }

    var body: some View {
        if model.projects.isEmpty {
            ScrollView {
                emptyState
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 32).padding(.top, 60)
                    .frame(maxWidth: .infinity)
            }
            .background(DefaultTheme.background)
        } else {
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(DefaultTheme.cardBorder)
                detail
            }
            .background(DefaultTheme.background)
        }
    }

    // MARK: Sidebar des projets

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PROJETS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.groupHeader)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            ForEach(model.projects, id: \.id) { project in
                ProjectSidebarRow(project: project,
                                  isSelected: current?.id == project.id,
                                  activeCount: model.activeCount(for: project.id),
                                  onSelect: { model.selectedProject = project.id },
                                  onRemove: { removalTarget = project })
                .opacity(draggedProject == project.id ? 0.35 : 1)
                .onDrag {
                    draggedProject = project.id
                    return NSItemProvider(object: project.id.rawValue.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: ProjectReorderDelegate(
                    target: project.id, dragged: $draggedProject,
                    move: { dragged, target in
                        withAnimation(.hover) {
                            model.reorderProjects(dragged: dragged, before: target)
                        }
                    }))
            }
            Spacer()
            GhostButton("Ajouter un projet", systemImage: "plus") { pickProject() }
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .frame(width: 216)
        .background(DefaultTheme.background)
        .alert("Supprimer « \(removalTarget?.name ?? "") » ?",
               isPresented: Binding(get: { removalTarget != nil },
                                    set: { if !$0 { removalTarget = nil } })) {
            Button("Supprimer", role: .destructive) {
                if let target = removalTarget { model.removeProject(target.id) }
                removalTarget = nil
            }
            Button("Annuler", role: .cancel) { removalTarget = nil }
        } message: {
            Text("Le projet disparaît de Loom — le dossier local et l'historique des sessions ne sont pas touchés.")
        }
    }

    // MARK: Détail du projet

    private var detail: some View {
        ScrollView {
            if let project = current {
                VStack(alignment: .leading, spacing: 26) {
                    header(project)
                    tabBar
                    if let document = viewedDocument {
                        documentViewer(document)
                    } else {
                        switch projectTab {
                        case .overview:
                            goalField(project)
                            activeSection(project)
                            recentSection(project)
                        case .git: gitTab(project)
                        case .files: filesTab(project)
                        case .skills: skillsTab(project)
                        case .rules: rulesTab(project)
                        }
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DefaultTheme.background)
        // Changer de projet remet la navigation des tabs à zéro.
        .onChange(of: current?.id) {
            projectTab = .overview
            filesPath = ""
            gitData = nil
            viewedDocument = nil
        }
        .onChange(of: projectTab) { viewedDocument = nil }
        .task(id: "\(current?.id.rawValue.uuidString ?? "")-\(projectTab.rawValue)") {
            if projectTab == .git, let project = current {
                gitData = await model.projectGit(project.id)
            }
        }
    }

    /// La rangée d'onglets de la référence : soulignement accent sur l'actif.
    private var tabBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                ForEach(ProjectTab.allCases, id: \.self) { tabItem in
                    ProjectTabButton(title: tabItem.rawValue,
                                     isActive: projectTab == tabItem) {
                        projectTab = tabItem
                    }
                }
            }
            Divider().overlay(DefaultTheme.cardBorder)
        }
    }

    // MARK: Tab Git — le dossier racine du projet

    @ViewBuilder
    private func gitTab(_ project: ProjectRecord) -> some View {
        if let git = gitData {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    MonoTag(git.branch, systemImage: "arrow.triangle.branch")
                    Text("· racine du projet (les worktrees vivent dans leurs sessions)")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                if git.changes.isEmpty {
                    Text("Aucune modification en attente")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(git.changes.enumerated()), id: \.offset) { _, change in
                            HStack(spacing: 8) {
                                Text(String(describing: change.kind).prefix(1).uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.accent)
                                    .frame(width: 14)
                                Text(change.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DefaultTheme.primaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(12)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Lecture du dépôt…")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    // MARK: Tab Files — navigation lecture seule

    private func filesTab(_ project: ProjectRecord) -> some View {
        let entries = model.listFiles(in: project.id, at: filesPath)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HoverIconButton(systemImage: "house", help: "Racine du projet") { filesPath = "" }
                Text("/" + filesPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
                Spacer()
                GhostButton("Finder", systemImage: "arrow.up.forward.square") {
                    let url = URL(fileURLWithPath: project.path).appendingPathComponent(filesPath)
                    NSWorkspace.shared.open(url)
                }
            }
            VStack(spacing: 1) {
                if !filesPath.isEmpty {
                    fileRow(name: "..", isDirectory: true) {
                        filesPath = filesPath.contains("/")
                            ? String(filesPath[..<filesPath.lastIndex(of: "/")!]) : ""
                    }
                }
                ForEach(entries) { entry in
                    fileRow(name: entry.name, isDirectory: entry.isDirectory) {
                        if entry.isDirectory {
                            filesPath = entry.path
                        } else {
                            openDocument(at: URL(fileURLWithPath: project.path)
                                .appendingPathComponent(entry.path), title: entry.name)
                        }
                    }
                }
            }
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func fileRow(name: String, isDirectory: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(isDirectory ? DefaultTheme.accent : DefaultTheme.secondaryText)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DefaultTheme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverSurface(0.6)
        .onTapGesture(perform: action)
    }

    // MARK: Tab Skills — ce que les agents peuvent invoquer ici (cartes, réf. Xirp)

    private func skillsTab(_ project: ProjectRecord) -> some View {
        let skills = model.skills(forProject: project.id)
        let globals = skills.filter { $0.scope == .global }
        let projets = skills.filter { $0.scope == .project }
        let filtered = switch skillFilter {
        case .all: skills
        case .global: globals
        case .project: projets
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                filterPill("Tous (\(skills.count))", isActive: skillFilter == .all) { skillFilter = .all }
                filterPill("Global (\(globals.count))", isActive: skillFilter == .global) { skillFilter = .global }
                filterPill("Projet (\(projets.count))", isActive: skillFilter == .project) { skillFilter = .project }
            }
            if filtered.isEmpty {
                Text("Aucun skill — ajoute des dossiers dans .claude/skills (projet) ou ~/.claude/skills (global).")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(filtered, id: \.name) { skill in
                    SkillCard(skill: skill) {
                        if let path = skill.path {
                            openDocument(at: path, title: skill.name)
                        }
                    }
                }
            }
        }
    }

    /// Ouvre un fichier DANS l'app : texte affiché en place, binaire signalé.
    private func openDocument(at url: URL, title: String) {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            viewedDocument = ViewedDocument(title: title, path: url,
                                            content: String(content.prefix(200_000)),
                                            isText: true)
        } else {
            viewedDocument = ViewedDocument(title: title, path: url, content: "",
                                            isText: false)
        }
    }

    /// Lecteur intégré : retour, titre, chemin, Finder — contenu mono, markdown
    /// léger pour les .md (gras, code…), sélectionnable.
    private func documentViewer(_ document: ViewedDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HoverIconButton(systemImage: "arrow.left", help: "Retour") {
                    viewedDocument = nil
                }
                Text(document.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(document.path.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
                Spacer()
                GhostButton("Finder", systemImage: "arrow.up.forward.square") {
                    NSWorkspace.shared.activateFileViewerSelecting([document.path])
                }
            }
            if document.isText {
                Text(renderedContent(document))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(DefaultTheme.cardBorder, lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 28))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text("Fichier binaire — ouvre-le depuis le Finder")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func renderedContent(_ document: ViewedDocument) -> AttributedString {
        guard document.path.pathExtension.lowercased() == "md",
              let markdown = try? AttributedString(
                  markdown: document.content,
                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(document.content) }
        return markdown
    }

    private func filterPill(_ title: String, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(isActive ? DefaultTheme.surfaceRaised : .clear, in: Capsule())
                .overlay(Capsule().stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Tab Rules — les instructions que liront les agents (cartes)

    private func rulesTab(_ project: ProjectRecord) -> some View {
        let rules = model.ruleFiles(for: project.id)
        return VStack(alignment: .leading, spacing: 16) {
            if rules.isEmpty {
                Text("Aucun fichier de règles (CLAUDE.md, AGENTS.md, CONTEXT.md…) à la racine.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(rules) { rule in
                    RuleCard(rule: rule) {
                        openDocument(at: URL(fileURLWithPath: project.path)
                            .appendingPathComponent(rule.name), title: rule.name)
                    }
                }
            }
        }
    }

    private func header(_ project: ProjectRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 17))
                .foregroundStyle(DefaultTheme.accent)
                .frame(width: 40, height: 40)
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(project.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer()
            GhostButton("Sessions", systemImage: "arrow.right") { onOpenSessions(project.id) }
        }
    }

    /// Le geste central de la référence : décrire l'objectif ICI lance la session —
    /// le prompt part directement dans le terminal de l'agent.
    private func goalField(_ project: ProjectRecord) -> some View {
        TextField("Que construit-on ? Décris ton objectif — Entrée lance une session…",
                  text: $goal)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(DefaultTheme.primaryText)
            .focused($goalFocused)
            .onSubmit { submitGoal(project) }
            .padding(.horizontal, 18).padding(.vertical, 17)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(goalFocused ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder,
                        lineWidth: 1))
            .animation(.hover, value: goalFocused)
    }

    private func submitGoal(_ project: ProjectRecord) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        goal = ""
        Task {
            if let id = await model.launchSession(prompt: trimmed, in: project.id) {
                onOpenSession(id)
            }
        }
    }

    // MARK: Sessions actives

    private func activeSection(_ project: ProjectRecord) -> some View {
        let items = model.sessions.filter { $0.projectID == project.id && !$0.isShell }
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("ACTIVES", count: items.count,
                          color: DefaultTheme.badgeColor(for: .working))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    ActiveSessionCard(item: item) { onOpenSession(item.id) }
                }
                QuickSessionCard { onNewSession(project.id) }
            }
        }
    }

    // MARK: Sessions récentes

    private func recentSection(_ project: ProjectRecord) -> some View {
        let records = (model.interruptedSessions + model.historySessions)
            .filter { $0.projectID == project.id }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
        return Group {
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("RÉCENTES", count: records.count,
                                  color: DefaultTheme.secondaryText)
                    VStack(spacing: 2) {
                        ForEach(Array(records), id: \.id) { record in
                            RecentSessionRow(record: record) {
                                Task {
                                    await model.resumeSession(record)
                                    onOpenSession(record.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(DefaultTheme.accent)
            Text("Ajoute ton premier projet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text("Un dossier local — s'il contient un repo Git, chaque session\ntravaillera isolée sur son propre worktree.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
                .multilineTextAlignment(.center)
            AccentButton("Ajouter un projet", systemImage: "plus") { pickProject() }
                .padding(.top, 6)
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

/// Onglet horizontal d'une pile (référence : barre du Terminal) : icône,
/// titre, croix visible au survol ou sur l'actif. Dormant = atténué.
struct StackTab: View {
    let icon: String
    let title: String
    let isActive: Bool
    var isDormant: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(isDormant ? DefaultTheme.mutedText
                                 : isActive ? DefaultTheme.accent : DefaultTheme.secondaryText)
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isDormant ? DefaultTheme.secondaryText
                                 : isActive || hovered ? DefaultTheme.primaryText
                                                       : DefaultTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if hovered || isActive {
                HoverIconButton(systemImage: "xmark", help: "Fermer", action: onClose)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isActive ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Carte skill de la référence : étincelle dans un carré teinté, nom, deux
/// lignes de description, chip de portée.
struct SkillCard: View {
    let skill: SkillEntry
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.62, green: 0.55, blue: 0.95))
                .frame(width: 30, height: 30)
                .background(Color(red: 0.62, green: 0.55, blue: 0.95).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                scopeChip
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(hovered ? DefaultTheme.surfaceRaised : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hovered ? DefaultTheme.accent.opacity(0.5) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }

    private var scopeChip: some View {
        let isProject = skill.scope == .project
        let color = isProject ? DefaultTheme.accent
                              : Color(red: 0.416, green: 0.635, blue: 0.910)
        return Label(isProject ? "projet" : "global",
                     systemImage: isProject ? "folder" : "globe")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Carte règle : document dans un carré teinté, nom, aperçu — clic pour ouvrir.
struct RuleCard: View {
    let rule: AppModel.RuleFile
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(DefaultTheme.accent)
                .frame(width: 30, height: 30)
                .background(DefaultTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(rule.content.prefix(300))
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(hovered ? DefaultTheme.surfaceRaised : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hovered ? DefaultTheme.accent.opacity(0.5) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Onglet du détail projet : soulignement accent sur l'actif, texte éclairci
/// au survol (référence Xirp).
struct ProjectTabButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                         : DefaultTheme.secondaryText)
                Rectangle()
                    .fill(isActive ? DefaultTheme.accent : .clear)
                    .frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Réordonnancement au survol pendant le drag : la ligne se déplace en direct
/// dès qu'on la traîne sur une autre — le lâcher ne fait que conclure.
struct ProjectReorderDelegate: DropDelegate {
    let target: ProjectID
    @Binding var dragged: ProjectID?
    let move: (ProjectID, ProjectID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        move(dragged, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// Ligne de la sidebar : barre accent + dossier orange quand le projet est ouvert.
struct ProjectSidebarRow: View {
    let project: ProjectRecord
    let isSelected: Bool
    let activeCount: Int
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DefaultTheme.accent)
                .frame(width: 2, height: 14)
                .opacity(isSelected ? 1 : 0)
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? DefaultTheme.accent : DefaultTheme.secondaryText)
            Text(project.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected || hovered ? DefaultTheme.primaryText
                                                       : DefaultTheme.secondaryText)
                .lineLimit(1)
            Spacer()
            if hovered {
                // La poignée (glisser-déposer) + la croix (retrait du projet).
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(DefaultTheme.mutedText)
                    HoverIconButton(systemImage: "xmark", help: "Supprimer le projet",
                                    action: onRemove)
                }
            } else if activeCount > 0 {
                Circle()
                    .fill(DefaultTheme.badgeColor(for: .working))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(isSelected ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Carte d'une session vivante : statut, titre, branche — clic pour ouvrir.
struct ActiveSessionCard: View {
    let item: AppModel.SessionItem
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusLabel(item.state)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if let branch = item.branch {
                MonoTag(branch, systemImage: "arrow.triangle.branch",
                        color: DefaultTheme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(hovered ? DefaultTheme.surfaceRaised : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hovered ? DefaultTheme.accent.opacity(0.5) : DefaultTheme.cardBorder,
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// La carte pointillée de la référence : une session SANS objectif, tout de suite.
struct QuickSessionCard: View {
    let onCreate: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text("Session vide rapide").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hovered ? DefaultTheme.accent.opacity(0.5) : DefaultTheme.cardBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCreate)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

/// Ligne d'une session récente : chip d'état, titre, date relative — clic reprend.
struct RecentSessionRow: View {
    let record: SessionRecord
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(DefaultTheme.label(for: record.state).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(DefaultTheme.badgeColor(for: record.state))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(DefaultTheme.badgeColor(for: record.state).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 4))
            Text(record.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if let branch = record.branch {
                MonoTag(branch, systemImage: "arrow.triangle.branch",
                        color: DefaultTheme.mutedText)
            }
            Spacer()
            Text(Self.relative(record.createdAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverSurface(0.6)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onOpen)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Vue Sessions (référence : piles par session — parent + terminaux + webs)

struct SessionsView: View {
    let model: AppModel
    @Binding var selected: DetailSelection?
    let onVisit: (String, String) -> Void
    let onNewSession: (ProjectID) -> Void
    let onShowProject: (ProjectID?) -> Void
    @State private var renameTarget: SessionID?
    @State private var renameText = ""
    /// Groupes repliés (affichage seulement — les sessions continuent de tourner).
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DefaultTheme.cardBorder)
            VStack(spacing: 0) {
                stackTabStrip
                switch selected {
                case .session(let sessionID):
                    SessionDetailView(model: model, sessionID: sessionID,
                                      onBack: onShowProject)
                        .id(sessionID)
                case .webPane(let paneID):
                    if let pane = model.browserPane(paneID) {
                        BrowserPanelView(controller: pane.controller, onVisit: onVisit)
                            .id(paneID)
                            .background(DefaultTheme.contentBackground)
                    } else {
                        placeholder
                    }
                case nil:
                    placeholder
                }
            }
        }
        // ⌘T : un onglet DANS le contexte affiché — web si navigateur, terminal sinon.
        .onReceive(NotificationCenter.default.publisher(for: .loomNewTab)) { _ in
            switch selected {
            case .webPane(let paneID):
                model.browserPane(paneID)?.controller.openTab(urlString: "google.com")
            case .session:
                if let parent = currentStackParent {
                    Task {
                        if let id = await model.launchShell(for: parent) {
                            selected = .session(id)
                        }
                    }
                }
            case nil:
                break
            }
        }
        // Le process de la session affichée est mort (⌃C⌃C, exit) : le tab se
        // ferme tout seul — la carte « inactif » reste dans la pile si la
        // session a une conversation.
        .onChange(of: model.sessions) { _, live in
            if case .session(let id) = selected,
               !live.contains(where: { $0.id == id }) {
                selected = nil
            }
        }
    }

    /// La pile de l'élément affiché : son parent claude, qu'on soit sur lui,
    /// sur un de ses terminaux ou sur un de ses navigateurs.
    private var currentStackParent: AppModel.SessionItem? {
        func dormantItem(_ record: SessionRecord) -> AppModel.SessionItem {
            AppModel.SessionItem(id: record.id, title: record.title, state: record.state,
                                 projectID: record.projectID, branch: record.branch,
                                 parentID: nil, isShell: false, isDormant: true)
        }
        func parentItem(_ id: SessionID) -> AppModel.SessionItem? {
            model.sessions.first { $0.id == id }
                ?? model.dormantSessions.first { $0.id == id }.map(dormantItem)
        }
        switch selected {
        case .session(let id):
            guard let item = parentItem(id) else { return nil }
            if item.isShell, let parentID = item.parentID { return parentItem(parentID) }
            return item
        case .webPane(let paneID):
            guard let parentID = model.browserPane(paneID)?.parentID else { return nil }
            return parentItem(parentID)
        case nil:
            return nil
        }
    }

    /// La barre d'onglets horizontale de la référence : les membres de la pile
    /// (claude, terminaux, navigateurs), croix comprise, « + » = ⌘T.
    @ViewBuilder
    private var stackTabStrip: some View {
        if let parent = currentStackParent {
            let shells = model.sessions.filter { $0.parentID == parent.id && $0.isShell }
            let dormants = model.dormantShells.filter { $0.parentID == parent.id }
            let panes = model.browserPanes.filter { $0.parentID == parent.id }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    StackTab(icon: "sparkle", title: parent.title,
                             isActive: selected == .session(parent.id),
                             isDormant: parent.isDormant,
                             onSelect: {
                                 if parent.isDormant {
                                     Task {
                                         await model.resumeDormant(parent.id)
                                         selected = .session(parent.id)
                                     }
                                 } else {
                                     selected = .session(parent.id)
                                 }
                             },
                             onClose: {
                                 Task {
                                     if parent.isDormant { await model.archiveSession(parent.id) }
                                     else { await model.stopSession(parent.id) }
                                 }
                             })
                    ForEach(shells) { shell in
                        StackTab(icon: "terminal", title: shell.title,
                                 isActive: selected == .session(shell.id),
                                 onSelect: { selected = .session(shell.id) },
                                 onClose: { Task { await model.stopSession(shell.id) } })
                    }
                    ForEach(dormants) { dormant in
                        StackTab(icon: "terminal", title: dormant.title,
                                 isActive: false, isDormant: true,
                                 onSelect: {
                                     Task {
                                         if let id = await model.reopenDormantShell(dormant) {
                                             selected = .session(id)
                                         }
                                     }
                                 },
                                 onClose: { model.forgetDormantShell(dormant) })
                    }
                    ForEach(panes) { pane in
                        StackTab(icon: "globe", title: pane.title,
                                 isActive: selected == .webPane(pane.id),
                                 onSelect: { selected = .webPane(pane.id) },
                                 onClose: {
                                     if selected == .webPane(pane.id) { selected = nil }
                                     model.closeBrowserPane(pane.id)
                                 })
                    }
                    HoverIconButton(systemImage: "plus",
                                    help: "Nouveau terminal dans cette pile (⌘T)") {
                        Task {
                            if let id = await model.launchShell(for: parent) {
                                selected = .session(id)
                            }
                        }
                    }
                    .padding(.leading, 3)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
        }
    }

    private var placeholder: some View {
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

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let globalPanes = model.browserPanes.filter { $0.parentID == nil }
                if !globalPanes.isEmpty {
                    group("NAVIGATEUR", projectID: nil) {
                        ForEach(globalPanes) { pane in paneRow(pane).stackChrome(
                            isSelected: selected == .webPane(pane.id)) }
                    }
                }
                ForEach(model.projects, id: \.id) { project in
                    let items = stackItems(for: project.id)
                    if !items.isEmpty {
                        group(project.name.uppercased(), projectID: project.id) {
                            projectStacks(items: items)
                        }
                    }
                }
                let orphans = stackItems(for: nil)
                if !orphans.isEmpty {
                    group("SANS PROJET", projectID: nil) {
                        projectStacks(items: orphans)
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

    /// Vivantes + inactives (fermées mais pas détruites) : la pile complète du
    /// projet, nom et tabs mémorisés — seules les sessions claude sans aucune
    /// conversation sont écartées (filtre en amont, dans le modèle).
    private func stackItems(for projectID: ProjectID?) -> [AppModel.SessionItem] {
        let live = model.sessions.filter {
            projectID != nil ? $0.projectID == projectID : model.project($0.projectID) == nil
        }
        let dormant = model.dormantSessions
            .filter { projectID != nil ? $0.projectID == projectID
                                       : model.project($0.projectID) == nil }
            .map { record in
                AppModel.SessionItem(id: record.id, title: record.title, state: record.state,
                                     projectID: record.projectID, branch: record.branch,
                                     parentID: nil, isShell: false, isDormant: true)
            }
        return live + dormant
    }

    /// La pile de la référence : la session et ses enfants (terminaux, webs) forment
    /// UN bloc joint ; chaque pile est séparée de la suivante.
    @ViewBuilder
    private func projectStacks(items: [AppModel.SessionItem]) -> some View {
        ForEach(items.filter { !$0.isShell }) { item in
            sessionStack(item,
                         shells: items.filter { $0.parentID == item.id },
                         dormantShells: model.dormantShells.filter { $0.parentID == item.id },
                         panes: model.browserPanes.filter { $0.parentID == item.id })
        }
    }

    private func sessionStack(_ item: AppModel.SessionItem,
                              shells: [AppModel.SessionItem],
                              dormantShells: [AppModel.DormantShell],
                              panes: [AppModel.BrowserPane]) -> some View {
        VStack(spacing: 0) {
            SidebarSessionCard(
                item: item,
                childCount: shells.count + dormantShells.count + panes.count,
                isSelected: selected == .session(item.id),
                onSelect: {
                    if item.isDormant {
                        Task {
                            await model.resumeDormant(item.id)
                            selected = .session(item.id)
                        }
                    } else {
                        selected = .session(item.id)
                    }
                },
                onNewTerminal: {
                    Task {
                        if let id = await model.launchShell(for: item) { selected = .session(id) }
                    }
                },
                onOpenBrowser: {
                    let pane = model.openBrowserPane(for: item.id)
                    selected = .webPane(pane)
                },
                onRename: {
                    renameText = item.title
                    renameTarget = item.id
                },
                onArchive: { Task { await model.archiveSession(item.id) } },
                onClose: {
                    Task {
                        if item.isDormant {
                            await model.archiveSession(item.id)   // inactive : la croix détruit
                        } else {
                            await model.stopSession(item.id)      // vivante : stop → le tab se ferme seul
                        }
                    }
                })
                .stackChrome(isSelected: selected == .session(item.id))
            ForEach(shells) { shell in
                Divider().overlay(DefaultTheme.cardBorder)
                shellRow(shell, parent: item)
                    .stackChrome(isSelected: selected == .session(shell.id))
            }
            ForEach(dormantShells) { dormant in
                Divider().overlay(DefaultTheme.cardBorder)
                dormantShellRow(dormant, parent: item)
                    .stackChrome(isSelected: false)
            }
            ForEach(panes) { pane in
                Divider().overlay(DefaultTheme.cardBorder)
                paneRow(pane, parent: item)
                    .stackChrome(isSelected: selected == .webPane(pane.id))
            }
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    /// SES-04 : le terminal secondaire dans la pile (« >_ Term n · parent »).
    private func shellRow(_ shell: AppModel.SessionItem, parent: AppModel.SessionItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                Label(parent.title, systemImage: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
                // Pas de badge d'état sur les terminaux : working/attend une
                // réponse ne parlent que des sessions claude.
            }
            Spacer()
        }
        .padding(10)
        .contentShape(Rectangle())
        .hoverSurface(0.6)
        .stackQuickActions(
            onNewTerminal: { Task { await model.launchShell(for: parent) } },
            onOpenBrowser: { selected = .webPane(model.openBrowserPane(for: parent.id)) },
            onClose: { Task { await model.stopSession(shell.id) } })
        .onTapGesture { selected = .session(shell.id) }
        .contextMenu {
            Button("Arrêter") { Task { await model.stopSession(shell.id) } }
        }
    }

    /// Un terminal mémorisé dont le process est mort avec l'app : la ligne
    /// reste dans la pile, le clic relance un shell du même nom au même endroit.
    private func dormantShellRow(_ dormant: AppModel.DormantShell,
                                 parent: AppModel.SessionItem) -> some View {
        let parentTitle = parent.title
        return dormantShellRowBody(dormant, parentTitle: parentTitle, parent: parent)
    }

    private func dormantShellRowBody(_ dormant: AppModel.DormantShell, parentTitle: String,
                                     parent: AppModel.SessionItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text(dormant.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Label(parentTitle, systemImage: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .contentShape(Rectangle())
        .hoverSurface(0.6)
        .stackQuickActions(
            onNewTerminal: { Task { await model.launchShell(for: parent) } },
            onOpenBrowser: { selected = .webPane(model.openBrowserPane(for: parent.id)) },
            onClose: { model.forgetDormantShell(dormant) })
        .onTapGesture {
            Task {
                if let id = await model.reopenDormantShell(dormant) {
                    selected = .session(id)
                }
            }
        }
    }

    /// WEB-03 : le navigateur dédié dans la pile (« 🌐 Web n · parent »).
    private func paneRow(_ pane: AppModel.BrowserPane,
                         parent: AppModel.SessionItem? = nil) -> some View {
        let parentTitle = parent?.title
        return paneRowBody(pane, parentTitle: parentTitle, parent: parent)
    }

    private func paneRowBody(_ pane: AppModel.BrowserPane, parentTitle: String?,
                             parent: AppModel.SessionItem?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                if let parentTitle {
                    Label(parentTitle, systemImage: "link")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                }
                if !pane.controller.tabs.isEmpty {
                    Text("\(pane.controller.tabs.count) onglet\(pane.controller.tabs.count > 1 ? "s" : "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(10)
        .contentShape(Rectangle())
        .hoverSurface(0.6)
        .stackQuickActions(
            onNewTerminal: parent.map { p in { Task { await model.launchShell(for: p) } } },
            onOpenBrowser: { selected = .webPane(model.openBrowserPane(for: parent?.id)) },
            onClose: {
                if selected == .webPane(pane.id) { selected = nil }
                model.closeBrowserPane(pane.id)
            })
        .onTapGesture { selected = .webPane(pane.id) }
        .contextMenu {
            Button("Fermer") {
                if selected == .webPane(pane.id) { selected = nil }
                model.closeBrowserPane(pane.id)
            }
        }
    }

    /// Un groupe repliable : chevron + titre cliquables (affichage seulement,
    /// les sessions continuent de tourner) ; écart resserré entre les piles.
    @ViewBuilder
    private func group(_ title: String, projectID: ProjectID?,
                       @ViewBuilder content: () -> some View) -> some View {
        let collapsed = collapsedGroups.contains(title)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if collapsed { collapsedGroups.remove(title) } else { collapsedGroups.insert(title) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.8)
                    }
                    .foregroundStyle(DefaultTheme.groupHeader)
                    .contentShape(Rectangle())
                    .hoverBrightness(0.2)
                }
                .buttonStyle(.plain)
                Spacer()
                if let projectID {
                    HoverIconButton(systemImage: "plus",
                                    help: "Nouvelle session dans ce projet") {
                        onNewSession(projectID)
                    }
                }
            }
            .padding(.horizontal, 2)
            if !collapsed {
                content()
            }
        }
    }

}

/// La sélection d'un élément de pile : liseré accent inséré, fond teinté — comme
/// la référence.
private struct StackChrome: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        content
            .background(isSelected ? DefaultTheme.accent.opacity(0.08) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DefaultTheme.accent : .clear, lineWidth: 1)
                    .padding(2))
    }
}

private extension View {
    func stackChrome(isSelected: Bool) -> some View {
        modifier(StackChrome(isSelected: isSelected))
    }
}

// MARK: - Détail de session (référence : fil d'Ariane + terminal + actions)

struct SessionDetailView: View {
    let model: AppModel
    let sessionID: SessionID
    let onBack: (ProjectID?) -> Void
    @State private var infoShown = false
    @State private var surface: TerminalSurface?
    @State private var gitShown = false
    @State private var gitData: AppModel.GitPanelData?
    @State private var firstResizeDone = false
    /// Incrémenté à chaque clic sur le terminal : la capture clavier reprend le focus.
    @State private var focusTick = 0

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
                        TerminalScreenView(screen: surface.screen, history: surface.history)
                            // TRM-02 : la vue annonce sa grille au PTY ; le task(id:)
                            // s'annule à chaque changement de taille — debounce gratuit
                            // pendant le redimensionnement de la fenêtre.
                            .task(id: proxy.size) {
                                // GeometryReader publie un placeholder (100×100) avant
                                // le vrai layout : ne JAMAIS l'appliquer — l'agent
                                // recevrait un SIGWINCH 20×5 en plein démarrage et
                                // peindrait son interface pour cinq lignes.
                                guard proxy.size.width >= 300, proxy.size.height >= 200 else { return }
                                // Première mesure réelle : immédiate, pour corriger la
                                // grille de lancement avant la bannière de l'agent.
                                // Les suivantes sont debouncées (annulation du task).
                                if firstResizeDone {
                                    try? await Task.sleep(for: .milliseconds(80))
                                    guard !Task.isCancelled else { return }
                                }
                                firstResizeDone = true
                                let grid = TerminalMetrics.grid(fitting: proxy.size)
                                surface.resize(cols: grid.cols, rows: grid.rows)
                                model.noteTerminalGrid(cols: grid.cols, rows: grid.rows)
                            }
                            // SES-05bis : la frappe va au champ de saisie de
                            // l'agent — pas de barre à nous. La capture vit SOUS
                            // le feed (le clavier suit le premier répondant, pas
                            // la géométrie) ; cliquer le terminal reprend le focus.
                            .background(KeyCaptureView(focusTick: focusTick) { surface.send($0) })
                            .contentShape(Rectangle())
                            .onTapGesture { focusTick += 1 }
                    }
                    .background(DefaultTheme.contentBackground)
                    if gitShown { gitPanel }
                }
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
            // ← retour à la page du projet (référence Xirp).
            HoverIconButton(systemImage: "arrow.left", help: "Retour au projet") {
                onBack(item?.projectID)
            }
            Divider().frame(height: 16).overlay(DefaultTheme.cardBorder)
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
            // ⌄ la fiche de la session : identité, worktree, dates.
            HoverIconButton(systemImage: "chevron.down", help: "Infos de la session") {
                infoShown.toggle()
            }
            .popover(isPresented: $infoShown, arrowEdge: .bottom) { sessionInfoPanel }
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

    /// La fiche de la session (référence Xirp) : ce qu'on sait de vrai —
    /// identité, worktree, agent, dates. Rien d'inventé.
    private var sessionInfoPanel: some View {
        let record = model.sessionInfo(sessionID)
        let workingDir = record?.worktreePath
            ?? model.project(item?.projectID ?? record?.projectID)?.path
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("ID de session", record?.id.rawValue.uuidString.lowercased() ?? "—") {
                HoverIconButton(systemImage: "doc.on.doc", help: "Copier l'identifiant") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record?.id.rawValue.uuidString.lowercased() ?? "",
                                                   forType: .string)
                }
            }
            infoRow("Dossier de travail", workingDir ?? "—") {
                if let workingDir {
                    HoverIconButton(systemImage: "folder", help: "Ouvrir dans le Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: workingDir))
                    }
                }
            }
            if let branch = record?.branch { infoRow("Branche", branch) }
            infoRow("Agent", record?.agentID ?? "claude-code")
            HStack(spacing: 10) {
                Text("État")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .frame(width: 110, alignment: .leading)
                StatusLabel(item?.state ?? record?.state ?? .starting)
            }
            if let created = record?.createdAt {
                infoRow("Créée", Self.infoDate.string(from: created))
            }
            if let code = record?.exitCode {
                infoRow("Code de sortie", "\(code)")
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(DefaultTheme.surface)
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ label: String, _ value: String,
                         @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DefaultTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
            trailing()
        }
    }

    private static let infoDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

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

/// Actions rapides d'une ligne de pile, révélées au survol : petit bloc à
/// droite (terminal, navigateur, croix) — disponibles sur TOUS les onglets.
struct StackQuickActionsModifier: ViewModifier {
    var onNewTerminal: (() -> Void)?
    var onOpenBrowser: (() -> Void)?
    let onClose: () -> Void
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovered {
                    HStack(spacing: 2) {
                        if let onNewTerminal {
                            HoverIconButton(systemImage: "terminal",
                                            help: "Nouveau terminal dans ce worktree",
                                            action: onNewTerminal)
                        }
                        if let onOpenBrowser {
                            HoverIconButton(systemImage: "globe",
                                            help: "Navigateur dédié dans cette pile",
                                            action: onOpenBrowser)
                        }
                        HoverIconButton(systemImage: "xmark", help: "Fermer",
                                        action: onClose)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(DefaultTheme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
                }
            }
            .onHover { hovered = $0 }
            .animation(.hover, value: hovered)
    }
}

extension View {
    func stackQuickActions(onNewTerminal: (() -> Void)? = nil,
                           onOpenBrowser: (() -> Void)? = nil,
                           onClose: @escaping () -> Void) -> some View {
        modifier(StackQuickActionsModifier(onNewTerminal: onNewTerminal,
                                           onOpenBrowser: onOpenBrowser,
                                           onClose: onClose))
    }
}

/// Icône d'action des cartes : grise au repos, accent au survol — le pointeur
/// dit ce qui est cliquable.
struct HoverIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(hovered ? DefaultTheme.accent : DefaultTheme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - Carte parent d'une pile (icônes au survol — terminal, navigateur)

struct SidebarSessionCard: View {
    let item: AppModel.SessionItem
    let childCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onNewTerminal: () -> Void
    let onOpenBrowser: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                if hovered {
                    // Même cluster que les lignes de pile : espacement identique
                    // partout, quel que soit le type d'onglet.
                    HStack(spacing: 2) {
                        HoverIconButton(systemImage: "terminal",
                                        help: "Nouveau terminal dans ce worktree",
                                        action: onNewTerminal)
                        HoverIconButton(systemImage: "globe",
                                        help: "Navigateur dédié dans cette pile",
                                        action: onOpenBrowser)
                        HoverIconButton(systemImage: "xmark",
                                        help: "Fermer la session",
                                        action: onClose)
                    }
                }
            }
            if let branch = item.branch {
                MonoTag(branch, systemImage: "arrow.triangle.branch",
                        color: DefaultTheme.secondaryText)
            }
            HStack(spacing: 6) {
                StatusLabel(item.state)
                if childCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        Text("\(childCount)").font(.system(size: 10))
                    }
                    .foregroundStyle(DefaultTheme.secondaryText)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .contextMenu {
            Button("Renommer…", action: onRename)
            Button("Nouveau terminal", action: onNewTerminal)
            Button("Navigateur dédié", action: onOpenBrowser)
            Button("Archiver", action: onArchive)
        }
    }
}
