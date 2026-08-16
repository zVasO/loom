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
            })
            case .sessions: SessionsView(model: model, selected: $selected,
                                         onVisit: { url, title in model.recordVisit(url: url, title: title) },
                                         onNewSession: { project in
                                             createSession(in: project)
                                         })
            }
        }
        .background(DefaultTheme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
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

// MARK: - Vue Sessions (référence : piles par session — parent + terminaux + webs)

struct SessionsView: View {
    let model: AppModel
    @Binding var selected: DetailSelection?
    let onVisit: (String, String) -> Void
    let onNewSession: (ProjectID) -> Void
    @State private var renameTarget: SessionID?
    @State private var renameText = ""
    /// Groupes repliés (affichage seulement — les sessions continuent de tourner).
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DefaultTheme.cardBorder)
            switch selected {
            case .session(let sessionID):
                SessionDetailView(model: model, sessionID: sessionID)
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
                        ForEach(globalPanes) { pane in paneRow(pane, parentTitle: nil).stackChrome(
                            isSelected: selected == .webPane(pane.id)) }
                    }
                }
                ForEach(model.projects, id: \.id) { project in
                    let items = model.sessions.filter { $0.projectID == project.id }
                    let interrupted = model.interruptedSessions.filter { $0.projectID == project.id }
                    if !items.isEmpty || !interrupted.isEmpty {
                        group(project.name.uppercased(), projectID: project.id) {
                            projectStacks(items: items)
                            ForEach(interrupted, id: \.id) { record in interruptedCard(record) }
                        }
                    }
                }
                let orphans = model.sessions.filter { model.project($0.projectID) == nil }
                if !orphans.isEmpty {
                    group("SANS PROJET", projectID: nil) {
                        projectStacks(items: orphans)
                    }
                }
                if !model.historySessions.isEmpty {
                    group("HISTORIQUE", projectID: nil) {
                        ForEach(model.historySessions.prefix(12), id: \.id) { record in
                            historyCard(record)
                        }
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

    /// La pile de la référence : la session et ses enfants (terminaux, webs) forment
    /// UN bloc joint ; chaque pile est séparée de la suivante.
    @ViewBuilder
    private func projectStacks(items: [AppModel.SessionItem]) -> some View {
        ForEach(items.filter { !$0.isShell }) { item in
            sessionStack(item,
                         shells: items.filter { $0.parentID == item.id },
                         panes: model.browserPanes.filter { $0.parentID == item.id })
        }
    }

    private func sessionStack(_ item: AppModel.SessionItem,
                              shells: [AppModel.SessionItem],
                              panes: [AppModel.BrowserPane]) -> some View {
        VStack(spacing: 0) {
            SidebarSessionCard(
                item: item,
                childCount: shells.count + panes.count,
                isSelected: selected == .session(item.id),
                onSelect: { selected = .session(item.id) },
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
                onArchive: { Task { await model.archiveSession(item.id) } })
                .stackChrome(isSelected: selected == .session(item.id))
            ForEach(shells) { shell in
                Divider().overlay(DefaultTheme.cardBorder)
                shellRow(shell, parentTitle: item.title)
                    .stackChrome(isSelected: selected == .session(shell.id))
            }
            ForEach(panes) { pane in
                Divider().overlay(DefaultTheme.cardBorder)
                paneRow(pane, parentTitle: item.title)
                    .stackChrome(isSelected: selected == .webPane(pane.id))
            }
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    /// SES-04 : le terminal secondaire dans la pile (« >_ Term n · parent »).
    private func shellRow(_ shell: AppModel.SessionItem, parentTitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                Label(parentTitle, systemImage: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
                StatusLabel(shell.state)
            }
            Spacer()
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { selected = .session(shell.id) }
        .contextMenu {
            Button("Arrêter") { Task { await model.stopSession(shell.id) } }
        }
    }

    /// WEB-03 : le navigateur dédié dans la pile (« 🌐 Web n · parent »).
    private func paneRow(_ pane: AppModel.BrowserPane, parentTitle: String?) -> some View {
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
                }
                .buttonStyle(.plain)
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
            if !collapsed {
                content()
            }
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
                        TerminalScreenView(screen: surface.screen, history: surface.history)
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
                // Le helper / FLOTTE au-dessus du feed : il ne participe pas au
                // layout — la grille du PTY ne bouge pas d'un pixel quand il
                // apparaît, le feed de la session reste immobile.
                .overlay(alignment: .bottomLeading) {
                    if skillHelperActive && !skillSuggestions.isEmpty {
                        skillHelper
                            .frame(maxWidth: 560)
                            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
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
                    Button(action: onNewTerminal) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Nouveau terminal dans ce worktree")
                    Button(action: onOpenBrowser) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Navigateur dédié dans cette pile")
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Renommer…", action: onRename)
            Button("Nouveau terminal", action: onNewTerminal)
            Button("Navigateur dédié", action: onOpenBrowser)
            Button("Archiver", action: onArchive)
        }
    }
}
