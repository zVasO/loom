import LoomAgents
import LoomCore
import LoomGit
import LoomIPC
import LoomPersistence
import LoomSessions
import LoomTerminal
import LoomWeb
import Foundation
import Observation
import SwiftUI
import UserNotifications

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
        /// Badge label — resolved to a color by the badge definitions.
        public var badge: String?
    }

    // MARK: - Badges: user-defined labels with a color

    public struct BadgeDefinition: Identifiable, Equatable, Codable {
        public var id: String { name }
        public var name: String
        public var colorHex: String
    }

    public private(set) var badgeDefinitions: [BadgeDefinition] = {
        if let data = UserDefaults.standard.data(forKey: "loom.badges"),
           let saved = try? JSONDecoder().decode([BadgeDefinition].self, from: data) {
            return saved
        }
        return [BadgeDefinition(name: "review", colorHex: "#4CC38A"),
                BadgeDefinition(name: "wip", colorHex: "#E5B455"),
                BadgeDefinition(name: "urgent", colorHex: "#E5646C")]
    }()

    public func saveBadgeDefinitions(_ definitions: [BadgeDefinition]) {
        badgeDefinitions = definitions
        if let data = try? JSONEncoder().encode(definitions) {
            UserDefaults.standard.set(data, forKey: "loom.badges")
        }
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

    /// Assigns (or clears) a session's badge — card, fleet, tabs and base follow.
    public func setBadge(_ badge: String?, for id: SessionID) {
        try? store?.setBadge(session: id, badge: badge)
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].badge = badge
        }
        reloadPersistedSessions()
    }

    public private(set) var sessions: [SessionItem] = []
    /// PRJ-03: the sidebar groups by project.
    public private(set) var projects: [ProjectRecord] = []
    public var selectedProject: ProjectID?
    /// UC-7: offered for Resume on relaunch.
    public private(set) var interruptedSessions: [SessionRecord] = []
    /// SES-07: completed/failed/archived, browsable.
    public private(set) var historySessions: [SessionRecord] = []
    public private(set) var startupError: String?

    public func clearError() {
        startupError = nil
    }

    private(set) var manager: SessionManager?
    private let replyHandler = NotificationReplyHandler()
    private var hookServer: HookSocketServer?
    private let supportDirectory: URL
    private var socketURL: URL { supportDirectory.appendingPathComponent("loom.sock") }

    /// The grid actually displayed, remembered at each view measurement: the
    /// next sessions are BORN at the right size — claude paints its banner
    /// directly for the real grid, no more mangling reflow at startup.
    public private(set) var preferredGrid: TerminalGeometry = {
        let cols = UserDefaults.standard.integer(forKey: "loom.terminal.cols")
        let rows = UserDefaults.standard.integer(forKey: "loom.terminal.rows")
        return cols >= 40 && rows >= 10 ? TerminalGeometry(cols: cols, rows: rows) : .default
    }()

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

    /// P0 perf — the Settings refresh rate as a frame interval (default 30 fps).
    public static func preferredFrameInterval() -> Duration {
        let fps = UserDefaults.standard.integer(forKey: "loom.terminal.fps")
        let clamped = [30, 60, 120].contains(fps) ? fps : 30
        return .milliseconds(1000 / clamped)
    }

    public func applyFrameRate() {
        let interval = Self.preferredFrameInterval()
        Task { await manager?.setFrameInterval(interval) }
    }

    public func noteTerminalGrid(cols: Int, rows: Int) {
        // Only a grid plausible for a real window is remembered: a transient
        // measurement (layout in progress) must never poison the launch
        // geometry of the next sessions.
        guard cols >= 40, rows >= 10 else { return }
        preferredGrid = TerminalGeometry(cols: cols, rows: rows)
        UserDefaults.standard.set(cols, forKey: "loom.terminal.cols")
        UserDefaults.standard.set(rows, forKey: "loom.terminal.rows")
    }

    /// UIX-06: the claude binary located at launch (GUI apps don't see the
    /// shell's PATH — an absolute path is the only reliable way).
    public private(set) var claudePath: URL? = ClaudeLocator.locate()
    public var claudeSearchedLocations: [String] { ClaudeLocator.wellKnownLocations }

    /// The adapter talks to the CLI with the full hooks wiring (ADR-0005).
    private var adapter: ClaudeCodeAdapter {
        ClaudeCodeAdapter(executable: claudePath?.path ?? "claude",
                          hooks: .init(helper: Self.helperBinaryURL(fallback: supportDirectory),
                                       socket: socketURL))
    }

    /// In development, `loom-hook` is a sibling product of the app; packaged,
    /// it will live in the bundle and then be copied to Application Support.
    static func helperBinaryURL(fallback supportDirectory: URL) -> URL {
        let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("loom-hook")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return supportDirectory.appendingPathComponent("loom-hook")
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
            let store = try SessionStore(path: supportDirectory.appendingPathComponent("loom.sqlite").path)
            self.store = store
            try store.markLiveSessionsInterrupted()

            let transcripts = try FileTranscriptSink(
                directory: supportDirectory.appendingPathComponent("transcripts"))
            // v2 (search): one sink per session, in its own directory — this is
            // what makes transcripts indexable per session.
            let transcriptsRoot = supportDirectory.appendingPathComponent("transcripts")
            let manager = SessionManager(
                runtimeDependencies: SessionRuntime.Dependencies(ptyHost: ForkPTYHost(),
                                                                 transcript: transcripts),
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
            restoreStackChildren()
            reindexAllSessions()
        } catch {
            startupError = String(describing: error)
        }
    }

    /// All known records — counters and dates for the project cards.
    public private(set) var allRecords: [SessionRecord] = []

    /// P1 perf: exists() scans ~/.claude/projects directories — memoized per
    /// session; a closed session's native file is settled, so entries only
    /// need invalidation right when a session closes.
    private var nativeExistsCache: [SessionID: Bool] = [:]

    private func nativeSessionExists(_ id: SessionID) -> Bool {
        if let cached = nativeExistsCache[id] { return cached }
        let exists = ClaudeNativeSessions.exists(id)
        nativeExistsCache[id] = exists
        return exists
    }

    private func reloadPersistedSessions() {
        let all = ((try? store?.allSessions()) ?? nil) ?? []
        allRecords = all
        // A closed session with no persisted conversation has nothing to show or
        // to resume: it doesn't clutter the lists (pre-fix identifier wrecks
        // disappear at the same time).
        interruptedSessions = all.filter {
            $0.state == .interrupted && nativeSessionExists($0.id)
        }
        historySessions = all.filter {
            [.completed, .failed, .archived].contains($0.state) && nativeSessionExists($0.id)
        }
        projects = ((try? store?.activeProjects()) ?? nil) ?? []
        applySavedProjectOrder()
        if selectedProject == nil { selectedProject = projects.first?.id }
    }

    // MARK: - v4: GitHub PR review through the user's authenticated gh

    private func projectRepo(_ id: ProjectID?) -> URL? {
        project(id).map { URL(fileURLWithPath: $0.path) }
    }

    public func listPRs(for projectID: ProjectID) async -> [GitHubService.PullRequest] {
        guard let repo = projectRepo(projectID) else { return [] }
        return (try? await GitHubService().listPRs(in: repo)) ?? []
    }

    public func prDetail(_ number: Int, in projectID: ProjectID) async -> GitHubService.PRDetail? {
        guard let repo = projectRepo(projectID) else { return nil }
        return try? await GitHubService().prDetail(number, in: repo)
    }

    public func prDiff(_ number: Int, in projectID: ProjectID) async -> String {
        guard let repo = projectRepo(projectID) else { return "" }
        return (try? await GitHubService().prDiff(number, in: repo)) ?? ""
    }

    /// nil on success, error text otherwise — the panel reports the truth.
    public func submitPRReview(_ number: Int, verdict: GitHubService.Verdict,
                               body: String, in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do { try await GitHubService().submitReview(number, verdict: verdict, body: body, in: repo); return nil }
        catch { return Self.ghErrorText(error) }
    }

    public func commentPR(_ number: Int, body: String, in projectID: ProjectID) async -> String? {
        guard let repo = projectRepo(projectID) else { return "No repo for this project" }
        do { try await GitHubService().comment(number, body: body, in: repo); return nil }
        catch { return Self.ghErrorText(error) }
    }

    private static func ghErrorText(_ error: Error) -> String {
        if case GitHubService.GitHubError.commandFailed(_, let stderr) = error, !stderr.isEmpty {
            return stderr
        }
        return String(describing: error)
    }

    // MARK: - Global PRs tab: cache + PR ↔ review session mapping

    public private(set) var prCache: [ProjectID: [GitHubService.PullRequest]] = [:]
    public private(set) var prLoading: Set<ProjectID> = []

    public func refreshPRs(for projectID: ProjectID) async {
        guard !prLoading.contains(projectID) else { return }
        prLoading.insert(projectID)
        prCache[projectID] = await listPRs(for: projectID)
        prLoading.remove(projectID)
    }

    private func prKey(_ number: Int, _ projectID: ProjectID) -> String {
        "\(projectID.rawValue.uuidString)#\(number)"
    }

    /// The review session attached to a PR, when it still exists somewhere
    /// (live or resumable). Mapping persisted across launches.
    public func reviewSession(forPR number: Int, in projectID: ProjectID) -> SessionID? {
        let map = UserDefaults.standard.dictionary(forKey: "loom.pr.sessions") as? [String: String]
        guard let raw = map?[prKey(number, projectID)], let uuid = UUID(uuidString: raw)
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
    }

    /// The PR tab's quick action: ONE review session per PR — reattached when
    /// it exists (resumed if dormant), created otherwise: PR checked out in a
    /// dedicated worktree, claude primed as reviewer, badge "PR #n".
    public func launchPRReviewSession(_ pr: GitHubService.PullRequest,
                                      in projectID: ProjectID) async -> SessionID? {
        if let existing = reviewSession(forPR: pr.number, in: projectID) {
            if sessions.contains(where: { $0.id == existing }) { return existing }
            await resumeDormant(existing)
            return existing
        }
        guard let manager, let repo = projectRepo(projectID) else { return nil }
        guard let worktree = try? await GitHubService().checkoutPR(pr.number, repo: repo)
        else { return nil }
        let prompt = """
        You are reviewing PR #\(pr.number) ("\(pr.title)"), checked out in this worktree. \
        Read the diff (gh pr diff \(pr.number)) and the touched files. Report findings in \
        order: correctness first, then design, then nitpicks — quote file:line for each. \
        End with a verdict: ship / fix first. The user may then ask about specific lines.
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
            spec.title = "PR #\(pr.number) · review"
            spec.badge = "PR #\(pr.number)"
            let id = try await manager.launch(spec)
            tokenRegistry.register(token: token, session: id)
            sessions.append(SessionItem(id: id, title: "PR #\(pr.number) · review",
                                        state: .starting, projectID: projectID,
                                        branch: pr.branch, badge: "PR #\(pr.number)"))
            rememberReviewSession(id, forPR: pr.number, in: projectID)
            reloadPersistedSessions()
            return id
        } catch {
            startupError = String(describing: error)
            return nil
        }
    }

    /// Phase 4 — diff quick actions: guarantees the PR's review session and
    /// delivers the message once the agent has painted (fresh sessions boot
    /// for seconds; sending into the void helps nobody).
    public func sendToPRReviewSession(_ message: String,
                                      pr: GitHubService.PullRequest,
                                      in projectID: ProjectID) async -> SessionID? {
        guard let id = await launchPRReviewSession(pr, in: projectID) else { return nil }
        guard let surface = await surface(for: id) else { return id }
        for _ in 0..<40 where surface.screen.revision == 0 {
            try? await Task.sleep(for: .milliseconds(500))
        }
        surface.send(message + "\r")
        return id
    }

    /// The guided tour: claude -p over the PR diff, strict-JSON answer parsed
    /// into chapters + a playful risk gauge. Slow (an agent run) — call it from
    /// a task, show progress.
    public func generateTour(_ number: Int, in projectID: ProjectID) async -> PRTour? {
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
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let output: String = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: String(
                    decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
        }
        return PRTourParser.parse(claudeOutput: output)
    }

    /// "Ask the guide": the PR checked out into a dedicated worktree, and an
    /// interactive session primed as its tour guide.
    public func askGuide(about number: Int, title: String, tour: PRTour?,
                         in projectID: ProjectID) async -> SessionID? {
        guard let manager, let repo = projectRepo(projectID) else { return nil }
        guard let worktree = try? await GitHubService().checkoutPR(number, repo: repo) else { return nil }
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
            spec.badge = "PR #\(number)"
            let id = try await manager.launch(spec)
            tokenRegistry.register(token: token, session: id)
            sessions.append(SessionItem(id: id, title: "PR #\(number) · guide",
                                        state: .starting, projectID: projectID,
                                        branch: nil, badge: "PR #\(number)"))
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
            spec.badge = "review"
            let reviewID = try await manager.launch(spec)
            tokenRegistry.register(token: token, session: reviewID)
            sessions.append(SessionItem(id: reviewID, title: "Review · \(record.title)",
                                        state: .starting, projectID: record.projectID,
                                        branch: record.branch, badge: "review"))
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
        for file in plain {
            if let chunk = try? String(contentsOf: file, encoding: .utf8) { text += chunk }
            if text.count > 2_000_000 { break }   // FTS does not need more to be useful
        }
        return text.isEmpty ? nil : text
    }

    func indexSessionForSearch(_ id: SessionID) {
        guard let store else { return }
        let root = supportDirectory.appendingPathComponent("transcripts")
        Task.detached(priority: .utility) {
            guard let record = (try? store.session(id: id)) ?? nil,
                  let text = Self.transcriptText(root: root, id: id) else { return }
            try? store.indexForSearch(session: id, title: record.title, transcript: text)
        }
    }

    /// Startup pass: (re)index every known session that has a transcript —
    /// idempotent, off the main actor (P1 perf: MBs of file reads).
    private func reindexAllSessions() {
        guard let store else { return }
        let root = supportDirectory.appendingPathComponent("transcripts")
        let ids = allRecords.map(\.id)
        Task.detached(priority: .utility) {
            for id in ids {
                guard let record = (try? store.session(id: id)) ?? nil,
                      let text = Self.transcriptText(root: root, id: id) else { continue }
                try? store.indexForSearch(session: id, title: record.title, transcript: text)
            }
        }
    }

    public func searchTranscripts(_ query: String) -> [SessionStore.SearchHit] {
        ((try? store?.searchTranscripts(matching: query)) ?? nil) ?? []
    }

    /// A session's record for the info panel (breadcrumb chevron).
    public func sessionInfo(_ id: SessionID) -> SessionRecord? {
        (try? store?.session(id: id)) ?? nil
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
        let directory = record?.worktreePath.map(URL.init(fileURLWithPath:))
            ?? project(parent.projectID).map { URL(fileURLWithPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser
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
    public var dormantSessions: [SessionRecord] {
        (interruptedSessions + historySessions).filter { record in
            record.state != .archived && !sessions.contains { $0.id == record.id }
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
                        projectID: $0.projectID, branch: $0.branch)
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
            for url in record.urls { pane.controller.openTab(urlString: url) }
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

    /// PRJ-01: adds a project by pointing at a folder; if it is a Git repo, the
    /// current branch is detected. The app never modifies the folder.
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

    /// UC-7: Resume — same identifier, hooks re-injected, original worktree.
    /// If claude never persisted the conversation (session launched but never
    /// used), `--resume` would have nothing to resume: we relaunch FRESH under
    /// the same UUID in the same worktree — "Resume" can no longer fail.
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
                                     geometry: preferredGrid,
                                     samplingInterval: .milliseconds(500), hookToken: token)
            tokenRegistry.register(token: token, session: record.id)
            sessions.append(SessionItem(id: record.id, title: record.title, state: .starting,
                                        projectID: record.projectID, branch: record.branch,
                                        badge: record.badge))
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
                // was parked in pendingCloseProjects.
                let closedProject = sessions.first(where: { $0.id == closed })?.projectID
                    ?? pendingCloseProjects.removeValue(forKey: closed) ?? nil
                sessions.removeAll { $0.id == closed }
                nativeExistsCache.removeValue(forKey: closed)   // settled at close: rescan once
                saveStackChildren()
                reloadPersistedSessions()
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

    // MARK: - Actions (UC-1, SES-06)

    /// UC-1, per the reference: one click launches claude immediately in the
    /// project — no prior input; the goal is then typed in the terminal.
    /// (`prompt` remains possible for the palette or future shortcuts.)
    /// Returns the identifier of the created session.
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
                geometry: preferredGrid,
                samplingInterval: .milliseconds(500),
                hookToken: token)
            spec.projectID = project?.id
            // A single UUID end to end: the `--session-id` one — Resume depends on it.
            spec.sessionID = sessionID
            spec.title = initialPrompt ?? Self.generatedName(project: project)
            // GIT-01 became a per-project CHOICE: worktree isolation only when
            // the project opted in — by default sessions run in the folder.
            if worktreeEnabled(for: project?.id),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                spec.worktree = .create(repo: directory, slug: Self.slug(from: initialPrompt ?? ""))
            }
            let id = try await manager.launch(spec)
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
        try? store?.recordVisit(url: url, title: title, at: Date())
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
        guard let worktree = worktreeURL(for: id), let gh = Self.ghPath else { return nil }
        let process = Process()
        process.executableURL = gh
        process.arguments = ["pr", "create", "--fill"]
        process.currentDirectoryURL = worktree
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return (false, String(describing: error)) }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: finished.terminationStatus == 0
                                    ? (true, out) : (false, err.isEmpty ? out : err))
            }
        }
    }

    /// GUI apps do not inherit the shell PATH: well-known locations only.
    public static let ghPath: URL? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

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
        let diff = (try? await git.diff(in: worktree)) ?? ""
        return GitPanelData(changes: changes, diff: diff)
    }

    public func surface(for id: SessionID) async -> TerminalSurface? {
        await manager?.runtime(for: id)?.surface()
    }
}
