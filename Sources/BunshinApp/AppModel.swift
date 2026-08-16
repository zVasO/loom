import BunshinAgents
import BunshinCore
import BunshinIPC
import BunshinPersistence
import BunshinSessions
import BunshinTerminal
import Foundation
import Observation

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
    private let adapter = ClaudeCodeAdapter()
    private var socketURL: URL { supportDirectory.appendingPathComponent("bunshin.sock") }
    private var helperURL: URL { supportDirectory.appendingPathComponent("bunshin-hook") }

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
            try store.markLiveSessionsInterrupted()

            let transcripts = try FileTranscriptSink(
                directory: supportDirectory.appendingPathComponent("transcripts"))
            let manager = SessionManager(
                runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(),
                                                                 transcript: transcripts),
                store: store)
            self.manager = manager

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
            let id = try await manager.launch(SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: prompt),
                workingDirectory: directory,
                samplingInterval: .milliseconds(500)))
            if let token = await manager.hookToken(for: id) {
                tokenRegistry.register(token: token, session: id)
            }
            sessions.insert(SessionItem(id: id, title: prompt.isEmpty ? "Session" : prompt,
                                        state: .starting), at: 0)
        } catch {
            startupError = String(describing: error)
        }
    }

    public func stopSession(_ id: SessionID) async {
        await manager?.stop(id)
    }

    public func surface(for id: SessionID) async -> TerminalSurface? {
        await manager?.runtime(for: id)?.surface()
    }
}
