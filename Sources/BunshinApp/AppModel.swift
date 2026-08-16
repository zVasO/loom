import BunshinAgents
import BunshinCore
import BunshinIPC
import BunshinPersistence
import BunshinSessions
import BunshinTerminal
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
    }

    public private(set) var sessions: [SessionItem] = []
    public private(set) var startupError: String?

    private(set) var manager: SessionManager?
    private var hookServer: HookSocketServer?
    private let supportDirectory: URL
    private var socketURL: URL { supportDirectory.appendingPathComponent("bunshin.sock") }

    /// L'adapter parle au CLI avec le câblage hooks complet (ADR-0005).
    private var adapter: ClaudeCodeAdapter {
        ClaudeCodeAdapter(hooks: .init(helper: Self.helperBinaryURL(fallback: supportDirectory),
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
        } catch {
            startupError = String(describing: error)
        }
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

    public func launchSession(prompt: String, in directory: URL) async {
        guard let manager else { return }
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: prompt,
                                               hookToken: token),
                workingDirectory: directory,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            // GIT-01 : un repo Git → un worktree isolé par session, jamais le dossier nu.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                spec.worktree = .create(repo: directory, slug: Self.slug(from: prompt))
            }
            let id = try await manager.launch(spec)
            tokenRegistry.register(token: token, session: id)
            sessions.insert(SessionItem(id: id, title: prompt.isEmpty ? "Session" : prompt,
                                        state: .starting), at: 0)
        } catch {
            startupError = String(describing: error)
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

    public func surface(for id: SessionID) async -> TerminalSurface? {
        await manager?.runtime(for: id)?.surface()
    }
}
