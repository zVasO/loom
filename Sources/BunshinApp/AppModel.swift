import BunshinAgents
import BunshinCore
import BunshinGit
import BunshinIPC
import BunshinPersistence
import BunshinSessions
import BunshinTerminal
import BunshinWeb
import Foundation
import Observation
import UserNotifications

/// STA-04 : notification système quand une session attend une réponse.
/// Second adapter du seam SessionNotifier (l'espion de test est le premier).
struct UserNotificationsNotifier: SessionNotifier {
    func sessionNeedsInput(_ session: SessionID, title: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // swift run sans bundle
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "La session attend une réponse"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: session.rawValue.uuidString,
                                  content: content, trigger: nil))
    }
}

/// Racine de composition de l'app : démarre le store (marquage `interrupted` à
/// l'ouverture — UC-7), le manager, le serveur IPC des hooks, et projette les
/// sessions pour SwiftUI.
@MainActor
@Observable
public final class AppModel {

    public struct SessionItem: Identifiable, Equatable {
        public let id: SessionID
        public var title: String
        public var state: SessionState
        public var projectID: ProjectID?
        public var branch: String?
        /// SES-04 : un terminal secondaire (shell libre) rattaché à une session agent.
        public var parentID: SessionID?
        public var isShell: Bool = false
    }

    public private(set) var sessions: [SessionItem] = []
    /// PRJ-03 : la sidebar regroupe par projet.
    public private(set) var projects: [ProjectRecord] = []
    public var selectedProject: ProjectID?
    /// UC-7 : proposées à la Reprise au relancement.
    public private(set) var interruptedSessions: [SessionRecord] = []
    /// SES-07 : terminées/échouées/archivées, consultables.
    public private(set) var historySessions: [SessionRecord] = []
    public private(set) var startupError: String?

    public func clearError() {
        startupError = nil
    }

    private(set) var manager: SessionManager?
    private var hookServer: HookSocketServer?
    private let supportDirectory: URL
    private var socketURL: URL { supportDirectory.appendingPathComponent("bunshin.sock") }

    /// UIX-06 : le binaire claude localisé au lancement (les apps GUI ne voient pas
    /// le PATH du shell — un chemin absolu est la seule voie fiable).
    public private(set) var claudePath: URL? = ClaudeLocator.locate()
    public var claudeSearchedLocations: [String] { ClaudeLocator.wellKnownLocations }

    /// L'adapter parle au CLI avec le câblage hooks complet (ADR-0005).
    private var adapter: ClaudeCodeAdapter {
        ClaudeCodeAdapter(executable: claudePath?.path ?? "claude",
                          hooks: .init(helper: Self.helperBinaryURL(fallback: supportDirectory),
                                       socket: socketURL))
    }

    /// En développement, `bunshin-hook` est un produit frère de l'app ; empaqueté,
    /// il vivra dans le bundle puis sera copié dans Application Support.
    static func helperBinaryURL(fallback supportDirectory: URL) -> URL {
        let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("bunshin-hook")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return supportDirectory.appendingPathComponent("bunshin-hook")
    }

