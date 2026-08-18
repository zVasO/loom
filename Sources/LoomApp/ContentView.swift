import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomTerminal
import LoomUI
import LoomWeb
import SwiftUI

// Structure of the validated reference: custom navbar (Projects / Sessions / +),
// Projects view as a centered column, Sessions view as grouped sidebar + detail.

/// The woven logo, loaded once from the module resources.
struct LogoMark: View {
    let size: CGFloat
    private static let image: NSImage? = Bundle.module
        .url(forResource: "loom-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(DefaultTheme.accent)
        }
    }
}

enum MainTab {
    case projects, sessions, overview, settings
}

/// The Sessions view's detail: a session… or the browser, as a tab
/// like the others (WEB-03).
enum DetailSelection: Hashable {
    case session(SessionID)
    case webPane(UUID)
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: MainTab = .projects
    /// Where Mission Control was toggled FROM — a second ⌘G returns there.
    @State private var tabBeforeOverview: MainTab = .projects
    @State private var tabBeforeSettings: MainTab = .projects
    @AppStorage("loom.shortcut.missionControl") private var keyMissionControl = "g"
    @AppStorage("loom.shortcut.palette") private var keyPalette = "k"
    @State private var selected: DetailSelection?
    @State private var paletteShown = false

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
            case .overview: MissionControlView(model: model, onOpen: { id in
                selected = .session(id)
                tab = .sessions
            })
            case .settings: SettingsPage(model: model)
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
        .preferredColorScheme(ThemeStore.shared.palette.isLight ? .light : .dark)
        .onAppear {
            model.start()
            applyTheme()
        }
        // The app follows the project you are working in: override, else global.
        .onChange(of: model.selectedProject) { applyTheme() }
        .onChange(of: selected) { applyTheme() }
        .onChange(of: tab) { applyTheme() }
        .onReceive(NotificationCenter.default.publisher(for: .loomThemeChanged)) { _ in
            applyTheme()
        }
        .task {
            // Autonomous repro (diagnostics): LOOM_AUTOTEST=1 simulates the
            // "+" click two seconds after launch — same code path.
            guard ProcessInfo.processInfo.environment["LOOM_AUTOTEST"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1))
            NSApp.windows.first?.setFrame(NSRect(x: 40, y: 40, width: 1500, height: 950),
                                          display: true)
            try? await Task.sleep(for: .seconds(1))
            createSession(in: model.projects.first?.id)
            // Keystrokes go through the REAL path (window → first responder →
            // PTY): the dump must show "salut" in the agent's input field.
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
        .onReceive(NotificationCenter.default.publisher(for: .loomFrameRateChanged)) { _ in
            model.applyFrameRate()
        }
        .sheet(isPresented: $paletteShown) { palette }
        .alert("Incomplete startup", isPresented: .constant(model.startupError != nil)) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.startupError ?? "")
        }
    }

    private var contextProjectID: ProjectID? {
        if tab == .sessions, case .session(let id) = selected {
            return model.sessions.first(where: { $0.id == id })?.projectID
                ?? model.dormantSessions.first(where: { $0.id == id })?.projectID
                ?? model.selectedProject
        }
        return model.selectedProject
    }

    private func applyTheme() {
        ThemeStore.shared.apply(projectID: contextProjectID)
    }

    // MARK: - Navigation bar

    private var navbar: some View {
        HStack(spacing: 10) {
            // Space for the traffic lights (title bar hidden).
            Spacer().frame(width: 70)
            LogoMark(size: 20)
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

            // v2 — Mission Control: the fleet at a glance (⌘G). A TOGGLE:
            // press again to return to the view you came from.
            Button {
                if tab == .overview {
                    tab = tabBeforeOverview
                } else {
                    tabBeforeOverview = tab
                    tab = .overview
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(tab == .overview ? DefaultTheme.accent
                                                      : DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(tab == .overview ? DefaultTheme.surfaceRaised : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(keyMissionControl.first ?? "g"), modifiers: .command)
            .help("Mission Control — every live session (⌘\(keyMissionControl.uppercased()))")
            GhostButton(systemImage: "globe") {
                // WEB-03: the browser is born INSIDE the current session's stack.
                var parent: SessionID?
                if case .session(let id) = selected { parent = id }
                let pane = model.openBrowserPane(for: parent)
                tab = .sessions
                selected = .webPane(pane)
            }
            Button {
                paletteShown = true
            } label: {
                Text("⌘\(keyPalette.uppercased())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    .hoverBrightness(0.1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(keyPalette.first ?? "k"), modifiers: .command)
            // Settings: the gear toggles the in-app page.
            Button {
                if tab == .settings {
                    tab = tabBeforeSettings
                } else {
                    tabBeforeSettings = tab
                    tab = .settings
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(tab == .settings ? DefaultTheme.accent
                                                      : DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(tab == .settings ? DefaultTheme.surfaceRaised : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(DefaultTheme.background)
    }

    // MARK: - ⌘K action palette (Raycast-style)

    /// Everything ⌘K can do, assembled with full app context. Closures capture
    /// the navigation state — the palette itself stays dumb.
    private var paletteActions: [PaletteAction] {
        var actions: [PaletteAction] = []

        // Navigation
        actions.append(PaletteAction(id: "nav.projects", icon: "house",
                                     title: "Go to Projects", subtitle: "View all projects",
                                     section: "Navigation") { tab = .projects })
        actions.append(PaletteAction(id: "nav.sessions", icon: "square.stack",
                                     title: "Go to Sessions", subtitle: "The stacks and their tabs",
                                     section: "Navigation") { tab = .sessions })
        actions.append(PaletteAction(id: "nav.overview", icon: "square.grid.2x2",
                                     title: "Open Mission Control",
                                     subtitle: "Every live session in a grid",
                                     section: "Navigation",
                                     shortcut: "⌘\(keyMissionControl.uppercased())") { tab = .overview })
        actions.append(PaletteAction(id: "nav.settings", icon: "gearshape",
                                     title: "Open Settings",
                                     subtitle: "Shortcuts, themes, projects",
                                     section: "Navigation", shortcut: "⌘,") { tab = .settings })

        // Actions
        actions.append(PaletteAction(id: "act.newSession", icon: "plus",
                                     title: "New claude session",
                                     subtitle: "In the current project",
                                     section: "Actions", shortcut: "⌘N") {
            createSession(in: model.selectedProject)
        })
        if case .session(let id) = selected,
           let item = model.sessions.first(where: { $0.id == id }) {
            let parent = item.isShell
                ? model.sessions.first { $0.id == item.parentID } ?? item
                : item
            actions.append(PaletteAction(id: "act.newTerminal", icon: "terminal",
                                         title: "New terminal in the stack",
                                         subtitle: "Same worktree as \(parent.title)",
                                         section: "Actions", shortcut: "⌘T") {
                Task {
                    if let shellID = await model.launchShell(for: parent) {
                        selected = .session(shellID)
                    }
                }
            })
            actions.append(PaletteAction(id: "act.newBrowser", icon: "globe",
                                         title: "New browser in the stack",
                                         subtitle: "Dedicated web pane under \(parent.title)",
                                         section: "Actions") {
                selected = .webPane(model.openBrowserPane(for: parent.id))
            })
            actions.append(PaletteAction(id: "act.rename", icon: "pencil",
                                         title: "Rename session",
                                         subtitle: item.title,
                                         section: "Actions") {
                NotificationCenter.default.post(name: .loomRenameSession, object: nil)
            })
            actions.append(PaletteAction(id: "act.stop", icon: "xmark",
                                         title: "Close session",
                                         subtitle: "Stops claude — resumable as inactive",
                                         section: "Actions") {
                Task { await model.stopSession(parent.id) }
            })
        }

        // Themes — quick-apply, filterable by name.
        for palette in ThemePalette.all {
            actions.append(PaletteAction(id: "theme.\(palette.name)", icon: "paintpalette",
                                         title: "Set theme: \(palette.name)",
                                         subtitle: "Global theme",
                                         section: "Theme") {
                ThemeStore.shared.setGlobalTheme(palette.name)
                NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
            })
        }

        // Projects
        for project in model.projects {
            actions.append(PaletteAction(id: "project.\(project.id.rawValue.uuidString)",
                                         icon: "folder",
                                         title: project.name,
                                         subtitle: "Open project",
                                         section: "Projects") {
                model.selectedProject = project.id
                tab = .projects
            })
        }

        // Sessions (live + resumable)
        let dormantIDs = Set(model.dormantSessions.map(\.id))
        let entries = model.sessions.filter { !$0.isShell }.map { ($0.title, $0.id) }
            + model.dormantSessions.map { ($0.title, $0.id) }
        for (title, id) in entries {
            actions.append(PaletteAction(id: "session.\(id.rawValue.uuidString)",
                                         icon: "sparkle",
                                         title: title,
                                         subtitle: dormantIDs.contains(id)
                                             ? "Resume session" : "Open session",
                                         section: "Sessions") {
                openSessionByID(id)
            })
        }
        return actions
    }

    private var palette: some View {
        ActionPaletteView(actions: paletteActions,
                          transcriptSearch: { model.searchTranscripts($0) },
                          onOpenSession: { openSessionByID($0) },
                          isPresented: $paletteShown)
    }

    /// Opens a session found by search: resumes it first when it is dormant.
    private func openSessionByID(_ id: SessionID) {
        paletteShown = false
        if model.sessions.contains(where: { $0.id == id }) {
            selected = .session(id)
            tab = .sessions
        } else {
            Task {
                await model.resumeDormant(id)
                selected = .session(id)
                tab = .sessions
            }
        }
    }

    /// The reference's +: a claude session starts immediately,
    /// the goal is typed in the terminal.
    private func createSession(in projectID: ProjectID?) {
        Task {
            if let id = await model.launchSession(in: projectID) {
                selected = .session(id)
                tab = .sessions
            }
        }
    }

}

// MARK: - Projects view (reference: project sidebar + detail — goal → session)

struct ProjectsView: View {
    let model: AppModel
    let onOpenSessions: (ProjectID) -> Void
    let onNewSession: (ProjectID) -> Void
    let onOpenSession: (SessionID) -> Void
    @State private var goal = ""
    @FocusState private var goalFocused: Bool
    @State private var draggedProject: ProjectID?
    @State private var removalTarget: ProjectRecord?
    @State private var fanOut = 1
    // v4 — PR review
    @State private var prs: [GitHubService.PullRequest] = []
    @State private var prsLoading = false
    @State private var selectedPR: GitHubService.PullRequest?
    @State private var prDetail: GitHubService.PRDetail?
    @State private var prDiff = ""
    @State private var prTour: PRTour?
    @State private var tourLoading = false
    @State private var reviewBody = ""
    @State private var prActionOutput: String?
    @State private var prActionBusy = false
    // P1 perf: filesystem scans live in .task, never in body.
    @State private var loadedSkills: [SkillEntry] = []
    @State private var loadedRules: [AppModel.RuleFile] = []
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
        case all = "All", global = "Global", project = "Project"
    }
    @State private var filesPath = ""
    @State private var gitData: AppModel.ProjectGitData?

    enum ProjectTab: String, CaseIterable {
        case overview = "Overview", git = "Git", files = "Files"
        case skills = "Skills", rules = "Rules", prs = "PRs"
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

    // MARK: Project sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PROJECTS")
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
            GhostButton("Add project", systemImage: "plus") { pickProject() }
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .frame(width: 216)
        .background(DefaultTheme.background)
        .alert("Delete “\(removalTarget?.name ?? "")”?",
               isPresented: Binding(get: { removalTarget != nil },
                                    set: { if !$0 { removalTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let target = removalTarget { model.removeProject(target.id) }
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: {
            Text("The project disappears from Loom — the local folder and the session history are not touched.")
        }
    }

    // MARK: Project detail

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
                        case .prs: prsTab(project)
                        }
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DefaultTheme.background)
        // Switching projects resets the tab navigation.
        .onChange(of: current?.id) {
            projectTab = .overview
            filesPath = ""
            gitData = nil
            viewedDocument = nil
            resetPRState()
        }
        .onChange(of: projectTab) {
            viewedDocument = nil
            if projectTab != .prs { resetPRState() }
        }
        .task(id: "\(current?.id.rawValue.uuidString ?? "")-\(projectTab.rawValue)") {
            guard let project = current else { return }
            switch projectTab {
            case .git: gitData = await model.projectGit(project.id)
            case .skills: loadedSkills = model.skills(forProject: project.id)
            case .rules: loadedRules = model.ruleFiles(for: project.id)
            default: break
            }
        }
    }

    /// The reference's tab row: accent underline on the active one.
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

    // MARK: Git tab — the project's root folder

    @ViewBuilder
    private func gitTab(_ project: ProjectRecord) -> some View {
        if let git = gitData {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    MonoTag(git.branch, systemImage: "arrow.triangle.branch")
                    Text("· project root (worktrees live in their sessions)")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                if git.changes.isEmpty {
                    Text("No pending changes")
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
                Text("Reading the repository…")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    // MARK: Files tab — read-only navigation

    private func filesTab(_ project: ProjectRecord) -> some View {
        let entries = model.listFiles(in: project.id, at: filesPath)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HoverIconButton(systemImage: "house", help: "Project root") { filesPath = "" }
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

    // MARK: Skills tab — what agents can invoke here (cards, Xirp ref.)

    private func skillsTab(_ project: ProjectRecord) -> some View {
        let skills = loadedSkills
        let globals = skills.filter { $0.scope == .global }
        let projets = skills.filter { $0.scope == .project }
        let filtered = switch skillFilter {
        case .all: skills
        case .global: globals
        case .project: projets
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                filterPill("All (\(skills.count))", isActive: skillFilter == .all) { skillFilter = .all }
                filterPill("Global (\(globals.count))", isActive: skillFilter == .global) { skillFilter = .global }
                filterPill("Project (\(projets.count))", isActive: skillFilter == .project) { skillFilter = .project }
            }
            if filtered.isEmpty {
                Text("No skills — add folders in .claude/skills (project) or ~/.claude/skills (global).")
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

    /// Opens a file INSIDE the app: text displayed in place, binary flagged.
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

    /// Built-in viewer: back, title, path, Finder — mono content, light
    /// markdown for .md files (bold, code…), selectable.
    private func documentViewer(_ document: ViewedDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HoverIconButton(systemImage: "arrow.left", help: "Back") {
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
                    Text("Binary file — open it from the Finder")
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

    // MARK: Rules tab — the instructions agents will read (cards)

    private func rulesTab(_ project: ProjectRecord) -> some View {
        let rules = loadedRules
        return VStack(alignment: .leading, spacing: 16) {
            if rules.isEmpty {
                Text("No rule files (CLAUDE.md, AGENTS.md, CONTEXT.md…) at the root.")
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

    /// The reference's central gesture: describing the goal HERE launches the
    /// session — the prompt goes straight into the agent's terminal.
    private func goalField(_ project: ProjectRecord) -> some View {
        HStack(spacing: 10) {
            TextField("What are we building? Describe your goal — Enter starts a session…",
                      text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DefaultTheme.primaryText)
                .focused($goalFocused)
                .onSubmit { submitGoal(project) }
            // v3 — fan-out: the same goal, N parallel sessions, N worktrees.
            Menu {
                ForEach(1...4, id: \.self) { count in
                    Button("×\(count)\(count > 1 ? " parallel sessions" : " session")") {
                        fanOut = count
                    }
                }
            } label: {
                Text("×\(fanOut)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(fanOut > 1 ? DefaultTheme.accent : DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Launch the goal in N parallel sessions, each on its own worktree")
        }
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
        let count = fanOut
        Task {
            var first: SessionID?
            for _ in 0..<count {
                if let id = await model.launchSession(prompt: trimmed, in: project.id) {
                    if first == nil { first = id }
                }
            }
            if let first { onOpenSession(first) }
        }
    }

    // MARK: Active sessions

    private func activeSection(_ project: ProjectRecord) -> some View {
        let items = model.sessions.filter { $0.projectID == project.id && !$0.isShell }
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("ACTIVE", count: items.count,
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

    // MARK: Recent sessions

    private func recentSection(_ project: ProjectRecord) -> some View {
        let records = (model.interruptedSessions + model.historySessions)
            .filter { $0.projectID == project.id }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
        return Group {
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("RECENT", count: records.count,
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

    // MARK: PRs tab (v4) — inbox, detail, verdict, guided tour

    private func resetPRState() {
        prs = []
        selectedPR = nil
        prDetail = nil
        prDiff = ""
        prTour = nil
        reviewBody = ""
        prActionOutput = nil
    }

    @ViewBuilder
    private func prsTab(_ project: ProjectRecord) -> some View {
        if !GitHubService.isAvailable {
            Text("Install the GitHub CLI (brew install gh) and authenticate (gh auth login) to review pull requests here.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
        } else if let pr = selectedPR {
            prDetailView(pr, project: project)
        } else {
            prListView(project)
        }
    }

    private func prListView(_ project: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("OPEN PULL REQUESTS", count: prs.count,
                              color: DefaultTheme.badgeColor(for: .working))
                Spacer()
                if prsLoading { ProgressView().controlSize(.small) }
                GhostButton(systemImage: "arrow.clockwise") { loadPRs(project) }
            }
            if prs.isEmpty && !prsLoading {
                Text("No open pull request — or gh is not authenticated for this repo.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            VStack(spacing: 6) {
                ForEach(prs) { pr in
                    PRRow(pr: pr) {
                        selectedPR = pr
                        loadPRDetail(pr, project: project)
                    }
                }
            }
        }
        .task(id: current?.id) { loadPRs(project) }
    }

    private func loadPRs(_ project: ProjectRecord) {
        prsLoading = true
        Task {
            prs = await model.listPRs(for: project.id)
            prsLoading = false
        }
    }

    private func loadPRDetail(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        prDetail = nil
        prDiff = ""
        prTour = nil
        Task {
            prDetail = await model.prDetail(pr.number, in: project.id)
            prDiff = await model.prDiff(pr.number, in: project.id)
        }
    }

    private func prDetailView(_ pr: GitHubService.PullRequest,
                              project: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                HoverIconButton(systemImage: "arrow.left", help: "Back to the list") {
                    selectedPR = nil
                }
                Text("#\(pr.number)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.accent)
                Text(pr.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                GhostButton("GitHub", systemImage: "arrow.up.forward.square") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
            }

            // The playful part: the guided tour.
            tourSection(pr, project: project)

            if let detail = prDetail {
                if !detail.body.isEmpty {
                    Text(detail.body)
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if !detail.reviews.isEmpty || !detail.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("CONVERSATION",
                                      count: detail.reviews.count + detail.comments.count,
                                      color: DefaultTheme.secondaryText)
                        ForEach(Array(detail.reviews.enumerated()), id: \.offset) { _, review in
                            conversationRow(author: review.author,
                                            chip: review.state.replacingOccurrences(of: "_", with: " ").lowercased(),
                                            body: review.body)
                        }
                        ForEach(Array(detail.comments.enumerated()), id: \.offset) { _, comment in
                            conversationRow(author: comment.author, chip: nil, body: comment.body)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }

            if !prDiff.isEmpty {
                let files = DiffParser.parse(prDiff)
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("DIFF", count: files.count,
                                  color: DefaultTheme.secondaryText)
                    // GitHub-style side-by-side: old on the left, new on the
                    // right, aligned and tinted, per-file collapsible sections.
                    SplitDiffView(files: files)
                }
            }

            // Verdict bar.
            VStack(alignment: .leading, spacing: 8) {
                TextField("Review comment…", text: $reviewBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...5)
                    .padding(10)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                HStack(spacing: 8) {
                    AccentButton("Approve") { submitReview(pr, .approve, project) }
                    GhostButton("Request changes", systemImage: "exclamationmark.bubble") {
                        submitReview(pr, .requestChanges, project)
                    }
                    GhostButton("Comment", systemImage: "bubble.left") {
                        submitReview(pr, .comment, project)
                    }
                    if prActionBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let prActionOutput {
                    Text(prActionOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(prActionOutput.hasSuffix("✓") ? DefaultTheme.groupHeader
                                                                       : DefaultTheme.secondaryText)
                }
            }
        }
    }

    private func submitReview(_ pr: GitHubService.PullRequest,
                              _ verdict: GitHubService.Verdict,
                              _ project: ProjectRecord) {
        if verdict != .approve, reviewBody.trimmingCharacters(in: .whitespaces).isEmpty {
            prActionOutput = "Write the comment first."
            return
        }
        prActionBusy = true
        Task {
            let error = await model.submitPRReview(pr.number, verdict: verdict,
                                                   body: reviewBody, in: project.id)
            prActionOutput = error ?? "Review sent ✓"
            if error == nil {
                reviewBody = ""
                loadPRDetail(pr, project: project)
            }
            prActionBusy = false
        }
    }

    private func conversationRow(author: String, chip: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("@" + author)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                if let chip, !chip.isEmpty {
                    Text(chip)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(chip.contains("changes") ? DefaultTheme.danger
                                                                  : DefaultTheme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
            }
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func tourSection(_ pr: GitHubService.PullRequest,
                             project: ProjectRecord) -> some View {
        if let tour = prTour {
            PRTourView(tour: tour) {
                Task {
                    if let id = await model.askGuide(about: pr.number, title: pr.title,
                                                     tour: tour, in: project.id) {
                        onOpenSession(id)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                GhostButton(tourLoading ? "The guide is reading the PR…" : "Explain this PR",
                            systemImage: "sparkles") {
                    guard !tourLoading else { return }
                    tourLoading = true
                    Task {
                        prTour = await model.generateTour(pr.number, in: project.id)
                        if prTour == nil { prActionOutput = "The guide could not read this PR." }
                        tourLoading = false
                    }
                }
                if tourLoading { ProgressView().controlSize(.small) }
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
            LogoMark(size: 72)
            Text("Add your first project")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text("A local folder — if it contains a Git repo, each session\nwill work isolated on its own worktree.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
                .multilineTextAlignment(.center)
            AccentButton("Add project", systemImage: "plus") { pickProject() }
                .padding(.top, 6)
            if model.claudePath == nil {
                VStack(spacing: 4) {
                    Label("Claude Code not found", systemImage: "exclamationmark.triangle.fill")
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

/// Horizontal tab of a stack (reference: the Terminal bar): icon, title,
/// close cross visible on hover or on the active one. Dormant = dimmed.
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
                HoverIconButton(systemImage: "xmark", help: "Close", action: onClose)
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

/// The reference's skill card: sparkle in a tinted square, name, two
/// lines of description, scope chip.
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
        return Label(isProject ? "project" : "global",
                     systemImage: isProject ? "folder" : "globe")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Rule card: document in a tinted square, name, preview — click to open.
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

/// v4 — a pull request in the inbox: number, title, author, branch, checks
/// dot, review-state chip. Green dot = CI passing; red = at least one failure.
struct PRRow: View {
    let pr: GitHubService.PullRequest
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pr.checksPassing ? DefaultTheme.groupHeader : DefaultTheme.danger)
                .frame(width: 7, height: 7)
            Text("#\(pr.number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("@" + pr.author)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                    MonoTag(pr.branch, systemImage: "arrow.triangle.branch",
                            color: DefaultTheme.mutedText)
                }
            }
            Spacer()
            if pr.isDraft {
                Text("draft")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
            }
            if !pr.reviewDecision.isEmpty {
                Text(pr.reviewDecision.replacingOccurrences(of: "_", with: " ").lowercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(pr.reviewDecision == "APPROVED" ? DefaultTheme.groupHeader
                                                                     : DefaultTheme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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

/// v4 — the guided tour rendered: pitch, story chapters, playful risk gauge,
/// warnings with file:line, and the door to an interactive guide session.
struct PRTourView: View {
    let tour: PRTour
    let onAskGuide: () -> Void

    private var gauge: (label: String, color: Color) {
        switch tour.riskLevel {
        case "quiet": ("Quiet waters", DefaultTheme.groupHeader)
        case "dragon": ("There be dragons", DefaultTheme.danger)
        default: ("Watch out", DefaultTheme.badgeColor(for: .needsInput))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DefaultTheme.accent)
                Text(tour.pitch)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                Label(gauge.label, systemImage: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(gauge.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(gauge.color.opacity(0.14), in: Capsule())
            }
            ForEach(Array(tour.chapters.enumerated()), id: \.offset) { index, chapter in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(DefaultTheme.accent)
                        .frame(width: 20, height: 20)
                        .background(DefaultTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(chapter.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DefaultTheme.primaryText)
                            if !chapter.file.isEmpty {
                                MonoTag(chapter.file, color: DefaultTheme.mutedText)
                            }
                        }
                        Text(chapter.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                }
            }
            if !tour.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(tour.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(gauge.color)
                            Text("\(warning.file)\(warning.line.map { ":\($0)" } ?? "")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DefaultTheme.primaryText)
                            Text(warning.note)
                                .font(.system(size: 10))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            }
            GhostButton("Ask the guide", systemImage: "bubble.left.and.text.bubble.right") {
                onAskGuide()
            }
            .help("Opens an interactive claude session, checked out on this PR, primed as its guide")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(DefaultTheme.accent.opacity(0.35), lineWidth: 1))
    }
}

/// Project detail tab: accent underline on the active one, text lightened
/// on hover (Xirp reference).
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

/// Reorder on hover during drag: the row moves live as soon as it is
/// dragged over another — the drop only finalizes.
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

/// Sidebar row: accent bar + orange folder when the project is open.
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
                // The handle (drag and drop) + the cross (project removal).
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(DefaultTheme.mutedText)
                    HoverIconButton(systemImage: "xmark", help: "Delete project",
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

/// Card of a live session: status, title, branch — click to open.
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

/// The reference's dashed card: a session WITHOUT a goal, right away.
struct QuickSessionCard: View {
    let onCreate: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text("Quick empty session").font(.system(size: 12, weight: .medium))
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

/// Row of a recent session: state chip, title, relative date — click resumes.
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

// MARK: - Sessions view (reference: stacks per session — parent + terminals + webs)

struct SessionsView: View {
    let model: AppModel
    @Binding var selected: DetailSelection?
    let onVisit: (String, String) -> Void
    let onNewSession: (ProjectID) -> Void
    let onShowProject: (ProjectID?) -> Void
    @State private var renameTarget: SessionID?
    @State private var renameText = ""
    /// Collapsed groups (display only — the sessions keep running).
    @State private var collapsedGroups: Set<String> = []
    /// Close requested but not yet confirmed: every close cross goes through here.
    @State private var pendingClose: PendingClose?

    struct PendingClose {
        var message: String
        var action: () -> Void
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DefaultTheme.cardBorder)
            VStack(spacing: 0) {
                stackTabStrip
                switch selected {
                case .session(let sessionID):
                    SessionDetailView(model: model, sessionID: sessionID,
                                      onBack: onShowProject,
                                      selectedAfterReview: { selected = .session($0) })
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
        .alert("Close this tab?",
               isPresented: Binding(get: { pendingClose != nil },
                                    set: { if !$0 { pendingClose = nil } })) {
            Button("Close", role: .destructive) {
                pendingClose?.action()
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text(pendingClose?.message ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomRenameSession)) { _ in
            if case .session(let id) = selected {
                renameText = model.sessions.first(where: { $0.id == id })?.title ?? ""
                renameTarget = id
            }
        }
        // ⌘T only exists in a terminal or browser context, and NECESSARILY
        // creates a tab of the same type, in the horizontal bar.
        .onReceive(NotificationCenter.default.publisher(for: .loomNewTab)) { _ in
            guard let context = stripContext else { return }
            switch context.kind {
            case .web:
                selected = .webPane(model.openBrowserPane(for: context.parent?.id))
            case .terminal:
                if let parent = context.parent {
                    Task {
                        if let id = await model.launchShell(for: parent) {
                            selected = .session(id)
                        }
                    }
                }
            }
        }
        // The displayed session's process is dead (⌃C⌃C, exit): the tab
        // closes on its own — the "inactive" card stays in the stack if the
        // session has a conversation.
        .onChange(of: model.sessions) { _, live in
            if case .session(let id) = selected,
               !live.contains(where: { $0.id == id }) {
                selected = nil
            }
        }
    }

    /// The horizontal bar's context: it exists ONLY if the open tab is a
    /// terminal or a browser — never on the claude session itself.
    enum StripKind { case terminal, web }

    private func stackParentItem(_ id: SessionID) -> AppModel.SessionItem? {
        model.sessions.first { $0.id == id }
            ?? model.dormantSessions.first { $0.id == id }.map { record in
                AppModel.SessionItem(id: record.id, title: record.title, state: record.state,
                                     projectID: record.projectID, branch: record.branch,
                                     parentID: nil, isShell: false, isDormant: true)
            }
    }

    private var stripContext: (parent: AppModel.SessionItem?, kind: StripKind)? {
        switch selected {
        case .session(let id):
            guard let item = model.sessions.first(where: { $0.id == id }), item.isShell,
                  let parentID = item.parentID else { return nil }
            return (stackParentItem(parentID), .terminal)
        case .webPane(let paneID):
            guard let pane = model.browserPane(paneID) else { return nil }
            return (pane.parentID.flatMap(stackParentItem), .web)
        case nil:
            return nil
        }
    }

    /// Single-type horizontal tab bar (Terminal reference): on a terminal,
    /// the stack's terminals; on a browser, its browsers.
    /// The "+" and ⌘T always create a tab OF THE SAME type.
    @ViewBuilder
    private var stackTabStrip: some View {
        if let context = stripContext {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    switch context.kind {
                    case .terminal:
                        if let parent = context.parent {
                            let shells = model.sessions.filter { $0.parentID == parent.id && $0.isShell }
                            let dormants = model.dormantShells.filter { $0.parentID == parent.id }
                            ForEach(shells) { shell in
                                StackTab(icon: "terminal", title: shell.title,
                                         isActive: selected == .session(shell.id),
                                         onSelect: { selected = .session(shell.id) },
                                         onClose: {
                                             pendingClose = PendingClose(
                                                 message: "“\(shell.title)” will be stopped.") {
                                                 Task { await model.stopSession(shell.id) }
                                             }
                                         })
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
                                         onClose: {
                                             pendingClose = PendingClose(
                                                 message: "“\(dormant.title)” will be removed from the remembered stack.") {
                                                 model.forgetDormantShell(dormant)
                                             }
                                         })
                            }
                        }
                    case .web:
                        let panes = model.browserPanes.filter { $0.parentID == context.parent?.id }
                        ForEach(panes) { pane in
                            StackTab(icon: "globe", title: pane.title,
                                     isActive: selected == .webPane(pane.id),
                                     onSelect: { selected = .webPane(pane.id) },
                                     onClose: {
                                         pendingClose = PendingClose(
                                             message: "“\(pane.title)” will be closed — its tabs will be lost.") {
                                             if selected == .webPane(pane.id) { selected = nil }
                                             model.closeBrowserPane(pane.id)
                                         }
                                     })
                        }
                    }
                    HoverIconButton(systemImage: "plus",
                                    help: context.kind == .terminal
                                        ? "New terminal (⌘T)" : "New browser (⌘T)") {
                        switch context.kind {
                        case .terminal:
                            if let parent = context.parent {
                                Task {
                                    if let id = await model.launchShell(for: parent) {
                                        selected = .session(id)
                                    }
                                }
                            }
                        case .web:
                            selected = .webPane(model.openBrowserPane(for: context.parent?.id))
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
            Text("No open session")
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("Pick one on the left, or ⌘K")
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
                    group("BROWSER", projectID: nil) {
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
                    group("NO PROJECT", projectID: nil) {
                        projectStacks(items: orphans)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(DefaultTheme.background)
        .alert("Rename session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.renameSession(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    /// Live + inactive (closed but not destroyed): the project's complete
    /// stack, name and tabs remembered — only claude sessions with no
    /// conversation at all are excluded (filtered upstream, in the model).
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

    /// The reference's stack: the session and its children (terminals, webs)
    /// form ONE joined block; each stack is separated from the next.
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
                    pendingClose = item.isDormant
                        ? PendingClose(message: "“\(item.title)” is inactive: it will be destroyed (archived), permanently.") {
                            Task { await model.archiveSession(item.id) }
                        }
                        : PendingClose(message: "claude will be stopped cleanly — “\(item.title)” will remain resumable as “inactive”.") {
                            Task { await model.stopSession(item.id) }
                        }
                })
                .stackChrome(isSelected: selected == .session(item.id))
            // Individual tabs live in the HORIZONTAL bar: the vertical
            // stack only shows one group row per type.
            if !shells.isEmpty || !dormantShells.isEmpty {
                Divider().overlay(DefaultTheme.cardBorder)
                terminalGroupRow(parent: item, shells: shells, dormants: dormantShells)
                    .stackChrome(isSelected: shells.contains { selected == .session($0.id) })
            }
            if !panes.isEmpty {
                Divider().overlay(DefaultTheme.cardBorder)
                webGroupRow(parent: item, panes: panes)
                    .stackChrome(isSelected: panes.contains { selected == .webPane($0.id) })
            }
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    /// SES-04: THE stack's terminal group — a single row, the tab detail
    /// lives in the horizontal bar.
    private func terminalGroupRow(parent: AppModel.SessionItem,
                                  shells: [AppModel.SessionItem],
                                  dormants: [AppModel.DormantShell]) -> some View {
        let count = shells.count + dormants.count
        return HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(shells.isEmpty ? DefaultTheme.mutedText : DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(count > 1 ? "Terminals" : (shells.first?.title ?? dormants.first?.title ?? "Terminal"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(shells.isEmpty ? DefaultTheme.secondaryText
                                                        : DefaultTheme.primaryText)
                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DefaultTheme.surfaceRaised, in: Capsule())
                    }
                }
                Label(parent.title, systemImage: "link")
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
            onClose: {
                pendingClose = PendingClose(
                    message: count > 1 ? "The stack's \(count) terminals will be closed."
                                       : "The stack's terminal will be closed.") {
                    Task {
                        for shell in shells { await model.stopSession(shell.id) }
                        for dormant in dormants { model.forgetDormantShell(dormant) }
                    }
                }
            })
        .onTapGesture {
            if let first = shells.first {
                selected = .session(first.id)
            } else if let dormant = dormants.first {
                Task {
                    if let id = await model.reopenDormantShell(dormant) {
                        selected = .session(id)
                    }
                }
            }
        }
    }

    /// WEB-03: THE stack's browser group — same principle.
    private func webGroupRow(parent: AppModel.SessionItem,
                             panes: [AppModel.BrowserPane]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(panes.count > 1 ? "Web" : (panes.first?.title ?? "Web"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DefaultTheme.primaryText)
                    if panes.count > 1 {
                        Text("\(panes.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DefaultTheme.surfaceRaised, in: Capsule())
                    }
                }
                Label(parent.title, systemImage: "link")
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
            onClose: {
                pendingClose = PendingClose(
                    message: panes.count > 1 ? "The stack's \(panes.count) browsers will be closed — tabs lost."
                                             : "The stack's browser will be closed — tabs lost.") {
                    for pane in panes {
                        if selected == .webPane(pane.id) { selected = nil }
                        model.closeBrowserPane(pane.id)
                    }
                }
            })
        .onTapGesture {
            if let first = panes.first { selected = .webPane(first.id) }
        }
    }

    /// WEB-03: the dedicated browser in the stack ("🌐 Web n · parent").
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
                    Text("\(pane.controller.tabs.count) tab\(pane.controller.tabs.count > 1 ? "s" : "")")
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
            Button("Close") {
                if selected == .webPane(pane.id) { selected = nil }
                model.closeBrowserPane(pane.id)
            }
        }
    }

    /// A collapsible group: clickable chevron + title (display only, the
    /// sessions keep running); tightened gap between the stacks.
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
                                    help: "New session in this project") {
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

/// Selection of a stack element: inset accent outline, tinted background — like
/// the reference.
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

// MARK: - Session detail (reference: breadcrumb + terminal + actions)

struct SessionDetailView: View {
    let model: AppModel
    let sessionID: SessionID
    let onBack: (ProjectID?) -> Void
    /// v3 — opens the reviewer session that the Ship panel just launched.
    var selectedAfterReview: ((SessionID) -> Void)?
    @State private var infoShown = false
    @State private var surface: TerminalSurface?
    @State private var gitShown = false
    @State private var gitData: AppModel.GitPanelData?
    @State private var firstResizeDone = false
    /// Incremented on each click on the terminal: the key capture regains focus.
    @State private var focusTick = 0
    @State private var shipMessage = ""
    @State private var shipOutput: String?
    @State private var shipBusy = false
    @State private var followUpShown = false
    @State private var followUpDraft = ""

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
                        TerminalScreenView(screen: surface.screen, history: surface.history,
                                           historyBase: surface.historyBase)
                            // TRM-02: the view announces its grid to the PTY; the task(id:)
                            // cancels on every size change — free debounce
                            // while the window is being resized.
                            .task(id: proxy.size) {
                                // GeometryReader publishes a placeholder (100×100) before
                                // the real layout: NEVER apply it — the agent
                                // would receive a 20×5 SIGWINCH mid-startup and
                                // paint its interface for five lines.
                                guard proxy.size.width >= 300, proxy.size.height >= 200 else { return }
                                // First real measurement: immediate, to correct the
                                // launch grid before the agent's banner.
                                // The following ones are debounced (task cancellation).
                                if firstResizeDone {
                                    try? await Task.sleep(for: .milliseconds(80))
                                    guard !Task.isCancelled else { return }
                                }
                                firstResizeDone = true
                                let grid = TerminalMetrics.grid(fitting: proxy.size)
                                surface.resize(cols: grid.cols, rows: grid.rows)
                                model.noteTerminalGrid(cols: grid.cols, rows: grid.rows)
                            }
                            // SES-05bis: keystrokes go to the agent's input
                            // field — no bar of our own. The capture lives UNDER
                            // the feed (the keyboard follows the first responder,
                            // not the geometry); clicking the terminal regains focus.
                            .background(KeyCaptureView(focusTick: focusTick) { surface.send($0) })
                            .contentShape(Rectangle())
                            .onTapGesture { focusTick += 1 }
                            // claude's own boot (plugins, MCP handshakes) takes
                            // seconds — a silent black screen reads as broken.
                            .overlay {
                                if surface.screen.revision == 0 {
                                    VStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text("claude is starting…")
                                            .font(.system(size: 12))
                                            .foregroundStyle(DefaultTheme.secondaryText)
                                        Text("Plugins and MCP servers load first — unauthenticated MCP servers slow this down (run /mcp).")
                                            .font(.system(size: 10))
                                            .foregroundStyle(DefaultTheme.mutedText)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: 380)
                                    }
                                }
                            }
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
            // ← back to the project page (Xirp reference).
            HoverIconButton(systemImage: "arrow.left", help: "Back to project") {
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
            // ⌄ the session's record: identity, worktree, dates.
            HoverIconButton(systemImage: "chevron.down", help: "Session info") {
                infoShown.toggle()
            }
            .popover(isPresented: $infoShown, arrowEdge: .bottom) { sessionInfoPanel }
            if let state = item?.state {
                StatusLabel(state)
            }
            Spacer()
            // v3 — pipeline: queue the next goal, it launches when this ends.
            GhostButton(systemImage: "arrow.turn.down.right") {
                followUpDraft = model.followUps[sessionID] ?? ""
                followUpShown.toggle()
            }
            .overlay(alignment: .topTrailing) {
                if model.followUps[sessionID] != nil {
                    Circle().fill(DefaultTheme.accent).frame(width: 5, height: 5)
                        .offset(x: -3, y: 5)
                }
            }
            .help("Chain: when this session ends, start the next one")
            .popover(isPresented: $followUpShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When this session ends…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    TextField("…start a new session with this goal", text: $followUpDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(8)
                        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                        .frame(width: 320)
                        .onSubmit {
                            model.setFollowUp(followUpDraft, for: sessionID)
                            followUpShown = false
                        }
                    HStack {
                        GhostButton("Clear") {
                            model.setFollowUp(nil, for: sessionID)
                            followUpDraft = ""
                            followUpShown = false
                        }
                        Spacer()
                        AccentButton("Queue") {
                            model.setFollowUp(followUpDraft, for: sessionID)
                            followUpShown = false
                        }
                    }
                }
                .padding(14)
                .background(DefaultTheme.surface)
                .preferredColorScheme(.dark)
            }
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

    /// The session's record (Xirp reference): what we actually know —
    /// identity, worktree, agent, dates. Nothing invented.
    private var sessionInfoPanel: some View {
        let record = model.sessionInfo(sessionID)
        let workingDir = record?.worktreePath
            ?? model.project(item?.projectID ?? record?.projectID)?.path
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Session ID", record?.id.rawValue.uuidString.lowercased() ?? "—") {
                HoverIconButton(systemImage: "doc.on.doc", help: "Copy identifier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record?.id.rawValue.uuidString.lowercased() ?? "",
                                                   forType: .string)
                }
            }
            infoRow("Working directory", workingDir ?? "—") {
                if let workingDir {
                    HoverIconButton(systemImage: "folder", help: "Open in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: workingDir))
                    }
                }
            }
            if let branch = record?.branch { infoRow("Branch", branch) }
            infoRow("Agent", record?.agentID ?? "claude-code")
            // v3 — real counters, read from claude's own native records.
            if let usage = ClaudeNativeSessions.usage(for: sessionID) {
                infoRow("Context", "\(Self.tokens(usage.contextTokens)) tokens (last turn)")
                infoRow("Output", "\(Self.tokens(usage.outputTokens)) tokens total")
            }
            HStack(spacing: 10) {
                Text("State")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .frame(width: 110, alignment: .leading)
                StatusLabel(item?.state ?? record?.state ?? .starting)
            }
            if let created = record?.createdAt {
                infoRow("Created", Self.infoDate.string(from: created))
            }
            if let code = record?.exitCode {
                infoRow("Exit code", "\(code)")
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

    static func tokens(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    private static let infoDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    private var gitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Changes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton(systemImage: "arrow.clockwise") {
                    Task { gitData = await model.gitPanel(for: sessionID) }
                }
            }
            shipSection
            Divider().overlay(DefaultTheme.cardBorder)
            if let gitData {
                if gitData.changes.isEmpty {
                    Text("Clean worktree").font(.system(size: 12))
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
                Text("No worktree for this session")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: 420)
        .background(DefaultTheme.background)
    }

    /// v2 — Ship: commit, publish and open a PR without leaving the session.
    /// Every outcome is reported verbatim (stderr included) — no phantom success.
    private var shipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Commit message…", text: $shipMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                AccentButton("Commit") {
                    let message = shipMessage.trimmingCharacters(in: .whitespaces)
                    guard !message.isEmpty else { shipOutput = "Write a commit message first."; return }
                    shipBusy = true
                    Task {
                        let error = await model.shipCommit(sessionID, message: message)
                        shipOutput = error ?? "Committed ✓"
                        if error == nil { shipMessage = "" }
                        gitData = await model.gitPanel(for: sessionID)
                        shipBusy = false
                    }
                }
            }
            HStack(spacing: 6) {
                GhostButton("Push", systemImage: "arrow.up.circle") {
                    shipBusy = true
                    Task {
                        let error = await model.shipPush(sessionID)
                        shipOutput = error ?? "Pushed to origin ✓"
                        shipBusy = false
                    }
                }
                GhostButton("Review", systemImage: "eyes") {
                    Task {
                        if let id = await model.launchReviewSession(reviewing: sessionID) {
                            selectedAfterReview?(id)
                        }
                    }
                }
                .help("A second claude reviews this worktree's diff")
                if AppModel.ghPath != nil {
                    GhostButton("Create PR", systemImage: "arrow.triangle.pull") {
                        shipBusy = true
                        Task {
                            if let result = await model.shipCreatePR(sessionID) {
                                shipOutput = result.message
                                if result.success,
                                   let url = URL(string: result.message.split(separator: "\n").last.map(String.init) ?? "") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            shipBusy = false
                        }
                    }
                }
                if shipBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let shipOutput {
                Text(shipOutput)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(shipOutput.hasSuffix("✓") ? DefaultTheme.groupHeader
                                                               : DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
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

/// Quick actions of a stack row, revealed on hover: small block on the
/// right (terminal, browser, cross) — available on ALL tabs.
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
                                            help: "New terminal in this worktree",
                                            action: onNewTerminal)
                        }
                        if let onOpenBrowser {
                            HoverIconButton(systemImage: "globe",
                                            help: "Dedicated browser in this stack",
                                            action: onOpenBrowser)
                        }
                        HoverIconButton(systemImage: "xmark", help: "Close",
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

/// Card action icon: gray at rest, accent on hover — the pointer
/// tells what is clickable.
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

// MARK: - Stack parent card (icons on hover — terminal, browser)

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
                    // Same cluster as the stack rows: identical spacing
                    // everywhere, whatever the tab type.
                    HStack(spacing: 2) {
                        HoverIconButton(systemImage: "terminal",
                                        help: "New terminal in this worktree",
                                        action: onNewTerminal)
                        HoverIconButton(systemImage: "globe",
                                        help: "Dedicated browser in this stack",
                                        action: onOpenBrowser)
                        HoverIconButton(systemImage: "xmark",
                                        help: "Close session",
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
            Button("Rename…", action: onRename)
            Button("New terminal", action: onNewTerminal)
            Button("Dedicated browser", action: onOpenBrowser)
            Button("Archive", action: onArchive)
        }
    }
}
