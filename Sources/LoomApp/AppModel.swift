import LoomAgents
import LoomAPI
import LoomCore
import LoomGit
import LoomIPC
import LoomPersistence
import LoomSessions
import LoomTerminal
import LoomUI
import LoomWeb
import Foundation
import Observation
import SwiftUI
import UserNotifications
import os

/// STA-04: system notification when a session needs input.
/// Second adapter of the SessionNotifier seam (the test spy is the first).
struct UserNotificationsNotifier: SessionNotifier {
    static let replyCategory = "loom.session.needsInput"
    static let replyAction = "loom.session.reply"

    func sessionNeedsInput(_ session: SessionID, title: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // swift run without a bundle
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "The session needs input"
        // v3 — actionable: reply straight from the banner, no app switch.
        content.categoryIdentifier = Self.replyCategory
        content.userInfo = ["sessionID": session.rawValue.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: session.rawValue.uuidString,
                                  content: content, trigger: nil))
    }

    static func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction, title: "Reply",
            options: [], textInputButtonTitle: "Send",
            textInputPlaceholder: "Answer the agent…")
        let category = UNNotificationCategory(
            identifier: replyCategory, actions: [reply],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// Routes the banner's typed reply back to the session's PTY. The center's
/// delegate must be an NSObject — this tiny adapter carries the closure.
final class NotificationReplyHandler: NSObject, UNUserNotificationCenterDelegate {
    var onReply: ((SessionID, String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let textResponse = response as? UNTextInputNotificationResponse,
              response.actionIdentifier == UserNotificationsNotifier.replyAction,
              let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let uuid = UUID(uuidString: raw) else { return }
        onReply?(SessionID(uuid), textResponse.userText)
    }
}

/// Composition root of the app: starts the store (marking `interrupted` on
/// open — UC-7), the manager, the hooks IPC server, and projects the
/// sessions for SwiftUI.
@MainActor
@Observable
public final class AppModel {

    public struct SessionItem: Identifiable, Equatable {
        public let id: SessionID
        public var title: String
        public var state: SessionState
        public var projectID: ProjectID?
        public var branch: String?
        /// SES-04: a secondary terminal (free shell) attached to an agent session.
        public var parentID: SessionID?
        public var isShell: Bool = false
        /// Closed but not destroyed ("inactive"): clicking resumes the session.
        public var isDormant: Bool = false
        /// Badges, in assignment order — each resolved to a color by the
        /// badge definitions.
        public var badges: [String] = []
        /// The native conversation the process serves when it is not the
        /// imposed one (`/resume <id>` typed in the terminal). Last stored
        /// property: every memberwise call site keeps compiling.
        public var nativeSessionID: SessionID? = nil

        /// The id the native `.jsonl` is named after and `claude --resume` accepts.
        public var nativeID: SessionID { nativeSessionID ?? id }
    }

    // MARK: - Badges: user-defined labels with a color

    public typealias BadgeDefinition = LoomPersistence.BadgeDefinition

    /// The catalog, as the store holds it (v8) — empty until `start()`.
    public private(set) var badgeDefinitions: [BadgeDefinition] = []

    public func saveBadgeDefinitions(_ definitions: [BadgeDefinition]) {
        try? store?.saveBadgeDefinitions(definitions)
        reloadBadgeDefinitions()
    }

    private func reloadBadgeDefinitions() {
        badgeDefinitions = ((try? store?.badgeDefinitions()) ?? nil) ?? BadgeDefinition.builtIn
    }

    /// Appends to the catalog — false when the name is taken (the API's
    /// `badge.create`, ADR-0010).
    func addBadgeDefinition(_ definition: BadgeDefinition) -> Bool {
        guard let store, (try? store.addBadgeDefinition(definition)) == true else { return false }
        reloadBadgeDefinitions()
        return true
    }

    /// Before v8 the catalog lived in UserDefaults. A saved one is moved into
    /// the store once, over the seeded built-ins, and the key goes — so a
    /// later deletion of every badge is never undone by a stale import.
    private static let legacyBadgesKey = "loom.badges"

    private func importLegacyBadgeDefinitions(into store: SessionStore) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.legacyBadgesKey) else { return }
        if let saved = try? JSONDecoder().decode([BadgeDefinition].self, from: data) {
            try? store.saveBadgeDefinitions(saved)
        }
        defaults.removeObject(forKey: Self.legacyBadgesKey)
    }

    /// Label → color: a defined badge uses its color; "PR …" labels get the
    /// fixed purple; anything else the muted default.
    public func badgeColor(for label: String) -> Color {
        if let definition = badgeDefinitions.first(where: { $0.name == label }) {
            return Self.color(hex: definition.colorHex)
        }
        if label.hasPrefix("PR ") || label.hasPrefix("PR#") {
            return Self.color(hex: "#A78BFA")
        }
        return Self.color(hex: "#86868E")
    }

    public static func color(hex: String) -> Color {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return .gray }
        return Color(red: Double((number >> 16) & 0xFF) / 255,
                     green: Double((number >> 8) & 0xFF) / 255,
                     blue: Double(number & 0xFF) / 255)
    }

    /// The badges a session wears right now — live item first, record otherwise.
    public func badges(of id: SessionID) -> [String] {
        sessions.first { $0.id == id }?.badges
            ?? allRecords.first { $0.id == id }?.badges
            ?? []
    }

    /// Replaces a session's badges (empty = none) — card, fleet, tabs and base follow.
    public func setBadges(_ badges: [String], for id: SessionID) {
        let normalized = SessionRecord.normalizedBadges(badges)
        try? store?.setBadges(session: id, badges: normalized)
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].badges = normalized
        }
        reloadPersistedSessions()
    }

    /// Adds the badge when the session lacks it, removes it otherwise — the
    /// right-click menu's one gesture.
    public func toggleBadge(_ name: String, for id: SessionID) {
        var current = badges(of: id)
        if let index = current.firstIndex(of: name) {
            current.remove(at: index)
        } else {
            current.append(name)
        }
        setBadges(current, for: id)
    }

    public private(set) var sessions: [SessionItem] = []
    /// PRJ-03: the sidebar groups by project.
    public private(set) var projects: [ProjectRecord] = []
    /// Remembered across launches: landing in the project you left is half of
    /// "everything as it was", and the sidebar is scoped to it.
    public var selectedProject: ProjectID? {
        didSet {
            guard selectedProject != oldValue else { return }
            UserDefaults.standard.set(selectedProject?.rawValue.uuidString,
                                      forKey: "loom.project.last")
        }
    }
    /// UC-7: offered for Resume on relaunch.
    public private(set) var interruptedSessions: [SessionRecord] = []
    /// SES-07: completed/failed/archived, browsable.
    public private(set) var historySessions: [SessionRecord] = []
    public internal(set) var startupError: String?

    public func clearError() {
        startupError = nil
    }

    private(set) var manager: SessionManager?
    private let replyHandler = NotificationReplyHandler()
    private var hookServer: HookSocketServer?
    private let supportDirectory: URL
    private var socketURL: URL { supportDirectory.appendingPathComponent("loom.sock") }

    /// The agents API's global token (ADR-0010), read from `api-token` in the
    /// support directory; nil when the file could not be created.
    public private(set) var apiToken: String?
    public var apiTokenURL: URL { supportDirectory.appendingPathComponent(Self.apiTokenFileName) }
    public var apiSocketURL: URL { socketURL }

    /// The grid actually displayed, remembered at each view measurement: the
    /// next sessions are BORN at the right size — claude paints its banner
    /// directly for the real grid, no more mangling reflow at startup.
    /// One memory per pane role: the review drawer is a different shape from
    /// the Sessions tab, and a session born at the other one's grid is
    /// resized while it boots — the one moment a resize can be missed.
    public private(set) var preferredGrid: TerminalGeometry =
        AppModel.storedGrid(role: .session) ?? .default
    private var preferredReviewGrid: TerminalGeometry? = AppModel.storedGrid(role: .review)

    private static func storedGrid(role: TerminalPaneRole) -> TerminalGeometry? {
        let cols = UserDefaults.standard.integer(forKey: role.colsKey)
        let rows = UserDefaults.standard.integer(forKey: role.rowsKey)
        return cols >= 40 && rows >= 10 ? TerminalGeometry(cols: cols, rows: rows) : nil
    }

    /// The launch grid for a pane role. A drawer never measured yet is
    /// estimated from its default width and the Sessions grid's height.
    public func preferredGrid(for role: TerminalPaneRole) -> TerminalGeometry {
        switch role {
        case .session:
            return preferredGrid
        case .review:
            if let preferredReviewGrid { return preferredReviewGrid }
            let cols = TerminalMetrics.grid(fitting: CGSize(width: TerminalPaneRole.defaultReviewDrawerWidth,
                                                            height: 0)).cols
            return TerminalGeometry(cols: cols, rows: max(10, preferredGrid.rows - 2))
        }
    }

    /// Review worktrees are read-only (guard hooks) unless the user opts out —
    /// absent key means true: safe by default.
    public var reviewWorktreesReadOnly: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.review.readOnly") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loom.review.readOnly") }
    }

    /// `/setup-pr-review` is typed into a fresh review session so claude loads
    /// the PR before anyone asks. Off: the command is still installed in the
    /// worktree, the user types it when they want it.
    public var reviewSetupCommandEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.review.setupCommand.enabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loom.review.setupCommand.enabled") }
    }

    /// The command's text as the user edited it; nil = Loom's default. Filled
    /// with the PR's placeholders at every review launch.
    public var reviewSetupCommandTemplate: String? {
        get { UserDefaults.standard.string(forKey: "loom.review.setupCommand.template") }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty || trimmed == PRReviewCommand.defaultTemplate {
                UserDefaults.standard.removeObject(forKey: "loom.review.setupCommand.template")
            } else {
                UserDefaults.standard.set(newValue, forKey: "loom.review.setupCommand.template")
            }
        }
    }

    // MARK: - Worktree preference (per project, default OFF)

    /// Whether new sessions of a project run in an isolated worktree (GIT-01)
    /// or straight in the project folder. Default: the folder — worktrees are
    /// an explicit choice.
    public func worktreeEnabled(for projectID: ProjectID?) -> Bool {
        guard let projectID else { return false }
        let map = UserDefaults.standard.dictionary(forKey: "loom.worktree.projects") as? [String: Bool]
        return map?[projectID.rawValue.uuidString] ?? false
    }

    public func setWorktreeEnabled(_ enabled: Bool, for projectID: ProjectID) {
        var map = (UserDefaults.standard.dictionary(forKey: "loom.worktree.projects")
                   as? [String: Bool]) ?? [:]
        map[projectID.rawValue.uuidString] = enabled
        UserDefaults.standard.set(map, forKey: "loom.worktree.projects")
    }

    /// P0 perf — the Settings refresh rate as a frame interval. 60 by default:
    /// with rows that survive a frame and gated deliveries, any supported Mac
    /// affords it, and at 30 the echo of a keystroke landed up to 33 ms late.
    public static func preferredFrameInterval() -> Duration {
        let fps = UserDefaults.standard.integer(forKey: "loom.terminal.fps")
        let clamped = [30, 60, 120].contains(fps) ? fps : 60
        return .milliseconds(1000 / clamped)
    }

    public func applyFrameRate() {
        let interval = Self.preferredFrameInterval()
        Task { await manager?.setFrameInterval(interval) }
    }

    public func noteTerminalGrid(cols: Int, rows: Int, role: TerminalPaneRole = .session) {
        // Only a grid plausible for a real window is remembered: a transient
        // measurement (layout in progress) must never poison the launch
        // geometry of the next sessions.
        guard cols >= 40, rows >= 10 else { return }
        let grid = TerminalGeometry(cols: cols, rows: rows)
        switch role {
        case .session: preferredGrid = grid
        case .review: preferredReviewGrid = grid
        }
        UserDefaults.standard.set(cols, forKey: role.colsKey)
        UserDefaults.standard.set(rows, forKey: role.rowsKey)
    }

    /// UIX-06: the claude binary located at launch (GUI apps don't see the
    /// shell's PATH — an absolute path is the only reliable way).
    public private(set) var claudePath: URL? = ClaudeLocator.locate()
    public var claudeSearchedLocations: [String] { ClaudeLocator.wellKnownLocations }

    /// The adapter talks to the CLI with the full hooks wiring (ADR-0005) and,
    /// when the `loom` binary is around, the API as MCP tools (ADR-0010).
    private var adapter: ClaudeCodeAdapter {
        ClaudeCodeAdapter(executable: claudePath?.path ?? "claude",
                          hooks: .init(helper: Self.helperBinaryURL(fallback: supportDirectory),
                                       socket: socketURL,
                                       cli: Self.companionBinaryURL(named: "loom",
                                                                    fallback: supportDirectory)))
    }

    /// In development, `loom-hook` is a sibling product of the app; packaged,
    /// it will live in the bundle and then be copied to Application Support.
    static func helperBinaryURL(fallback supportDirectory: URL) -> URL {
        companionBinaryURL(named: "loom-hook", fallback: supportDirectory)
            ?? supportDirectory.appendingPathComponent("loom-hook")
    }

    /// A companion executable, wherever it is: beside the app's own binary
    /// (development, and the bundle's MacOS folder), else in the support
    /// directory. nil when neither holds one — a caller that cannot do
    /// without it says so; one that can, goes without.
    static func companionBinaryURL(named name: String, fallback supportDirectory: URL) -> URL? {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            supportDirectory.appendingPathComponent(name),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public init(supportDirectory: URL? = nil) {
        // LOOM_SUPPORT_DIR: injection for end-to-end tests —
        // FileManager ignores $HOME for Application Support.
        let injected = ProcessInfo.processInfo.environment["LOOM_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0) }
        let resolved = supportDirectory ?? injected
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Loom")
        Self.migrateLegacySupportDirectory(to: resolved)
        self.supportDirectory = resolved
    }

    /// The app used to be called Bunshin: on first launch under the new name, the
    /// existing data (database, transcripts) is moved as-is — the session
    /// history survives the rename. The stale socket is purged.
    private static func migrateLegacySupportDirectory(to destination: URL) {
        let fm = FileManager.default
        let legacy = destination.deletingLastPathComponent().appendingPathComponent("Bunshin")
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: destination.path)
        else { return }
        try? fm.moveItem(at: legacy, to: destination)
        try? fm.removeItem(at: destination.appendingPathComponent("bunshin.sock"))
        let legacyDB = destination.appendingPathComponent("bunshin.sqlite")
        if fm.fileExists(atPath: legacyDB.path) {
            try? fm.moveItem(at: legacyDB, to: destination.appendingPathComponent("loom.sqlite"))
        }
    }

    /// Called at app launch. Any error is displayed, never fatal.
    public func start() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            ThemeStore.shared.configure(themesDirectory: supportDirectory.appendingPathComponent("themes"))
            loadPRListCache()
            reviewDrafts = reviewDraftStore.load()
            catalog = repoCatalogCache.load()
            prTabs = prTabsStore.load()
            let store = try SessionStore(path: supportDirectory.appendingPathComponent("loom.sqlite").path)
            self.store = store
            try store.markLiveSessionsInterrupted()
            importLegacyBadgeDefinitions(into: store)
            reloadBadgeDefinitions()

            // v2 (search): one sink per session, in its own directory — this is
            // what makes transcripts indexable per session. The dependency's
            // sink is only the fallback when a session's own cannot be made.
            let transcriptsRoot = supportDirectory.appendingPathComponent("transcripts")
            let manager = SessionManager(
                runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(),
                                                                 transcript: NullTranscriptSink()),
                store: store,
                notifier: UserNotificationsNotifier(),
                transcriptFactory: { id in
                    try FileTranscriptSink(directory: transcriptsRoot
                        .appendingPathComponent(id.rawValue.uuidString))
                })
            self.manager = manager
            applyFrameRate()
            if Bundle.main.bundleIdentifier != nil {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                UserNotificationsNotifier.registerCategories()
                UNUserNotificationCenter.current().delegate = replyHandler
                replyHandler.onReply = { [weak self] id, text in
                    Task { @MainActor [weak self] in
                        guard let surface = await self?.surface(for: id) else { return }
                        surface.send(text + "\r")
                    }
                }
            }

            let registry = tokenRegistry
            let globalToken = Self.loadOrCreateAPIToken(in: supportDirectory)
            apiToken = globalToken
            let server = HookSocketServer(
                socketPath: socketURL,
                validate: { token in registry.session(for: token) },
                handler: { [weak self] session, payload in
                    guard let self else { return }
                    Task { await self.manager?.ingest(payload, for: session) }
                },
                // ADR-0010: the same socket answers requests. A session token
                // reaches its session; the global token, every one of them.
                authorize: { token in
                    if let globalToken, token == globalToken { return .global }
                    return registry.session(for: token).map { APIScope.session($0) }
                },
                requests: { [weak self] scope, request in
                    guard let self else {
                        return APIResponse(id: request.id, error: APIError(
                            code: .internalError, message: "the app is shutting down"))
                    }
                    return await self.handleAPIRequest(scope, request)
                })
            try server.start()
            hookServer = server

            Task { await self.observeStates(of: manager) }
            Task { await self.observeIdentities(of: manager) }
            reloadPersistedSessions()
            restoreStackChildren()
            reindexAllSessions()
        } catch {
            if case IPCError.anotherInstanceRunning = error {
                startupError = "Another Loom instance is already running (or did not fully quit). Close it and relaunch — sessions work, but state hooks are disabled in this instance."
            } else {
                startupError = String(describing: error)
            }
        }
    }

    /// All known records — counters and dates for the project cards.
    public private(set) var allRecords: [SessionRecord] = []

    /// P1 perf: exists() scans ~/.claude/projects directories — memoized per
    /// session; a closed session's native file is settled, so entries only
    /// need invalidation right when a session closes.
    private var nativeExistsCache: [SessionID: Bool] = [:]

    /// Keyed by the RECORD (its Loom id); the file looked up is the native
    /// conversation's — the same UUID unless the agent switched since.
    private func nativeSessionExists(_ record: SessionRecord) -> Bool {
        if let cached = nativeExistsCache[record.id] { return cached }
        let exists = ClaudeNativeSessions.exists(record.resolvedNativeSessionID)
        nativeExistsCache[record.id] = exists
        return exists
    }

    /// Fills the memo for every record it does not cover yet from ONE walk of
    /// `~/.claude/projects`. A cold launch used to walk it once per persisted
    /// session, on the main thread, before the first frame — and both the
    /// session table and the project slugs only ever grow.
    private func seedNativeExistsCache(for records: [SessionRecord]) {
        let uncached = records.filter { nativeExistsCache[$0.id] == nil }
        guard !uncached.isEmpty else { return }
        // One record (a close, an identity change): the per-session lookup
        // stops at the first slug that holds it. The walk pays off past that.
        if uncached.count == 1, let record = uncached.first {
            nativeExistsCache[record.id] = ClaudeNativeSessions.exists(record.resolvedNativeSessionID)
            return
        }
        let index = ClaudeNativeSessions.index()
        for record in uncached {
            nativeExistsCache[record.id] = ClaudeNativeSessions.contains(index, record.resolvedNativeSessionID)
        }
    }

    /// The conversation a session serves — live item first, then its record,
    /// else the Loom id itself. The one read path for the ring, the info
    /// panel, the context sheet and Mission Control.
    public func nativeSessionID(for id: SessionID) -> SessionID {
        sessions.first { $0.id == id }?.nativeID
            ?? allRecords.first { $0.id == id }?.resolvedNativeSessionID
            ?? id
    }

    private func reloadPersistedSessions() {
        let all = ((try? store?.allSessions()) ?? nil) ?? []
        allRecords = all
        seedNativeExistsCache(for: all.filter {
            [.interrupted, .completed, .failed, .archived].contains($0.state)
        })
        // A closed session with no persisted conversation has nothing to show or
        // to resume: it doesn't clutter the lists (pre-fix identifier wrecks
        // disappear at the same time).
        interruptedSessions = all.filter {
            $0.state == .interrupted && nativeSessionExists($0)
        }
        historySessions = all.filter {
            [.completed, .failed, .archived].contains($0.state) && nativeSessionExists($0)
        }
        let loadedProjects = (try? store?.activeProjects()) ?? nil
        projects = loadedProjects ?? []
        applySavedProjectOrder()
        if selectedProject == nil { selectedProject = lastOpenedProject ?? projects.first?.id }
        resolveProjectRepoNames()
        // A tab of a project removed since has nowhere to show. Only when
        // the query answered: a failed read is not an empty project list,
        // and must not wipe the tabs from disk.
        if let loadedProjects {
            let kept = prTabs
            prTabs.keep(projects: Set(loadedProjects.map(\.id)))
            if prTabs != kept { savePRTabs() }
        }
    }

    // MARK: - v4: GitHub PR review through the user's authenticated gh

    func projectRepo(_ id: ProjectID?) -> URL? {
        project(id).map { URL(fileURLWithPath: $0.path) }
    }

    public func prDetail(_ number: Int, in projectID: ProjectID,
                         refresh: Bool = false) async -> GitHubService.PRDetail? {
        guard let repo = projectRepo(projectID) else { return nil }
        let key = prKey(number, projectID)
        if !refresh, let cached = prDetailCache[key] { return cached }
        let detail = try? await GitHubService().prDetail(number, in: repo)
        if let detail { prDetailCache[key] = detail }
        return detail
    }

    /// The PR's diff, or the error explaining why there is none — a silently
    /// empty diff hid the entire file explorer.
    public func prDiff(_ number: Int, baseBranch: String = "", in projectID: ProjectID,
                       refresh: Bool = false) async -> (diff: String, error: String?) {
        guard let repo = projectRepo(projectID) else { return ("", "No repo for this project") }
        let key = prKey(number, projectID)
        if !refresh, let cached = prDiffCache[key] { return (cached, nil) }
        do {
            let diff = try await GitHubService().prDiff(number, in: repo)
            if !diff.isEmpty { prDiffCache[key] = diff }
            return (diff, nil)
        } catch {
            // The API refuses oversized diffs (HTTP 406) — git has no limit:
            // rebuild the diff locally from the fetched PR refs.
            do {
                let base = baseBranch.isEmpty ? "main" : baseBranch
                let diff = try await GitHubService().localDiff(number, baseBranch: base, in: repo)
                if !diff.isEmpty { prDiffCache[key] = diff }
                return (diff, nil)
            } catch let fallbackError {
                return ("", Self.ghErrorText(error) + " — local fallback: "
                        + Self.ghErrorText(fallbackError))
            }
        }
    }

    /// nil on success, error text otherwise — the panel reports the truth.
    /// With a draft pending on the PR, the verdict, the summary and every
    /// drafted comment leave as ONE review; the draft is gone once GitHub
    /// has it.
    public func submitPRReview(_ number: Int, verdict: GitHubService.Verdict,
                               body: String, in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        let key = prKey(number, projectID)
        do {
            if let draft = reviewDrafts[key], !draft.isEmpty {
                try await GitHubService().submitReview(number, verdict: verdict, body: body,
                                                       comments: draft.comments, in: repo)
                reviewDrafts[key] = nil
                saveReviewDrafts()
            } else {
                try await GitHubService().submitReview(number, verdict: verdict, body: body, in: repo)
            }
            return nil
        } catch { return Self.ghErrorText(error) }
    }

    /// Review comments anchored to code, cached like the diff.
    public func reviewComments(_ number: Int, in projectID: ProjectID,
                               refresh: Bool = false) async -> [GitHubService.ReviewComment] {
        guard let repo = projectRepo(projectID) else { return [] }
        let key = prKey(number, projectID)
        if !refresh, let cached = prCommentsCache[key] { return cached }
        let comments = (try? await GitHubService().reviewComments(number, in: repo)) ?? []
        prCommentsCache[key] = comments
        return comments
    }

    /// Replies inside an existing thread. nil on success, error text otherwise.
    public func replyToReviewComment(_ number: Int, commentID: Int, body: String,
                                     in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do {
            try await GitHubService().replyToComment(number, commentID: commentID,
                                                     body: body, in: repo)
            return nil
        } catch { return Self.ghErrorText(error) }
    }

    /// Whole-file review comment (selection spanning several hunks).
    /// nil on success, error text otherwise.
    public func commentOnFile(_ number: Int, path: String, note: String,
                              in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do {
            try await GitHubService().commentOnFile(number, path: path, note: note, in: repo)
            return nil
        } catch { return Self.ghErrorText(error) }
    }

    /// GitHub's "Viewed" state of every file of the PR — the truth lives on
    /// GitHub (shared with the web, reset by GitHub when a file changes);
    /// this cache only spares a gh call when the PR is revisited.
    public func fileViews(_ number: Int, in projectID: ProjectID,
                          refresh: Bool = false) async -> GitHubService.FileViews? {
        guard let repo = projectRepo(projectID) else { return nil }
        let key = prKey(number, projectID)
        if !refresh, let cached = prFileViewsCache[key] { return cached }
        let views = try? await GitHubService().fileViews(number, in: repo)
        if let views { prFileViewsCache[key] = views }
        return views
    }

    /// Checks or unchecks GitHub's "Viewed" box on a file. nil on success,
    /// error text otherwise — the caller flipped optimistically and reverts.
    public func setFileViewed(_ number: Int, path: String, viewed: Bool,
                              in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        guard let views = await fileViews(number, in: projectID) else {
            return "Could not read the PR's files from GitHub."
        }
        do {
            try await GitHubService().setFileViewed(prNodeID: views.prNodeID, path: path,
                                                    viewed: viewed, in: repo)
            prFileViewsCache[prKey(number, projectID)] = views.setting(path, to: viewed ? .viewed : .unviewed)
            return nil
        } catch { return Self.ghErrorText(error) }
    }

    /// Line-anchored review comment (optionally an appliable suggestion).
    /// nil on success, error text otherwise.
    public func commentOnLines(_ number: Int, path: String, firstLine: Int, lastLine: Int,
                               note: String, suggestion: String?, side: String = "RIGHT",
                               in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do {
            try await GitHubService().commentOnLines(number, path: path, firstLine: firstLine,
                                                     lastLine: lastLine, note: note,
                                                     suggestion: suggestion, side: side, in: repo)
            return nil
        } catch { return Self.ghErrorText(error) }
    }

    public func commentPR(_ number: Int, body: String, in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do { try await GitHubService().comment(number, body: body, in: repo); return nil }
        catch { return Self.ghErrorText(error) }
    }

    static func ghErrorText(_ error: Error) -> String {
        if case GitHubService.GitHubError.commandFailed(_, let stderr) = error, !stderr.isEmpty {
            return stderr
        }
        return String(describing: error)
    }

    // MARK: - Global PRs tab: cache + PR ↔ review session mapping

    /// Cross-tab navigation: "open this PR in the PRs tab" — consumed by the
    /// global view on appearance/change.
    public struct PendingPR: Equatable {
        public let projectID: ProjectID
        public let pr: GitHubService.PullRequest
    }
    public var pendingPR: PendingPR?

    /// A list is one project seen through one filter.
    public struct PRListKey: Hashable, Sendable {
        public let projectID: ProjectID
        public let filterID: String
        public init(projectID: ProjectID, filterID: String) {
            self.projectID = projectID
            self.filterID = filterID
        }
    }

    /// Every list ever fetched, by project and filter — the cache on disk mirrors it.
    private var prLists: [PRListKey: PRListCache.Entry] = [:]
    public private(set) var prLoading: Set<PRListKey> = []
    /// PRs whose review session is being prepared (worktree fetch + launch) —
    /// the UI shows progress instead of feeling frozen during the network fetch.
    public private(set) var prReviewLaunching: Set<String> = []
    /// PR content caches: selecting an already-seen PR paints instantly instead
    /// of re-running two gh processes. Invalidated by refreshPRs / submissions.
    private var prDetailCache: [String: GitHubService.PRDetail] = [:]
    private var prDiffCache: [String: String] = [:]

    /// What the diff view paints, per PR: the products of `DiffPipeline`,
    /// mirrored here so a workspace seeds its state SYNCHRONOUSLY in its init
    /// and paints a coloured diff in its first frame on a revisit.
    struct CachedDiff: Sendable {
        var files: [DiffFileRows]
        var highlights: DiffHighlights?
    }
    @ObservationIgnored private let diffPipeline = DiffPipeline()
    @ObservationIgnored private var diffProducts: [String: CachedDiff] = [:]
    @ObservationIgnored private var prTourCache: [String: PRTour] = [:]

    func cachedDiff(pr number: Int, in projectID: ProjectID) -> CachedDiff? {
        diffProducts[prKey(number, projectID)]
    }

    func cachedTour(pr number: Int, in projectID: ProjectID) -> PRTour? {
        prTourCache[prKey(number, projectID)]
    }

    /// Parsed and paired rows for a diff — cached across tab switches.
    func diffRows(pr number: Int, in projectID: ProjectID, diff: String) async -> DiffPipeline.Rows {
        let key = prKey(number, projectID)
        let rows = await diffPipeline.rows(for: key, diff: diff)
        if diffProducts[key]?.files != rows.files {
            diffProducts[key] = CachedDiff(files: rows.files, highlights: nil)
        }
        return rows
    }

    /// Colours for those rows in the given scheme — cached across tab switches.
    func diffHighlights(pr number: Int, in projectID: ProjectID,
                        rows: DiffPipeline.Rows, dark: Bool) async -> DiffHighlights {
        let key = prKey(number, projectID)
        let highlights = await diffPipeline.highlights(for: key, rows: rows, dark: dark)
        diffProducts[key] = CachedDiff(files: rows.files, highlights: highlights)
        return highlights
    }
    private var prCommentsCache: [String: [GitHubService.ReviewComment]] = [:]
    private var prFileViewsCache: [String: GitHubService.FileViews] = [:]
    private var prListCache: PRListCache { PRListCache(directory: supportDirectory) }
    private var prFilterStore: PRFilterStore { PRFilterStore(directory: supportDirectory) }

    // MARK: PRs tab beyond the projects: catalog, inbox, search, drafts

    /// The GitHub repository (`owner/name`) each project clones, from its
    /// `origin` remote. `""` once looked up and not a GitHub clone — the
    /// lookup is a git process, not to be repeated at every reload.
    public internal(set) var projectRepoNames: [ProjectID: String] = [:]
    /// Projects whose remote is being read right now — one git process each.
    var repoNameLookups: Set<ProjectID> = []
    /// Where clones land (`<folder>/<name>`). Asked once, kept in Settings.
    /// Stored (not computed over UserDefaults) so the views tracking it
    /// repaint when it is chosen.
    public var cloneDirectory: URL? = UserDefaults.standard
        .string(forKey: "loom.clone.directory").map(URL.init(fileURLWithPath:)) {
        didSet {
            if let cloneDirectory {
                UserDefaults.standard.set(cloneDirectory.path, forKey: "loom.clone.directory")
            } else {
                UserDefaults.standard.removeObject(forKey: "loom.clone.directory")
            }
        }
    }
    /// The GitHub search's generation: only the latest one may paint.
    var searchGeneration = 0
    /// The open PR tabs — the PRs tab's selection, drawer and summaries
    /// live here, not in the view: the view is rebuilt every time the app's
    /// tabs switch, and a relaunch reopens what was open.
    public internal(set) var prTabs = PRTabs()
    var prTabsStore: PRTabsStore { PRTabsStore(directory: supportDirectory) }
    /// The pending, debounced write of the tabs (see `savePRTabs`).
    @ObservationIgnored var prTabsSaveTask: Task<Void, Never>?
    /// One serial queue: the writes land in the order they were asked.
    static let prTabsWriteQueue = DispatchQueue(label: "loom.pr.tabs.write", qos: .utility)
    /// The PR list folded away (a review took the room) — kept while the
    /// app runs, whichever tab is on screen.
    public var prSidebarHidden = false
    /// Projects unfolded in the PRs sidebar — gh is queried for those only.
    public var expandedPRProjects: Set<ProjectID> = []
    /// The organizations' repositories, from disk at launch, then refreshed
    /// a day later or on demand.
    public internal(set) var catalog: RepoCatalogCache.Entry?
    public internal(set) var catalogLoading = false
    public internal(set) var catalogError: String?
    /// Organizations and repositories the user folded away, by login.
    public internal(set) var hiddenOwners: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "loom.pr.hiddenOwners") ?? [])
    public internal(set) var hiddenRepos: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "loom.pr.hiddenRepos") ?? [])
    /// Every open PR waiting on the user's review, whatever the repository.
    public internal(set) var inbox: [GitHubService.PRSearchHit] = []
    public internal(set) var inboxLoading = false
    public internal(set) var inboxError: String?
    var inboxFetchedAt: Date?
    /// The GitHub search's answer — nil when no search is showing.
    public internal(set) var searchResults: [GitHubService.PRSearchHit]?
    public internal(set) var searchLoading = false
    public internal(set) var searchError: String?
    /// Repositories being cloned right now (`owner/name`).
    public internal(set) var cloning: Set<String> = []
    /// A repository to clone before a PR can open: the view asks first.
    public var pendingClone: PendingClone?
    /// Drafted review comments by PR key — mirrored on disk.
    var reviewDrafts: [String: ReviewDraft] = [:]
    var reviewDraftStore: ReviewDraftStore { ReviewDraftStore(directory: supportDirectory) }
    var repoCatalogCache: RepoCatalogCache { RepoCatalogCache(directory: supportDirectory) }

    public struct PendingClone: Equatable {
        public let repo: String
        /// The PR to open once the clone is a project — nil for a bare add.
        public let number: Int?
    }

    // MARK: PR filters

    /// The user's own filters, after the built-ins in every menu.
    public private(set) var customPRFilters: [PRFilter] = []

    public var prFilters: [PRFilter] { PRFilter.builtIns + customPRFilters }

    /// The filter every PR list is currently seen through. Persisted: the tab
    /// reopens on the question you were asking.
    public var selectedPRFilterID: String = UserDefaults.standard
        .string(forKey: "loom.pr.filter") ?? PRFilter.all.id {
        didSet { UserDefaults.standard.set(selectedPRFilterID, forKey: "loom.pr.filter") }
    }

    /// A deleted custom filter falls back to "All open" rather than to nothing.
    public var selectedPRFilter: PRFilter {
        prFilters.first { $0.id == selectedPRFilterID } ?? .all
    }

    public func addCustomPRFilter(name: String, query: String) -> PRFilter {
        let filter = PRFilter.custom(name: name, query: query)
        customPRFilters.append(filter)
        prFilterStore.save(customPRFilters)
        return filter
    }

    public func updateCustomPRFilter(_ filter: PRFilter) {
        guard let index = customPRFilters.firstIndex(where: { $0.id == filter.id }) else { return }
        customPRFilters[index] = filter
        prFilterStore.save(customPRFilters)
    }

    public func removeCustomPRFilter(id: String) {
        customPRFilters.removeAll { $0.id == id }
        prFilterStore.save(customPRFilters)
        prLists = prLists.filter { $0.key.filterID != id }
        if selectedPRFilterID == id { selectedPRFilterID = PRFilter.all.id }
    }

    /// Runs a query once against a project, without touching the caches —
    /// the editor's "Test" button. The gh error text comes back verbatim:
    /// a bad qualifier is the one thing the user must read.
    public func testPRFilter(query: String, in projectID: ProjectID) async -> Result<Int, Error> {
        guard let repo = projectRepo(projectID) else {
            return .failure(GitHubService.GitHubError.commandFailed(
                arguments: [], stderr: "The project folder is missing."))
        }
        let probe = PRFilter(id: "probe", name: "probe", query: query, isBuiltIn: false)
        do {
            return .success(try await GitHubService().listPRs(in: repo, filter: probe).count)
        } catch {
            return .failure(error)
        }
    }

    // MARK: PR lists

    private func prKey(_ projectID: ProjectID) -> PRListKey {
        PRListKey(projectID: projectID, filterID: selectedPRFilterID)
    }

    /// The project's PRs through the current filter — empty until fetched.
    public func prs(for projectID: ProjectID) -> [GitHubService.PullRequest] {
        prLists[prKey(projectID)]?.prs ?? []
    }

    public func isLoadingPRs(for projectID: ProjectID) -> Bool {
        prLoading.contains(prKey(projectID))
    }

    /// Seeds every list from disk: after a relaunch the tab paints its lists,
    /// and their counts, without a single `gh` call.
    private func loadPRListCache() {
        customPRFilters = prFilterStore.load()
        for (projectID, lists) in prListCache.load() {
            for (filterID, entry) in lists {
                prLists[PRListKey(projectID: projectID, filterID: filterID)] = entry
            }
        }
    }

    /// Projects that no longer exist are dropped here rather than at load
    /// time, where `projects` has not been read from the database yet.
    /// Coalesced like the tabs: a filter change refreshes every expanded
    /// project, and each answer used to serialise and write the whole cache.
    private func savePRListCache() {
        prListSaveTask?.cancel()
        prListSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let known = Set(self.projects.map(\.id))
            var lists: PRListCache.Lists = [:]
            for (key, entry) in self.prLists where known.contains(key.projectID) {
                lists[key.projectID, default: [:]][key.filterID] = entry
            }
            let cache = self.prListCache
            Task.detached(priority: .utility) { cache.save(lists) }
        }
    }

    @ObservationIgnored private var prListSaveTask: Task<Void, Never>?

    /// Several projects at once: the lists arrive together instead of one
    /// gh process after another (audit 2026-09-22, secondary findings).
    public func ensurePRs(for projectIDs: [ProjectID]) async {
        await withTaskGroup(of: Void.self) { group in
            for projectID in projectIDs {
                group.addTask { await self.ensurePRs(for: projectID) }
            }
        }
    }

    /// How old a project's cached list is — nil when nothing is cached.
    public func prCacheAge(for projectID: ProjectID) -> TimeInterval? {
        prLists[prKey(projectID)].map { Date().timeIntervalSince($0.fetchedAt) }
    }

    /// What the refresh button says: where the list on screen comes from.
    public func prCacheHelp(for projectID: ProjectID) -> String {
        guard let age = prCacheAge(for: projectID) else { return "Fetch the pull requests" }
        let minutes = Int(age / 60)
        let when = minutes < 1 ? "just now"
                 : minutes < 60 ? "\(minutes) min ago"
                 : "\(minutes / 60) h ago"
        return "Loaded \(when) — refresh"
    }

    /// Fetches only what the cache cannot answer: nothing stored, stored
    /// longer ago than the TTL, or stored for a filter edited since. What
    /// visiting a project, or picking a filter, calls.
    public func ensurePRs(for projectID: ProjectID) async {
        if let entry = prLists[prKey(projectID)], !entry.isStale(for: selectedPRFilter) { return }
        await refreshPRs(for: projectID)
    }

    /// Fetches whatever the cache's age — the refresh button.
    public func refreshPRs(for projectID: ProjectID) async {
        let filter = selectedPRFilter
        let key = PRListKey(projectID: projectID, filterID: filter.id)
        guard !prLoading.contains(key) else { return }
        prLoading.insert(key)
        defer { prLoading.remove(key) }
        guard let repo = projectRepo(projectID) else { return }
        // A failed gh call must never be stamped fresh: the failure would then
        // be served from the cache for the whole TTL.
        guard let prs = try? await GitHubService().listPRs(in: repo, filter: filter) else { return }
        let prefix = "\(projectID.rawValue.uuidString)#"
        prDetailCache = prDetailCache.filter { !$0.key.hasPrefix(prefix) }
        prDiffCache = prDiffCache.filter { !$0.key.hasPrefix(prefix) }
        diffProducts = diffProducts.filter { !$0.key.hasPrefix(prefix) }
        Task { await diffPipeline.evict(prefix: prefix) }
        prCommentsCache = prCommentsCache.filter { !$0.key.hasPrefix(prefix) }
        prFileViewsCache = prFileViewsCache.filter { !$0.key.hasPrefix(prefix) }
        prLists[key] = PRListCache.Entry(fetchedAt: Date(), prs: prs, query: filter.query)
        savePRListCache()
        // The open tabs of this project take the fresh rows: title, head,
        // checks, review state.
        prTabs.refresh(from: prs, in: projectID)
        savePRTabs()
    }

    public func isLaunchingReview(forPR number: Int, in projectID: ProjectID) -> Bool {
        prReviewLaunching.contains(prKey(number, projectID))
    }

    func prKey(_ number: Int, _ projectID: ProjectID) -> String {
        "\(projectID.rawValue.uuidString)#\(number)"
    }

    /// In-memory mirror of loom.pr.sessions: reviewSession(forPR:) runs per
    /// sidebar row per frame — deserializing UserDefaults there is waste.
    private var prSessionMap: [String: String]?

    /// The review session attached to a PR, when it still exists somewhere
    /// (live or resumable). Mapping persisted across launches.
    public func reviewSession(forPR number: Int, in projectID: ProjectID) -> SessionID? {
        if prSessionMap == nil {
            prSessionMap = (UserDefaults.standard.dictionary(forKey: "loom.pr.sessions")
                            as? [String: String]) ?? [:]
        }
        guard let raw = prSessionMap?[prKey(number, projectID)], let uuid = UUID(uuidString: raw)
        else { return nil }
        let id = SessionID(uuid)
        let known = sessions.contains { $0.id == id } || allRecords.contains { $0.id == id }
        return known ? id : nil
    }

    private func rememberReviewSession(_ id: SessionID, forPR number: Int, in projectID: ProjectID) {
        var map = (UserDefaults.standard.dictionary(forKey: "loom.pr.sessions")
                   as? [String: String]) ?? [:]
        map[prKey(number, projectID)] = id.rawValue.uuidString
        UserDefaults.standard.set(map, forKey: "loom.pr.sessions")
        prSessionMap = map
    }

    /// The PR tab's quick action: ONE review session per PR — reattached when
    /// it exists (resumed if dormant), created otherwise: PR checked out in a
    /// dedicated worktree, claude launched bare, badge "PR #n".
    public func launchPRReviewSession(_ pr: GitHubService.PullRequest,
                                      in projectID: ProjectID) async -> SessionID? {
        if let existing = reviewSession(forPR: pr.number, in: projectID) {
            if !sessions.contains(where: { $0.id == existing }) {
                await resumeDormant(existing)
            }
            // A review whose command never went in (a boot too slow for the
            // old gate, the app quit meanwhile) gets it now — once.
            scheduleReviewSetupIfNeeded(for: existing, number: pr.number)
            return existing
        }
        guard let manager, let repo = projectRepo(projectID) else { return nil }
        let key = prKey(pr.number, projectID)
        prReviewLaunching.insert(key)
        defer { prReviewLaunching.remove(key) }
        let worktree: URL
        do {
            worktree = try await GitHubService().checkoutPR(pr.number, repo: repo,
                                                            readOnly: reviewWorktreesReadOnly)
        } catch {
            startupError = "Could not check out PR #\(pr.number): \(Self.ghErrorText(error))"
            return nil
        }
        // The /setup-pr-review command, rewritten at every launch so the text
        // in Settings is what claude reads. Installed even when it will not be
        // typed automatically: the user can call it.
        let commandMarkdown = PRReviewCommand.render(
            template: reviewSetupCommandTemplate,
            pr: .init(number: pr.number, title: pr.title, url: pr.url,
                      base: pr.baseBranch.isEmpty ? "main" : pr.baseBranch, head: pr.branch))
        do {
            try await GitHubService().installCommand(named: PRReviewCommand.name,
                                                     markdown: commandMarkdown, in: worktree)
        } catch {
            // A missing command is not a missing review: the session launches
            // without it, and says why.
            startupError = "Could not install /\(PRReviewCommand.name): \(Self.ghErrorText(error))"
        }
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            // claude boots BARE — no predefined prompt: the user decides what
            // the session does (and claude is not burning an agent run on a
            // review nobody asked for yet). The setup command is typed after
            // the boot, from the outside, and only when the setting says so.
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: nil,
                                               hookToken: token),
                workingDirectory: worktree,
                // Born at the drawer's grid: the first fit is then a no-op,
                // and nothing resizes claude while it boots.
                geometry: preferredGrid(for: .review),
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = projectID
            spec.sessionID = sessionID
            spec.title = "PR #\(pr.number) · review"
            spec.badges = ["PR #\(pr.number)"]
            // The record must know it runs in a worktree: the git panel and
            // the ship actions read worktreePath, and a nil left them blind.
            spec.worktree = .existing(path: worktree, branch: pr.branch)
            let id = try await manager.launch(spec)
            await cacheSurface(for: id)
            tokenRegistry.register(token: token, session: id)
            sessions.append(SessionItem(id: id, title: "PR #\(pr.number) · review",
                                        state: .starting, projectID: projectID,
                                        branch: pr.branch, badges: ["PR #\(pr.number)"]))
            rememberReviewSession(id, forPR: pr.number, in: projectID)
            reloadPersistedSessions()
            scheduleReviewSetupIfNeeded(for: id, number: pr.number)
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    /// The setup command still on its way to a review session.
    @ObservationIgnored private var pendingReviewSetup: [SessionID: Task<Void, Never>] = [:]

    /// Types `/setup-pr-review` into a review session that never had it, when
    /// the setting says so. Detached from the caller: the PR tab must not wait
    /// seconds for claude to boot. Remembered, so a quick action fired
    /// meanwhile queues BEHIND it. A session that already received it — this
    /// launch or a previous one, the brief lives in its native context — is
    /// left alone.
    private func scheduleReviewSetupIfNeeded(for id: SessionID, number: Int) {
        guard reviewSetupCommandEnabled, pendingReviewSetup[id] == nil,
              !reviewSetupSubmitted.contains(id.rawValue.uuidString),
              sessions.contains(where: { $0.id == id }) else { return }
        let invocation = PRReviewCommand.invocation(number: number)
        pendingReviewSetup[id] = Task { [weak self] in
            guard let self else { return }
            if await self.submitWhenReady(invocation, to: id) {
                self.rememberReviewSetupSubmitted(id)
            }
            self.pendingReviewSetup[id] = nil
        }
    }

    /// Review sessions that actually received their setup command, across
    /// launches: `loom.review.setupSubmitted`, session UUIDs.
    @ObservationIgnored private lazy var reviewSetupSubmitted: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: Self.reviewSetupSubmittedKey) ?? [])
    private static let reviewSetupSubmittedKey = "loom.review.setupSubmitted"

    private func rememberReviewSetupSubmitted(_ id: SessionID) {
        reviewSetupSubmitted.insert(id.rawValue.uuidString)
        UserDefaults.standard.set(Array(reviewSetupSubmitted).sorted(),
                                  forKey: Self.reviewSetupSubmittedKey)
    }

    /// Waits for the setup command to have been submitted, when one is pending:
    /// what a quick action must do before it speaks, or the two collide.
    private func awaitReviewSetup(for id: SessionID) async {
        guard let pending = pendingReviewSetup[id] else { return }
        await pending.value
        pendingReviewSetup[id] = nil
    }

    private static let log = Logger(subsystem: "app.loom", category: "review")

    /// Submits a line to a session once the agent is READY for it — painted,
    /// bracketed paste negotiated, prompt on screen, output settled
    /// (`AgentReadiness`), read off the runtime so no pane needs to be
    /// watching. A plugin-heavy claude boots for a long while: the wait is
    /// generous, and a miss is logged rather than typed into the void.
    /// Pasted, not typed: a paste never opens the slash-command menu, so the
    /// Return that follows submits instead of picking a suggestion.
    /// Returns whether the line went in.
    private func submitWhenReady(_ line: String, to id: SessionID,
                                 timeout: Duration = .seconds(120)) async -> Bool {
        guard let runtime = await manager?.runtime(for: id) else { return false }
        let surface = runtime.surface()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            let sample = await runtime.readiness()
            if AgentReadiness.isReady(sample) {
                surface.send(KeyTranslator.paste(line, bracketed: true) + "\r")
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Self.log.warning("session \(id.rawValue.uuidString, privacy: .public) never became ready: line not submitted")
        return false
    }

    /// Types text into a session's input WITHOUT submitting — the same path as
    /// ⌘V: bracketed when the program asked for it, so claude treats the
    /// newlines as one pasted block instead of submitting on each one.
    public func typeIntoSession(_ text: String, id: SessionID) async {
        guard let surface = await surface(for: id) else { return }
        surface.send(KeyTranslator.paste(text, bracketed: surface.modes.bracketedPaste))
    }

    /// Phase 4 — diff quick actions: guarantees the PR's review session and
    /// delivers the message once the agent has painted (fresh sessions boot
    /// for seconds; sending into the void helps nobody).
    public func sendToPRReviewSession(_ message: String,
                                      pr: GitHubService.PullRequest,
                                      in projectID: ProjectID) async -> SessionID? {
        guard let id = await launchPRReviewSession(pr, in: projectID) else { return nil }
        // A fresh session first loads the PR: the question waits its turn, or
        // claude answers it while the setup command lands mid-sentence.
        await awaitReviewSetup(for: id)
        let submitted = await submitWhenReady(message, to: id)
        if !submitted {
            // The user asked for this one: past the wait, it goes in anyway.
            guard let surface = await surface(for: id) else { return id }
            surface.send(KeyTranslator.paste(message, bracketed: surface.modes.bracketedPaste) + "\r")
        }
        return id
    }

    /// The guided tour: claude -p over the PR diff, strict-JSON answer parsed
    /// into chapters + a playful risk gauge. Slow (an agent run) — call it from
    /// a task, show progress.
    public func generateTour(_ number: Int, in projectID: ProjectID) async -> PRTour? {
        let tour = await generateTourUncached(number, in: projectID)
        if let tour { prTourCache[prKey(number, projectID)] = tour }
        return tour
    }

    private func generateTourUncached(_ number: Int, in projectID: ProjectID) async -> PRTour? {
        guard let repo = projectRepo(projectID), let claude = claudePath else { return nil }
        let diff = String((try? await GitHubService().prDiff(number, in: repo))?.prefix(40_000) ?? "")
        guard !diff.isEmpty else { return nil }
        let prompt = """
        You are a playful but rigorous code-tour guide. Given this pull-request diff, \
        respond with ONLY a JSON object, no prose: {"pitch": string (the PR in two vivid \
        sentences), "chapters": [{"title", "explanation", "file"}] (3 to 6, ordered as a \
        story: intent, key changes, risky spots; 2-3 beginner-friendly sentences each), \
        "riskLevel": "quiet"|"watch"|"dragon", "warnings": [{"file", "line": int, "note"}]}.

        DIFF:
        \(diff)
        """
        let process = Process()
        process.executableURL = claude
        process.arguments = ["-p", prompt, "--output-format", "json"]
        process.currentDirectoryURL = repo
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output: String? = await withCheckedContinuation { continuation in
            // ProcessDrain: drains pipes before exit and never touches
            // waitUntilExit (both deadlock in their own way).
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { _, out, _ in
                    continuation.resume(returning: String(decoding: out, as: UTF8.self))
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let output else { return nil }
        return PRTourParser.parse(claudeOutput: output)
    }

    /// "Ask the guide": the PR checked out into a dedicated worktree, and an
    /// interactive session primed as its tour guide.
    public func askGuide(about number: Int, title: String, tour: PRTour?,
                         in projectID: ProjectID) async -> SessionID? {
        guard let manager, let repo = projectRepo(projectID) else { return nil }
        guard let worktree = try? await GitHubService().checkoutPR(
            number, repo: repo, readOnly: reviewWorktreesReadOnly) else { return nil }
        let pitch = tour?.pitch ?? ""
        let prompt = """
        You are the tour guide for PR #\(number) ("\(title)"), checked out in this worktree. \
        \(pitch.isEmpty ? "" : "Your own summary of it: \(pitch) ")\
        The user will ask questions about what it does and why. Inspect the real code and \
        the diff (git diff main...HEAD or gh pr view) to answer precisely. Greet them with \
        a one-paragraph orientation.
        """
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: prompt,
                                               hookToken: token),
                workingDirectory: worktree,
                geometry: preferredGrid,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = projectID
            spec.sessionID = sessionID
            spec.title = "PR #\(number) · guide"
            spec.badges = ["PR #\(number)"]
            spec.worktree = .existing(path: worktree, branch: nil)
            let id = try await manager.launch(spec)
            await cacheSurface(for: id)
            tokenRegistry.register(token: token, session: id)
            sessions.append(SessionItem(id: id, title: "PR #\(number) · guide",
                                        state: .starting, projectID: projectID,
                                        branch: nil, badges: ["PR #\(number)"]))
            reloadPersistedSessions()
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    /// v3 — on-demand review: a fresh claude session IN THE SAME worktree,
    /// primed to review the pending diff. Sibling in the stack (same parent
    /// project), so the reviewer and the author sit side by side.
    public func launchReviewSession(reviewing id: SessionID) async -> SessionID? {
        guard let manager, let record = (try? store?.session(id: id)) ?? nil,
              let worktreePath = record.worktreePath else { return nil }
        let prompt = """
        Review the current uncommitted changes in this worktree (git status, git diff). \
        Report: correctness issues first, then design concerns, then nitpicks. \
        Quote file:line for every finding. End with a verdict: ship / fix first.
        """
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: prompt,
                                               hookToken: token),
                workingDirectory: URL(fileURLWithPath: worktreePath),
                geometry: preferredGrid,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = record.projectID
            spec.sessionID = sessionID
            spec.title = "Review · \(record.title)"
            spec.badges = ["review"]
            let reviewID = try await manager.launch(spec)
            await cacheSurface(for: reviewID)
            tokenRegistry.register(token: token, session: reviewID)
            sessions.append(SessionItem(id: reviewID, title: "Review · \(record.title)",
                                        state: .starting, projectID: record.projectID,
                                        branch: record.branch, badges: ["review"]))
            reloadPersistedSessions()
            return reviewID
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    // MARK: - Pipelines (v3): chain a follow-up session on completion

    /// "When this session ends, start a new one with this goal" — the minimal
    /// pipeline: one link, same project, fresh worktree. In-memory by design:
    /// a follow-up only makes sense for a session alive in this app run.
    public private(set) var followUps: [SessionID: String] = [:]

    public func setFollowUp(_ prompt: String?, for id: SessionID) {
        let cleaned = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            followUps.removeValue(forKey: id)
        } else {
            followUps[id] = cleaned
        }
    }

    // MARK: - Full-text search (v2): transcripts indexed per session

    /// The de-ANSI-fied transcript of a session, concatenated from its own
    /// directory (per-session sinks) — nil when the session never wrote one.
    /// nonisolated static: runs on any executor, never blocks the UI (P1 perf).
    private nonisolated static func transcriptText(root: URL, id: SessionID) -> String? {
        let directory = root.appendingPathComponent(id.rawValue.uuidString)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        let plain = files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var text = ""
        // Capped by bytes READ: a rotated 10 MB file used to be loaded whole
        // before the cap was even looked at. FTS does not need more to be useful.
        var remaining = Self.indexedTranscriptCap
        for file in plain where remaining > 0 {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: remaining), !data.isEmpty else { continue }
            text += String(decoding: data, as: UTF8.self)
            remaining -= data.count
        }
        return text.isEmpty ? nil : text
    }

    private static let indexedTranscriptCap = 2_000_000

    /// Size and last write of a session's transcript files — what the FTS row
    /// is compared against before anything is read. nil = no transcript.
    private nonisolated static func transcriptFingerprint(root: URL, id: SessionID)
        -> SessionStore.IndexFingerprint? {
        let directory = root.appendingPathComponent(id.rawValue.uuidString)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        var bytes: Int64 = 0
        var modifiedAt: Double = 0
        var found = false
        for file in files where file.pathExtension == "txt" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { continue }
            found = true
            bytes += Int64(values.fileSize ?? 0)
            modifiedAt = max(modifiedAt, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return found ? SessionStore.IndexFingerprint(bytes: bytes, modifiedAt: modifiedAt) : nil
    }

    func indexSessionForSearch(_ id: SessionID) {
        guard let store else { return }
        let root = supportDirectory.appendingPathComponent("transcripts")
        Task.detached(priority: .utility) {
            // Stat BEFORE reading: a flush landing between the two would stamp
            // the row with more content than it holds, and the next launch
            // would skip that tail for good. Older than the file, it re-indexes.
            let fingerprint = Self.transcriptFingerprint(root: root, id: id)
            guard let record = (try? store.session(id: id)) ?? nil,
                  let text = Self.transcriptText(root: root, id: id) else { return }
            try? store.indexForSearch(session: id, title: record.title, transcript: text,
                                      fingerprint: fingerprint)
        }
    }

    /// Startup pass: index every known session whose transcript CHANGED since
    /// it was last indexed — a stat per session, no read and no write for the
    /// rest. It used to re-read and re-tokenise every transcript ever written
    /// at each launch, one write transaction each, on the one connection every
    /// read then waited on (audit 2026-09-22, hot path 3). Off the main actor.
    private func reindexAllSessions() {
        guard let store else { return }
        let root = supportDirectory.appendingPathComponent("transcripts")
        let ids = allRecords.map(\.id)
        Task.detached(priority: .utility) {
            for id in ids {
                guard let fingerprint = Self.transcriptFingerprint(root: root, id: id) else { continue }
                if let indexed = (try? store.indexedFingerprint(session: id)) ?? nil,
                   indexed == fingerprint { continue }
                guard let record = (try? store.session(id: id)) ?? nil,
                      let text = Self.transcriptText(root: root, id: id) else { continue }
                try? store.indexForSearch(session: id, title: record.title, transcript: text,
                                          fingerprint: fingerprint)
            }
        }
    }

    /// Off the main actor: the palette queries on every keystroke and the FTS
    /// lookup walks the whole index. SessionStore is Sendable — GRDB's
    /// DatabaseQueue serialises access itself.
    public func searchTranscripts(_ query: String) async -> [SessionStore.SearchHit] {
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ((try? store.searchTranscripts(matching: query)) ?? nil) ?? []
        }.value
    }

    /// A session's record for the info panel (breadcrumb chevron).
    public func sessionInfo(_ id: SessionID) -> SessionRecord? {
        (try? store?.session(id: id)) ?? nil
    }

    /// The last moment the session's state moved (journal, STA-06) or its
    /// process ended — "last activity" in the session info. Nil before any
    /// transition was journaled.
    public func lastActivity(of id: SessionID) -> Date? {
        let transition = (try? store?.lastTransitionDate(session: id)) ?? nil
        let ended = sessionInfo(id)?.endedAt
        return [transition, ended].compactMap { $0 }.max()
    }

    /// What the session info panel shows, read off the main actor in one go:
    /// its body used to run three store reads per pass, one fetching the
    /// whole transition journal to take its last row.
    public func sessionInfoSnapshot(_ id: SessionID) async -> (record: SessionRecord?, lastActivity: Date?) {
        guard let store else { return (nil, nil) }
        return await Task.detached(priority: .userInitiated) {
            let record = (try? store.session(id: id)) ?? nil
            let transition = (try? store.lastTransitionDate(session: id)) ?? nil
            return (record, [transition, record?.endedAt].compactMap { $0 }.max())
        }.value
    }

    /// Removes the project from the app (archived in the database): the local
    /// folder and the session records stay intact.
    public func removeProject(_ id: ProjectID) {
        try? store?.archiveProject(id)
        if selectedProject == id { selectedProject = nil }
        reloadPersistedSessions()
    }

    /// The sidebar order belongs to the user (drag and drop): a simple display
    /// preference, persisted outside the database — unknowns go to the end.
    public func reorderProjects(dragged: ProjectID, before target: ProjectID) {
        guard let from = projects.firstIndex(where: { $0.id == dragged }),
              let to = projects.firstIndex(where: { $0.id == target }), from != to else { return }
        projects.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        UserDefaults.standard.set(projects.map(\.id.rawValue.uuidString),
                                  forKey: "loom.projects.order")
    }

    /// `nil` when the remembered project has since been removed.
    private var lastOpenedProject: ProjectID? {
        guard let saved = UserDefaults.standard.string(forKey: "loom.project.last"),
              let uuid = UUID(uuidString: saved)
        else { return nil }
        let id = ProjectID(uuid)
        return projects.contains { $0.id == id } ? id : nil
    }

    private func applySavedProjectOrder() {
        guard let order = UserDefaults.standard.stringArray(forKey: "loom.projects.order")
        else { return }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        projects = projects.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id.rawValue.uuidString] ?? Int.max
            let r = rank[rhs.element.id.rawValue.uuidString] ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// SES-04: a free shell in the parent session's worktree — the card
    /// appears indented under it ("Term n"). Shells die with the app and
    /// are never offered for Resume (no native conversation).
    @discardableResult
    public func launchShell(for parent: SessionItem, title: String? = nil) async -> SessionID? {
        guard let manager else { return nil }
        let record = (try? store?.session(id: parent.id)) ?? nil
        guard let directory = workingDirectory(worktreePath: record?.worktreePath,
                                               project: project(parent.projectID))
        else {
            startupError = """
            Could not open a terminal for \(parent.title): its folder is missing \
            or its project is no longer in Loom.
            """
            return nil
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let count = sessions.filter { $0.parentID == parent.id }.count
            + dormantShells.filter { $0.parentID == parent.id }.count + 1
        let name = title ?? "Term \(count)"
        var spec = SessionManager.SessionSpec(
            command: Command(executable: shell, arguments: ["-l"]),
            workingDirectory: directory,
            geometry: preferredGrid,
            samplingInterval: .seconds(1))
        spec.title = name
        spec.projectID = parent.projectID
        do {
            let id = try await manager.launch(spec)
            await cacheSurface(for: id)
            sessions.append(SessionItem(id: id, title: name, state: .starting,
                                        projectID: parent.projectID, branch: parent.branch,
                                        parentID: parent.id, isShell: true))
            saveStackChildren()
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    // MARK: - Stack memory (the name, the Term/Web tabs survive relaunch)

    /// A stack terminal whose PTY died with the app: the ROW survives —
    /// clicking relaunches a shell with the same name in the same worktree.
    public struct DormantShell: Identifiable, Codable, Equatable {
        public var id = UUID()
        public var title: String
        public var parentID: SessionID
    }

    public private(set) var dormantShells: [DormantShell] = []

    /// Claude sessions closed but not destroyed ("inactive"): they stay in
    /// their stack with their tabs — only those without a conversation (never
    /// a single message) disappear, via the ClaudeNativeSessions.exists filter.
    /// Compared by NATIVE conversation: a live session that adopted another
    /// record's conversation (`/resume <id>` in its terminal) hides that
    /// record — two claude processes must never resume the same conversation.
    public var dormantSessions: [SessionRecord] {
        (interruptedSessions + historySessions).filter { record in
            record.state != .archived
                && !sessions.contains { $0.id == record.id || $0.nativeID == record.resolvedNativeSessionID }
        }
    }

    public func resumeDormant(_ id: SessionID) async {
        guard let record = allRecords.first(where: { $0.id == id }) else { return }
        await resumeSession(record)
    }

    public func forgetDormantShell(_ dormant: DormantShell) {
        dormantShells.removeAll { $0.id == dormant.id }
        saveStackChildren()
    }

    public func reopenDormantShell(_ dormant: DormantShell) async -> SessionID? {
        guard let parent = stackParent(dormant.parentID) else { return nil }
        dormantShells.removeAll { $0.id == dormant.id }
        return await launchShell(for: parent, title: dormant.title)
    }

    private func stackParent(_ id: SessionID) -> SessionItem? {
        if let live = sessions.first(where: { $0.id == id }) { return live }
        return allRecords.first { $0.id == id }.map {
            SessionItem(id: $0.id, title: $0.title, state: $0.state,
                        projectID: $0.projectID, branch: $0.branch, badges: $0.badges,
                        nativeSessionID: $0.nativeSessionID)
        }
    }

    private struct PersistedPane: Codable {
        var title: String
        var parentID: SessionID?
        var urls: [String]
    }

    private struct PersistedChildren: Codable {
        var shells: [DormantShell]
        var panes: [PersistedPane]
    }

    /// Snapshots the stack children on every mutation: at the next launch,
    /// today's live shells will be tomorrow's dormant ones.
    func saveStackChildren() {
        let shells = sessions.filter(\.isShell).compactMap { item in
            item.parentID.map { DormantShell(title: item.title, parentID: $0) }
        }
        let panes = browserPanes.map { pane in
            PersistedPane(title: pane.title, parentID: pane.parentID,
                          urls: pane.controller.tabs.map(\.url.absoluteString))
        }
        let payload = PersistedChildren(shells: shells + dormantShells, panes: panes)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: "loom.stack.children")
        }
    }

    func restoreStackChildren() {
        guard let data = UserDefaults.standard.data(forKey: "loom.stack.children"),
              let payload = try? JSONDecoder().decode(PersistedChildren.self, from: data)
        else { return }
        // A dormant only makes sense if its parent still exists somewhere.
        dormantShells = payload.shells.filter { shell in
            allRecords.contains { $0.id == shell.parentID }
        }
        for record in payload.panes {
            let pane = BrowserPane(title: record.title, parentID: record.parentID)
            pane.controller.restoreTabs(urlStrings: record.urls)   // model only, until shown
            browserPanes.append(pane)
        }
    }

    // MARK: - Browser panes (WEB-03: a dedicated browser INSIDE a session's stack)

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

    /// Each open creates a dedicated pane, child of the session (or global if nil).
    @discardableResult
    public func openBrowserPane(for parent: SessionID?) -> UUID {
        let count = browserPanes.filter { $0.parentID == parent }.count + 1
        let pane = BrowserPane(title: "Web \(count)", parentID: parent)
        browserPanes.append(pane)
        saveStackChildren()
        return pane.id
    }

    public func closeBrowserPane(_ id: UUID) {
        browserPanes.removeAll { $0.id == id }
        saveStackChildren()
    }

    public func browserPane(_ id: UUID) -> BrowserPane? {
        browserPanes.first { $0.id == id }
    }

    /// SES-05: renaming — the card, the breadcrumb, and the database follow.
    public func renameSession(_ id: SessionID, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        try? store?.rename(session: id, to: cleaned)
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = cleaned
        }
        reloadPersistedSessions()
    }

    /// Auto name at birth, in the vibe of the reference: `<project>-<hex>`.
    static func generatedName(project: ProjectRecord?) -> String {
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(project?.name ?? "session")-\(suffix)"
    }

    /// The input field's `/` helper: skills from the session's worktree (the
    /// checkout carries the project's — SKL-08) + global skills.
    public func skills(for id: SessionID) -> [SkillEntry] {
        let record = (try? store?.session(id: id)) ?? nil
        let projectDirectory = (record?.worktreePath
            ?? record?.projectID.flatMap { pid in project(pid)?.path })
            .map { URL(fileURLWithPath: $0).appendingPathComponent(".claude/skills") }
        return SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory,
                                  projectDirectory: projectDirectory)
    }

    /// SKL-01 at the project level: project skills (root/.claude/skills) ahead
    /// of global ones — same shadowing rule as for sessions.
    public func skills(forProject id: ProjectID) -> [SkillEntry] {
        let projectDirectory = project(id).map {
            URL(fileURLWithPath: $0.path).appendingPathComponent(".claude/skills")
        }
        return SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory,
                                  projectDirectory: projectDirectory)
    }

    public struct ProjectGitData: Sendable {
        public var branch: String
        public var changes: [FileChange]
    }

    /// Git for the project's ROOT folder (session worktrees have their
    /// dedicated panel in the session view).
    public func projectGit(_ id: ProjectID) async -> ProjectGitData? {
        guard let path = project(id)?.path else { return nil }
        let root = URL(fileURLWithPath: path)
        let git = GitService()
        guard let branch = try? await git.currentBranch(in: root) else { return nil }
        let changes = (try? await git.status(in: root)) ?? []
        return ProjectGitData(branch: branch, changes: changes)
    }

    public struct FileEntry: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var name: String
        public var path: String       // relative to the project root
        public var isDirectory: Bool
    }

    /// Read-only listing of a project folder — directories first, hidden ones
    /// excluded (except .claude, useful for finding skills and rules).
    public func listFiles(in id: ProjectID, at relativePath: String) -> [FileEntry] {
        guard let rootPath = project(id)?.path else { return [] }
        return Self.listFiles(root: rootPath, at: relativePath)
    }

    /// The listing stats every entry: off the main actor for the Files tab.
    public func listFilesDetached(in id: ProjectID, at relativePath: String) async -> [FileEntry] {
        guard let rootPath = project(id)?.path else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.listFiles(root: rootPath, at: relativePath)
        }.value
    }

    /// Skills scan two directory trees: off the main actor for the Skills tab.
    public func skillsDetached(forProject id: ProjectID) async -> [SkillEntry] {
        let projectDirectory = project(id).map {
            URL(fileURLWithPath: $0.path).appendingPathComponent(".claude/skills")
        }
        return await Task.detached(priority: .userInitiated) {
            SkillsCatalog.scan(globalDirectory: SkillsCatalog.defaultGlobalDirectory,
                               projectDirectory: projectDirectory)
        }.value
    }

    private nonisolated static func listFiles(root rootPath: String, at relativePath: String) -> [FileEntry] {
        let directory = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents
            .filter { !$0.lastPathComponent.hasPrefix(".") || $0.lastPathComponent == ".claude" }
            .map { url in
                FileEntry(name: url.lastPathComponent,
                          path: relativePath.isEmpty ? url.lastPathComponent
                                                     : relativePath + "/" + url.lastPathComponent,
                          isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                              .isDirectory ?? false)
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased())
                      < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public struct RuleFile: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        public var content: String
    }

    /// The rules that agents will read in this project: known instruction
    /// files present at the root (or .claude/).
    public func ruleFiles(for id: ProjectID) -> [RuleFile] {
        guard let rootPath = project(id)?.path else { return [] }
        let root = URL(fileURLWithPath: rootPath)
        let candidates = ["CLAUDE.md", "AGENTS.md", "CONTEXT.md", ".claude/CLAUDE.md",
                          ".cursorrules", ".github/copilot-instructions.md"]
        return candidates.compactMap { name in
            let url = root.appendingPathComponent(name)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return RuleFile(name: name, content: content)
        }
    }

    // MARK: - Project card counters (reference: "2 active · 4 sessions")

    public func activeCount(for projectID: ProjectID) -> Int {
        sessions.filter { $0.projectID == projectID && [.working, .needsInput, .starting, .idle].contains($0.state) }.count
    }

    public func sessionCount(for projectID: ProjectID) -> Int {
        allRecords.filter { $0.projectID == projectID }.count
    }

    public func lastActivity(for projectID: ProjectID) -> Date? {
        allRecords.filter { $0.projectID == projectID }.map(\.createdAt).max()
    }

    /// PRJ-01: registers a folder as a project — or finds it, when the same
    /// folder is already one: picking it twice must not make two projects.
    /// If it is a Git repo, the current branch is detected; the app never
    /// modifies the folder. Returns the project, selected.
    @discardableResult
    public func addProject(at url: URL) async -> ProjectID {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) {
            selectedProject = existing.id
            return existing.id
        }
        let isGit = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        let branch = isGit ? try? await GitService().currentBranch(in: url) : nil
        let record = ProjectRecord(id: ProjectID(), name: url.lastPathComponent,
                                   path: path, defaultBranch: branch, createdAt: Date())
        try? store?.insertProject(record)
        reloadPersistedSessions()
        selectedProject = record.id
        return record.id
    }

    /// The folder picker every "add a project" entry point shares. Modal:
    /// returns the chosen folder, or nil when cancelled.
    public static func pickFolder(title: String = "Choose a project folder") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Whether a project folder can host worktrees at all.
    public func isGitRepository(_ projectID: ProjectID?) -> Bool {
        guard let project = project(projectID) else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: project.path).appendingPathComponent(".git").path)
    }

    public func project(_ id: ProjectID?) -> ProjectRecord? {
        projects.first { $0.id == id }
    }

    /// No home fallback: an agent launched there would get the whole home, and
    /// a failed `chdir` is ignored downstream (SwiftTerm `Pty.swift`), so a
    /// stale path would start the agent wherever the app happens to sit.
    private func workingDirectory(worktreePath: String?,
                                  project: ProjectRecord?) -> URL? {
        guard let candidate = worktreePath.map(URL.init(fileURLWithPath:))
            ?? project.map({ URL(fileURLWithPath: $0.path) })
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    /// UC-7: Resume — same identifier, hooks re-injected, original worktree.
    /// If claude never persisted the conversation (session launched but never
    /// used), `--resume` would have nothing to resume: we relaunch FRESH under
    /// the same UUID in the same worktree — "Resume" can no longer fail.
    public func resumeSession(_ record: SessionRecord) async {
        guard let manager else { return }
        let token = UUID().uuidString
        // The conversation to pick up is the NATIVE one — the imposed UUID,
        // unless a `/resume <id>` in the terminal moved the session elsewhere.
        let native = record.resolvedNativeSessionID
        let command = nativeSessionExists(record)
            ? adapter.resumeCommand(session: native, hookToken: token)
            : adapter.launchCommand(session: record.id, initialPrompt: nil, hookToken: token)
        guard let directory = workingDirectory(worktreePath: record.worktreePath,
                                               project: project(record.projectID))
        else {
            startupError = """
            Could not resume \(record.title): its folder is missing or its \
            project is no longer in Loom.
            """
            return
        }
        do {
            try await manager.resume(record, command: command, workingDirectory: directory,
                                     geometry: preferredGrid,
                                     samplingInterval: .milliseconds(500), hookToken: token)
            await cacheSurface(for: record.id)
            tokenRegistry.register(token: token, session: record.id)
            sessions.append(SessionItem(id: record.id, title: record.title, state: .starting,
                                        projectID: record.projectID, branch: record.branch,
                                        badges: record.badges,
                                        nativeSessionID: record.nativeSessionID))
            interruptedSessions.removeAll { $0.id == record.id }
        } catch {
            startupError = String(describing: error)
        }
    }

    /// SES-07: archives and moves to history.
    public func archiveSession(_ id: SessionID) async {
        await manager?.archive(id)
        sessions.removeAll { $0.id == id }
        reloadPersistedSessions()
    }

    /// The IPC server validates SYNCHRONOUSLY on its own queue: the token
    /// registry lives behind a lock, never behind the MainActor.
    private let tokenRegistry = TokenRegistry()

    final class TokenRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var sessionsByToken: [String: SessionID] = [:]
        func register(token: String, session: SessionID) {
            lock.withLock { sessionsByToken[token] = session }
        }
        /// A dead session's hook must stop resolving: the manager already
        /// dropped its token, the server's registry has to follow.
        func unregister(session: SessionID) {
            lock.withLock { sessionsByToken = sessionsByToken.filter { $0.value != session } }
        }
        func session(for token: String) -> SessionID? {
            lock.withLock { sessionsByToken[token] }
        }
    }

    private func observeStates(of manager: SessionManager) async {
        let updates = await manager.stateUpdates()
        for await update in updates {
            let index = sessions.firstIndex(where: { $0.id == update.id })
            // A terminal state must be processed even when the item is already
            // gone (optimistic close) — that is what turns the record into an
            // "inactive" card, indexes the transcript and fires the follow-up.
            guard index != nil || pendingCloseProjects[update.id] != nil else { continue }
            // The process is dead (⌃C⌃C, exit, crash): the live card closes
            // on its own — the session reappears "inactive" in its stack if it
            // has a conversation, disappears otherwise (reload filter).
            if [.completed, .failed, .interrupted].contains(update.state) {
                let closed = update.id
                // The item may already be gone (optimistic close) — its project
                // was parked in pendingCloseProjects, which also says the close
                // was ASKED for rather than suffered.
                let requested = pendingCloseProjects.removeValue(forKey: closed)
                let closedProject = sessions.first(where: { $0.id == closed })?.projectID
                    ?? requested ?? nil
                sessions.removeAll { $0.id == closed }
                tokenRegistry.unregister(session: closed)
                nativeExistsCache.removeValue(forKey: closed)   // settled at close: rescan once
                surfaceCache.removeValue(forKey: closed)
                saveStackChildren()
                // SES-07: a close the user asked for — the cross, or `exit`,
                // which leaves through code 0 — archives on the spot. A session
                // that DIED keeps its inactive card, so UC-7 Resume after a
                // crash stays one click away.
                if requested != nil || update.state == .completed {
                    await archiveSession(closed)
                } else {
                    reloadPersistedSessions()
                }
                indexSessionForSearch(closed)
                // v3 pipeline: the queued follow-up takes over, same project.
                if let next = followUps.removeValue(forKey: closed) {
                    Task { await self.launchSession(prompt: next, in: closedProject) }
                }
            } else if let index {
                sessions[index].state = update.state
            }
        }
    }

    /// The process of a live session switched conversation: its item and its
    /// record follow, and the "does it have a conversation" memo of that
    /// record is stale — the file to look for is another one now.
    private func observeIdentities(of manager: SessionManager) async {
        let updates = await manager.identityUpdates()
        for await update in updates {
            if let index = sessions.firstIndex(where: { $0.id == update.id }) {
                sessions[index].nativeSessionID =
                    update.nativeSessionID == update.id ? nil : update.nativeSessionID
            }
            nativeExistsCache.removeValue(forKey: update.id)
            reloadPersistedSessions()
        }
    }

    // MARK: - Actions (UC-1, SES-06)

    /// Where a new session works: straight in the project folder, or on an
    /// isolated worktree of its own (GIT-01). A per-launch choice; the
    /// project's preference is only the default.
    public enum LaunchPlacement: Sendable, Equatable {
        case projectFolder
        case newWorktree
    }

    /// The placement a project launches with when nothing else is said.
    public func defaultPlacement(for projectID: ProjectID?) -> LaunchPlacement {
        worktreeEnabled(for: projectID) ? .newWorktree : .projectFolder
    }

    /// UC-1, per the reference: one click launches claude immediately in the
    /// project — no prior input; the goal is then typed in the terminal.
    /// (`prompt` remains possible for the palette or future shortcuts.)
    /// Returns the identifier of the created session.
    @discardableResult
    public func launchSession(prompt: String? = nil, in projectID: ProjectID? = nil,
                              placement: LaunchPlacement? = nil) async -> SessionID? {
        guard let manager else { return nil }
        if let projectID { selectedProject = projectID }
        let project = project(selectedProject)
        guard let directory = workingDirectory(worktreePath: nil, project: project)
        else {
            startupError = """
            Could not start a session: no project is selected, or its folder is \
            missing.
            """
            return nil
        }
        let placement = placement ?? defaultPlacement(for: project?.id)
        let initialPrompt = (prompt?.isEmpty == false) ? prompt : nil
        do {
            let sessionID = SessionID()
            let token = UUID().uuidString
            var spec = SessionManager.SessionSpec(
                command: adapter.launchCommand(session: sessionID, initialPrompt: initialPrompt,
                                               hookToken: token),
                workingDirectory: directory,
                geometry: preferredGrid,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = project?.id
            // A single UUID end to end: the `--session-id` one — Resume depends on it.
            spec.sessionID = sessionID
            spec.title = initialPrompt ?? Self.generatedName(project: project)
            // GIT-01 became a CHOICE, per launch: worktree isolation only when
            // asked (or when the project made it its default). A folder that is
            // not a git repository has no worktree to offer — the session runs
            // in it, and the record says so through its missing worktreePath.
            if placement == .newWorktree,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                spec.worktree = .create(repo: directory, slug: Self.slug(from: initialPrompt ?? ""))
            }
            let id = try await manager.launch(spec)
            await cacheSurface(for: id)
            tokenRegistry.register(token: token, session: id)
            let record = (try? store?.session(id: id)) ?? nil
            sessions.append(SessionItem(id: id, title: record?.title ?? "Session",
                                        state: .starting, projectID: project?.id,
                                        branch: record?.branch))
            reloadPersistedSessions()
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    /// "Fix the cache bug!" → `fix-the-cache-bug` (GIT-02).
    static func slug(from prompt: String) -> String {
        let cleaned = prompt.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-").prefix(40)
        return slug.isEmpty ? "session" : String(slug)
    }

    private var store: SessionStore?

    /// Usage & costs: the incremental index shares loom.sqlite with the store.
    public func usageIndex() -> UsageIndex? {
        store.map { UsageIndex(store: $0) }
    }

    /// Address bar history (WEB-01) — best-effort, never blocking.
    private var pendingStackSave: Task<Void, Never>?

    public func recordVisit(url: String, title: String) {
        // The panes' tabs are part of the remembered stack — debounced: page
        // navigations arrive in bursts (P2 perf).
        pendingStackSave?.cancel()
        pendingStackSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStackChildren()
        }
        // A page load is not worth a synchronous write on the main actor.
        guard let store else { return }
        let visitedAt = Date()
        Task.detached(priority: .utility) {
            try? store.recordVisit(url: url, title: title, at: visitedAt)
        }
    }

    /// Sessions whose tab was optimistically removed while the shutdown
    /// ladder still runs — the exit observer finishes their bookkeeping.
    private var pendingCloseProjects: [SessionID: ProjectID?] = [:]

    public func stopSession(_ id: SessionID) async {
        // OPTIMISTIC close: the tab disappears NOW — claude's exit takes
        // seconds (stop hooks, plugin teardown) and the ladder guarantees
        // death (double Ctrl+C, then SIGTERM/SIGKILL). The card returns as
        // "inactive" once the exit is observed and the record settles.
        if let item = sessions.first(where: { $0.id == id }) {
            pendingCloseProjects[id] = item.projectID
            sessions.removeAll { $0.id == id }
            saveStackChildren()
        }
        await manager?.stop(id, ladder: .close)
    }

    public struct GitPanelData {
        public let changes: [FileChange]
        public let diff: String
    }

    // MARK: - Ship (v2): commit / push / PR from a session worktree

    private func worktreeURL(for id: SessionID) -> URL? {
        ((try? store?.session(id: id)) ?? nil)?.worktreePath.map(URL.init(fileURLWithPath:))
    }

    /// Each action returns nil on success, or the error text to display —
    /// the panel reports the truth, never a phantom success.
    public func shipCommit(_ id: SessionID, message: String) async -> String? {
        guard let worktree = worktreeURL(for: id) else { return "No worktree for this session" }
        do { try await GitService().commitAll(in: worktree, message: message); return nil }
        catch { return Self.gitErrorText(error) }
    }

    public func shipPush(_ id: SessionID) async -> String? {
        guard let worktree = worktreeURL(for: id) else { return "No worktree for this session" }
        do { try await GitService().push(in: worktree); return nil }
        catch { return Self.gitErrorText(error) }
    }

    /// `gh pr create --fill` in the worktree. Success carries the PR URL.
    public func shipCreatePR(_ id: SessionID) async -> (success: Bool, message: String)? {
        guard let worktree = worktreeURL(for: id), let gh = GitHubService.ghPath else { return nil }
        let process = Process()
        process.executableURL = gh
        process.arguments = ["pr", "create", "--fill"]
        process.currentDirectoryURL = worktree
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        return await withCheckedContinuation { continuation in
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, outData, errData in
                    let out = String(decoding: outData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let err = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: status == 0
                                        ? (true, out) : (false, err.isEmpty ? out : err))
                }
            } catch {
                continuation.resume(returning: (false, String(describing: error)))
            }
        }
    }

    private static func gitErrorText(_ error: Error) -> String {
        if case GitError.commandFailed(_, _, let stderr) = error, !stderr.isEmpty { return stderr }
        return String(describing: error)
    }

    /// GIT-03: status + diff of the session's worktree, read-only.
    public func gitPanel(for id: SessionID) async -> GitPanelData? {
        let record = (try? store?.session(id: id)) ?? nil
        guard let path = record?.worktreePath else { return nil }
        let worktree = URL(fileURLWithPath: path)
        let git = GitService()
        let changes = (try? await git.status(in: worktree)) ?? []
        let diff = (try? await git.diff(in: worktree, changes: changes)) ?? ""
        return GitPanelData(changes: changes, diff: diff)
    }

    /// The surfaces of the live sessions, kept from the moment their runtime
    /// exists: a pane reads them synchronously and paints the retained screen
    /// in its first commit, where a hop to the session actor and back showed a
    /// spinner first (audit 2026-09-22, hot path 9). Dropped at close.
    @ObservationIgnored private var surfaceCache: [SessionID: TerminalSurface] = [:]

    public func cachedSurface(for id: SessionID) -> TerminalSurface? { surfaceCache[id] }

    private func cacheSurface(for id: SessionID) async {
        guard let surface = await manager?.runtime(for: id)?.surface() else { return }
        surfaceCache[id] = surface
    }

    public func surface(for id: SessionID) async -> TerminalSurface? {
        if let cached = surfaceCache[id] { return cached }
        guard let surface = await manager?.runtime(for: id)?.surface() else { return nil }
        surfaceCache[id] = surface
        return surface
    }
}