    public init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Bunshin")
    }

    /// Appelé au lancement de l'app. Toute erreur est affichée, jamais fatale.
    public func start() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let store = try SessionStore(path: supportDirectory.appendingPathComponent("bunshin.sqlite").path)
            self.store = store
            try store.markLiveSessionsInterrupted()

            let transcripts = try FileTranscriptSink(
                directory: supportDirectory.appendingPathComponent("transcripts"))
            let manager = SessionManager(
                runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(),
                                                                 transcript: transcripts),
                store: store,
                notifier: UserNotificationsNotifier())
            self.manager = manager
            if Bundle.main.bundleIdentifier != nil {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }

            let registry = tokenRegistry
            let server = HookSocketServer(
                socketPath: socketURL,
                validate: { token in registry.session(for: token) },
                handler: { [weak self] session, payload in
                    guard let self else { return }
                    Task { await self.manager?.ingest(payload, for: session) }
                })
            try server.start()
            hookServer = server

            Task { await self.observeStates(of: manager) }
            reloadPersistedSessions()
        } catch {
            startupError = String(describing: error)
        }
    }

    /// Tous les enregistrements connus — compteurs et dates des cartes projet.
    public private(set) var allRecords: [SessionRecord] = []

    private func reloadPersistedSessions() {
        let all = ((try? store?.allSessions()) ?? nil) ?? []
        allRecords = all
        // Une session fermée sans conversation persistée n'a rien à montrer ni à
        // reprendre : elle n'encombre pas les listes (les épaves d'identifiants
        // d'avant-correctif disparaissent du même coup).
        interruptedSessions = all.filter {
            $0.state == .interrupted && ClaudeNativeSessions.exists($0.id)
        }
        historySessions = all.filter {
            [.completed, .failed, .archived].contains($0.state) && ClaudeNativeSessions.exists($0.id)
        }
        projects = ((try? store?.activeProjects()) ?? nil) ?? []
        if selectedProject == nil { selectedProject = projects.first?.id }
    }

    /// SES-04 : un shell libre dans le worktree de la session parente — la carte
    /// apparaît indentée sous elle (« Term n »). Les shells meurent avec l'app et
    /// ne sont jamais proposés à la Reprise (aucune conversation native).
    public func launchShell(for parent: SessionItem) async -> SessionID? {
        guard let manager else { return nil }
        let record = (try? store?.session(id: parent.id)) ?? nil
        let directory = record?.worktreePath.map(URL.init(fileURLWithPath:))
            ?? project(parent.projectID).map { URL(fileURLWithPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let count = sessions.filter { $0.parentID == parent.id }.count + 1
        var spec = SessionManager.SessionSpec(
            command: Command(executable: shell, arguments: ["-l"]),
            workingDirectory: directory,
            samplingInterval: .seconds(1))
        spec.title = "Term \(count)"
        spec.projectID = parent.projectID
        do {
            let id = try await manager.launch(spec)
            sessions.append(SessionItem(id: id, title: "Term \(count)", state: .starting,
                                        projectID: parent.projectID, branch: parent.branch,
                                        parentID: parent.id, isShell: true))
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    // MARK: - Panneaux navigateur (WEB-03 : un navigateur dédié DANS la pile d'une session)

    public struct BrowserPane: Identifiable {
        public let id = UUID()
        public var title: String
        public var parentID: SessionID?
        public let controller: BrowserController

        @MainActor
        init(title: String, parentID: SessionID?) {
            self.title = title
            self.parentID = parentID
            self.controller = BrowserController()
        }
    }

    public private(set) var browserPanes: [BrowserPane] = []

    /// Chaque ouverture crée un panneau dédié, enfant de la session (ou global si nil).
    @discardableResult
    public func openBrowserPane(for parent: SessionID?) -> UUID {
        let count = browserPanes.filter { $0.parentID == parent }.count + 1
        let pane = BrowserPane(title: "Web \(count)", parentID: parent)
        browserPanes.append(pane)
        return pane.id
    }

    public func closeBrowserPane(_ id: UUID) {
        browserPanes.removeAll { $0.id == id }
    }

    public func browserPane(_ id: UUID) -> BrowserPane? {
        browserPanes.first { $0.id == id }
    }

    /// SES-05 : renommage — la carte, le fil d'Ariane et la base suivent.
    public func renameSession(_ id: SessionID, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        try? store?.rename(session: id, to: cleaned)
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = cleaned
        }
        reloadPersistedSessions()
    }

    /// Nom auto à la naissance, dans la vibe de la référence : `<projet>-<hex>`.
    static func generatedName(project: ProjectRecord?) -> String {
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(project?.name ?? "session")-\(suffix)"
    }

    /// Le helper `/` du champ de saisie : skills du worktree de la session (le
    /// checkout embarque ceux du projet — SKL-08) + skills globaux.
    public func skills(for id: SessionID) -> [SkillEntry] {
        let record = (try? store?.session(id: id)) ?? nil
        let projectDirectory = (record?.worktreePath
            ?? record?.projectID.flatMap { pid in project(pid)?.path })
            .map { URL(fileURLWithPath: $0).appendingPathComponent(".claude/skills") }
        return SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory,
                                  projectDirectory: projectDirectory)
    }

    // MARK: - Compteurs des cartes projet (référence : « 2 active · 4 sessions »)

    public func activeCount(for projectID: ProjectID) -> Int {
        sessions.filter { $0.projectID == projectID && [.working, .needsInput, .starting, .idle].contains($0.state) }.count
    }

    public func sessionCount(for projectID: ProjectID) -> Int {
        allRecords.filter { $0.projectID == projectID }.count
    }

    public func lastActivity(for projectID: ProjectID) -> Date? {
        allRecords.filter { $0.projectID == projectID }.map(\.createdAt).max()
    }

    /// PRJ-01 : ajoute un projet en pointant un dossier ; s'il est un repo Git, la
    /// branche courante est détectée. L'app ne modifie jamais le dossier.
    public func addProject(at url: URL) async {
        let isGit = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        let branch = isGit ? try? await GitService().currentBranch(in: url) : nil
        let record = ProjectRecord(id: ProjectID(), name: url.lastPathComponent,
                                   path: url.path, defaultBranch: branch, createdAt: Date())
        try? store?.insertProject(record)
        reloadPersistedSessions()
        selectedProject = record.id
    }

    public func project(_ id: ProjectID?) -> ProjectRecord? {
        projects.first { $0.id == id }
    }

    /// UC-7 : la Reprise — même identifiant, hooks ré-injectés, worktree d'origine.
    /// Si claude n'a jamais persisté la conversation (session lancée mais jamais
    /// utilisée), `--resume` n'aurait rien à reprendre : on relance À NEUF sous le
    /// même UUID dans le même worktree — « Reprendre » ne peut plus échouer.
    public func resumeSession(_ record: SessionRecord) async {
        guard let manager else { return }
        let token = UUID().uuidString
        let command = ClaudeNativeSessions.exists(record.id)
            ? adapter.resumeCommand(session: record.id, hookToken: token)
            : adapter.launchCommand(session: record.id, initialPrompt: nil, hookToken: token)
        let directory = record.worktreePath.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        do {
            try await manager.resume(record, command: command, workingDirectory: directory,
                                     samplingInterval: .milliseconds(500), hookToken: token)
            tokenRegistry.register(token: token, session: record.id)
            sessions.insert(SessionItem(id: record.id, title: record.title, state: .starting,
                                        projectID: record.projectID, branch: record.branch), at: 0)
            interruptedSessions.removeAll { $0.id == record.id }
        } catch {
            startupError = String(describing: error)
        }
    }

    /// SES-07 : archive et bascule dans l'historique.
    public func archiveSession(_ id: SessionID) async {
        await manager?.archive(id)
        sessions.removeAll { $0.id == id }
        reloadPersistedSessions()
    }

    /// Le serveur IPC valide de façon SYNCHRONE sur sa propre queue : le registre des
    /// tokens vit derrière un verrou, jamais derrière le MainActor.
    private let tokenRegistry = TokenRegistry()

    final class TokenRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var sessionsByToken: [String: SessionID] = [:]
        func register(token: String, session: SessionID) {
            lock.withLock { sessionsByToken[token] = session }
        }
        func session(for token: String) -> SessionID? {
            lock.withLock { sessionsByToken[token] }
        }
    }

    private func observeStates(of manager: SessionManager) async {
        let updates = await manager.stateUpdates()
        for await update in updates {
            if let index = sessions.firstIndex(where: { $0.id == update.id }) {
                sessions[index].state = update.state
            }
        }
    }

    // MARK: - Actions (UC-1, SES-06)

    /// UC-1, à la référence : un clic lance claude immédiatement dans le projet —
    /// aucune saisie préalable ; l'objectif se tape ensuite dans le terminal.
    /// (`prompt` reste possible pour la palette ou des raccourcis futurs.)
    /// Retourne l'identifiant de la session créée.
    @discardableResult
    public func launchSession(prompt: String? = nil, in projectID: ProjectID? = nil) async -> SessionID? {
        guard let manager else { return nil }
        if let projectID { selectedProject = projectID }
        let project = project(selectedProject)
        let directory = project.map { URL(fileURLWithPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let initialPrompt = (prompt?.isEmpty == false) ? prompt : nil
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: initialPrompt,
                                               hookToken: token),
                workingDirectory: directory,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = project?.id
            // Un seul UUID de bout en bout : celui de `--session-id` — la Reprise en dépend.
            spec.sessionID = sessionID
            spec.title = initialPrompt ?? Self.generatedName(project: project)
            // GIT-01 : un repo Git → un worktree isolé par session, jamais le dossier nu.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                spec.worktree = .create(repo: directory, slug: Self.slug(from: initialPrompt ?? ""))
            }
            let id = try await manager.launch(spec)
            tokenRegistry.register(token: token, session: id)
            let record = (try? store?.session(id: id)) ?? nil
            sessions.insert(SessionItem(id: id, title: record?.title ?? "Session",
                                        state: .starting, projectID: project?.id,
                                        branch: record?.branch), at: 0)
            reloadPersistedSessions()
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    /// « Corrige le bug de cache ! » → `corrige-le-bug-de-cache` (GIT-02).
    static func slug(from prompt: String) -> String {
        let cleaned = prompt.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-").prefix(40)
        return slug.isEmpty ? "session" : String(slug)
    }

    private var store: SessionStore?

    /// Historique de la barre d'adresse (WEB-01) — best-effort, jamais bloquant.
    public func recordVisit(url: String, title: String) {
        try? store?.recordVisit(url: url, title: title, at: Date())
    }

    public func stopSession(_ id: SessionID) async {
        await manager?.stop(id)
    }

    public struct GitPanelData {
        public let changes: [FileChange]
        public let diff: String
    }

    /// GIT-03 : status + diff du worktree de la session, en lecture seule.
    public func gitPanel(for id: SessionID) async -> GitPanelData? {
        let record = (try? store?.session(id: id)) ?? nil
        guard let path = record?.worktreePath else { return nil }
        let worktree = URL(fileURLWithPath: path)
        let git = GitService()
        let changes = (try? await git.status(in: worktree)) ?? []
        let diff = (try? await git.diff(in: worktree)) ?? ""
        return GitPanelData(changes: changes, diff: diff)
    }

    public func surface(for id: SessionID) async -> TerminalSurface? {
        await manager?.runtime(for: id)?.surface()
    }
}
