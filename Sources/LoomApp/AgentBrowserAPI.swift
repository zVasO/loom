import Foundation
import LoomAPI
import LoomChromium
import LoomCore
import LoomExtensions
import LoomPersistence
import LoomUI
import LoomWeb
import os

// The session's own browser through the agents API (ADR-0014): one browser
// per claude session, on its project's agent profile (a private one for
// reviews), driven by browser.* methods — the session's own token only.

extension AppModel {

    /// Settings: the browser tools of every session. Off, new sessions do not
    /// list them, and calls are refused at once — whatever is queued included;
    /// the agents' Chromium stops rather than idling out its grace.
    public var agentBrowserToolsEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.agents.browserTools") as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "loom.agents.browserTools")
            if !newValue {
                for browser in agentBrowsers.values {
                    browser.cancelAll("Browser tools were turned off in Loom's Settings.")
                }
                stopAgentChromium(reason: "Browser tools were turned off in Loom's Settings")
            }
        }
    }

    /// Settings: Claude Code runs Loom's own tools without a permission
    /// prompt. Applies to sessions started or resumed afterwards.
    public var preapprovesLoomTools: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.agents.preapproveLoomTools") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loom.agents.preapproveLoomTools") }
    }

    /// Settings: the agents' browsers open the machine's own addresses only,
    /// and the hosts listed — every load, enforced by either engine (WebKit's
    /// rules, Chromium's proxy fence). Off by default.
    public var agentBrowsersLocalOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "loom.agents.localOnly") }
        set {
            UserDefaults.standard.set(newValue, forKey: "loom.agents.localOnly")
            applyAgentNetworkAccess()
        }
    }

    /// Settings: the hosts local-only mode lets through besides the machine
    /// (an API the app under test calls), as typed.
    public var agentBrowsersAllowedHosts: String {
        get { UserDefaults.standard.string(forKey: "loom.agents.allowedHosts") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "loom.agents.allowedHosts")
            applyAgentNetworkAccess()
        }
    }

    var agentNetworkAccess: AgentNetworkAccess {
        agentBrowsersLocalOnly
            ? .localOnly(allowedHosts: AgentNetworkRules.parse(agentBrowsersAllowedHosts).hosts)
            : .open
    }

    /// Every live browser follows the setting at once; Chromium's processes
    /// on the old setting stop (applyAgentChromiumNetwork).
    func applyAgentNetworkAccess() {
        let access = agentNetworkAccess
        for browser in agentBrowsers.values { browser.setNetworkAccess(access) }
        applyAgentChromiumNetwork(access)
    }

    func handleBrowserRequest(_ method: APIMethod, _ request: APIRequest,
                              scope: APIScope) async throws -> APIResponse {
        guard agentBrowserToolsEnabled else {
            throw APIError(code: .unavailable, message: "Browser tools are turned off in Loom's Settings.")
        }
        let id = try targetSession(scope, named: request.params["sessionId"]?.stringValue)
        guard let item = sessions.first(where: { $0.id == id }), !item.isShell else {
            throw APIError(code: .unavailable, message: "this session is not running")
        }
        let command = try AgentCommand(method: method, params: request.params)
        let options = try AgentCommandOptions(method: method, params: request.params)
        guard let browser = agentBrowser(for: id, create: command.createsBrowser) else {
            throw APIError(code: .unavailable, message: "No page is open yet — start with browser_navigate.")
        }
        // Before running: a panel that opens now hosts the page while it loads.
        if command.touchesPage { noteAgentBrowserUse(for: id) }
        guard let budget = method.appDeadline else {
            throw APIError(code: .internalError, message: "\(method.rawValue) has no deadline")
        }
        do {
            let result = try await browser.run(command, options: options, deadline: ContinuousClock.now + budget)
            return .ok(request.id, result.apiContent)
        } catch let error as AgentError {
            throw error.apiError
        }
    }

    /// The stack's agent browser; `create` makes it for a running claude
    /// session that has none.
    func agentBrowser(for parent: SessionID, create: Bool) -> (any AgentBrowserEngine)? {
        let engine = agentEngines[parent] ?? .webkit
        if let existing = agentBrowsers[parent] {
            if existing.engine == engine { return existing }
            // Resumed on another engine (Settings changed meanwhile): the
            // old browser goes, its tools are no longer listed.
            agentBrowsers[parent] = nil
            existing.tearDown()
        }
        guard create, agentBrowserToolsEnabled,
              let item = sessions.first(where: { $0.id == parent }), !item.isShell else { return nil }
        let isReview = runsUntrustedCode(parent)
        // A removed project's session browses privately: its profile is
        // being deleted (sweepAgentStores).
        let project = item.projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
        let profile = AgentBrowserProfile.kind(projectID: project?.rawValue, isReview: isReview)
        let viewport = CGSize(width: storedSidePanelWidth ?? 640, height: 900)
        let environment = AgentBrowser.Environment(
            screenshotsDirectory: agentScreenshotsDirectory(for: parent),
            initialViewport: viewport,
            uploadRoots: agentUploadRoots(for: item),
            viewportWidth: agentViewportDefaults.width(for: project?.rawValue),
            networkAccess: agentNetworkAccess)
        let browser: any AgentBrowserEngine
        switch engine {
        case .webkit:
            // WebKit's identifier stores are shared by every Loom instance:
            // the registry says which are this one's (sweepAgentStores).
            if case .project(let identifier) = profile { registerAgentStore(identifier) }
            browser = AgentBrowser(profile: profile, environment: environment)
        case .chromium:
            // Same profile rules, folders under this support directory only.
            browser = ChromiumAgentBrowser(profile: profile, environment: environment, pool: agentChromiumPool)
        }
        agentBrowsers[parent] = browser
        return browser
    }

    // MARK: - Engine (ADR-0016)

    /// Settings ▸ Agents: which engine new sessions' browsers use; nil until
    /// the person chooses (WebKit).
    var agentBrowserEnginePreference: AgentBrowserEnginePreference? {
        get {
            UserDefaults.standard.string(forKey: AgentBrowserEnginePreference.defaultsKey)
                .flatMap(AgentBrowserEnginePreference.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: AgentBrowserEnginePreference.defaultsKey)
        }
    }

    /// What Settings ▸ Agents shows: the engine in force for new sessions,
    /// WebKit until the person chooses. Set to what is already in force, it
    /// stores nothing — an untouched choice keeps following the default.
    var agentBrowserEngineChoice: AgentBrowserEnginePreference {
        get { agentBrowserEnginePreference ?? .webkit }
        set {
            guard newValue != agentBrowserEngineChoice else { return }
            agentBrowserEnginePreference = newValue
        }
    }

    /// Whether a Chromium-family browser can drive agents' pages here.
    var agentChromiumAvailable: Bool { agentChromiumExecutable() != nil }

    /// The engine a session launching or resuming now gets.
    func resolveAgentBrowserEngine() -> APIBrowserEngine {
        AgentBrowserEnginePreference.resolve(preference: agentBrowserEnginePreference,
                                             environment: ProcessInfo.processInfo.environment,
                                             chromiumAvailable: agentChromiumAvailable)
    }

    /// Where browser_file_upload may take files: the session's working tree,
    /// and a folder of Loom's the agent copies other files into on purpose.
    private func agentUploadRoots(for item: SessionItem) -> [URL] {
        var roots: [URL] = []
        let record = allRecords.first { $0.id == item.id }
        if let tree = record?.worktreePath.map({ URL(fileURLWithPath: $0) }) ?? projectRepo(item.projectID) {
            roots.append(tree)
        }
        let uploads = agentUploadsDirectory(for: item.id)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        roots.append(uploads)
        return roots
    }

    func agentUploadsDirectory(for session: SessionID) -> URL {
        supportDirectory.appendingPathComponent("agent-browser/uploads", isDirectory: true)
            .appendingPathComponent(session.rawValue.uuidString, isDirectory: true)
    }

    /// The width a project's agent browsers open at; nil follows the default.
    func setAgentDefaultViewportWidth(_ width: ViewportWidth?, for project: ProjectID) {
        agentViewportDefaults.set(width, for: project.rawValue)
        agentViewportDefaults.save(to: .standard)
    }

    /// The width every project without its own opens at.
    func setAgentGlobalViewportWidth(_ width: ViewportWidth) {
        agentViewportDefaults.global = width
        agentViewportDefaults.save(to: .standard)
    }

    /// What the panel's menu offers about the project's default: nothing for
    /// a session without a project, or a review — it reads the default and
    /// never writes it.
    func agentDefaultWidth(for parent: SessionID) -> AgentBrowserPanelView.DefaultWidth? {
        guard !runsUntrustedCode(parent),
              let projectID = sessions.first(where: { $0.id == parent })?.projectID,
              let project = project(projectID) else { return nil }
        return AgentBrowserPanelView.DefaultWidth(
            projectName: project.name,
            current: agentViewportDefaults.width(for: projectID.rawValue),
            set: { [weak self] width in self?.setAgentDefaultViewportWidth(width, for: projectID) })
    }

    /// What the panel says about where the agent's cookies live.
    func agentBrowserCaption(for parent: SessionID) -> String {
        guard let browser = agentBrowsers[parent] else { return "" }
        switch browser.profile {
        case .project:
            let name = project(sessions.first { $0.id == parent }?.projectID)?.name ?? "this project"
            return "Agent profile · \(name) — claude can use whatever you sign in to here"
        case .private:
            return runsUntrustedCode(parent)
                ? "Private profile — code under review, nothing is kept"
                : "Private profile — nothing is kept"
        }
    }

    /// Settings: everything the agents' browsers kept, every profile, both engines.
    public func clearAgentBrowserData() async {
        for browser in agentBrowsers.values { await browser.clearData() }
        await AgentBrowserProfile.clearAllProjectStores()
        await clearAgentChromiumProfiles()
    }

    // MARK: - Profiles on disk

    /// The stores the agents' browsers of THIS support directory created,
    /// kept beside the database they are checked against: the sweep deletes
    /// only these — never an identifier store of another Loom instance
    /// (LOOM_SUPPORT_DIR shares WebKit's stores and the defaults domain).
    private var agentStoresFile: URL {
        supportDirectory.appendingPathComponent("agent-browser/stores.json")
    }

    private var registeredAgentStores: [UUID] {
        guard let data = try? Data(contentsOf: agentStoresFile),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names.compactMap(UUID.init(uuidString:))
    }

    private func saveAgentStores(_ stores: [UUID]) {
        let file = agentStoresFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(stores.map(\.uuidString)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func registerAgentStore(_ identifier: UUID) {
        var stores = registeredAgentStores
        guard !stores.contains(identifier) else { return }
        stores.append(identifier)
        saveAgentStores(stores)
    }

    private func unregisterAgentStores(_ identifiers: Set<UUID>) {
        saveAgentStores(registeredAgentStores.filter { !identifiers.contains($0) })
    }

    /// At launch, before any agent browser: the profiles of projects removed
    /// since are deleted. Skipped when the projects could not be read — an
    /// empty read is not proof every project is gone.
    func sweepAgentStores() {
        guard let active = activeProjectRecords() else { return }
        let orphans = AgentBrowserProfile.orphanedStores(registered: registeredAgentStores,
                                                         projects: active.map(\.id.rawValue))
        guard !orphans.isEmpty else { return }
        Task { @MainActor in
            var gone: Set<UUID> = []
            for identifier in orphans {
                if await AgentBrowserProfile.removeStore(identifier) { gone.insert(identifier) }
            }
            unregisterAgentStores(gone)
        }
    }

    /// A project removed: its agents' profile goes with it, both engines' —
    /// now, or at the next launch while a running session still browses with
    /// it (emptied meanwhile).
    func forgetAgentProfile(of project: ProjectID) async {
        agentViewportDefaults.forget(project.rawValue)
        agentViewportDefaults.save(to: .standard)
        let identifier = AgentBrowserProfile.storeIdentifier(forProject: project.rawValue)
        if agentBrowsers.values.contains(where: { $0.engine == .webkit && $0.profile == .project(identifier) }) {
            await AgentBrowserProfile.clearStore(identifier)
        } else if await AgentBrowserProfile.removeStore(identifier) {
            unregisterAgentStores([identifier])
        }
        await forgetAgentChromiumProfile(identifier)
    }

    // MARK: - Files

    /// Where the MCP server reads screenshots: beside the socket (APIProtocol).
    var agentScreenshotsRoot: URL {
        APIProtocol.screenshotsDirectory(socketPath: apiSocketURL.path)
    }

    func agentScreenshotsDirectory(for session: SessionID) -> URL {
        agentScreenshotsRoot.appendingPathComponent(session.rawValue.uuidString, isDirectory: true)
    }

    /// An archived session's browser and screenshots are gone for good.
    func forgetAgentBrowser(_ session: SessionID) {
        agentBrowsers.removeValue(forKey: session)?.tearDown()
        agentEngines[session] = nil
        try? FileManager.default.removeItem(at: agentScreenshotsDirectory(for: session))
        try? FileManager.default.removeItem(at: agentUploadsDirectory(for: session))
    }

    /// Screenshots older than a week: the agent has read them long ago.
    func pruneAgentScreenshots() {
        let root = agentScreenshotsRoot
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            let limit = Date().addingTimeInterval(-7 * 24 * 3600)
            guard let sessions = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { return }
            for directory in sessions {
                let files = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if modified < limit { try? manager.removeItem(at: file) }
                }
                if (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                    try? manager.removeItem(at: directory)
                }
            }
        }
    }
}


// MARK: - Chromium (ADR-0016)

// The agents' headless Chromium: one pool for the app, made on first use —
// a Loom that never runs Chromium launches, sweeps and waits for nothing.
// Profiles live under <support>/agent-browser/chromium (ChromiumProfiles),
// named by the same store identifiers as WebKit's. The pool holds the
// local-only fence: it starts it before any local-only launch, and launches
// nothing when it cannot (fail closed).

/// Which binary the agents' Chromium runs, and how the app's settings read to
/// LoomChromium. No actor: the pool asks at each launch, off the main thread.
enum AgentChromiumBinary {

    /// The Settings' choice of a binary: any Chromium-family browser, full
    /// browsers included.
    static let choiceKey = "loom.agents.chromiumPath"

    /// Where the Settings' download puts `chrome-headless-shell` (a later step).
    static func downloadDirectory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("chromium", isDirectory: true)
    }

    /// The Settings' choice as stored, nil for the automatic search.
    static func storedChoice() -> String? {
        guard let path = UserDefaults.standard.string(forKey: choiceKey), !path.isEmpty else { return nil }
        return path
    }

    /// The binary the agents' Chromium runs: the one chosen in Settings,
    /// whatever it is; else a headless shell — Loom's download, then
    /// Playwright's cache. A full browser is never picked on its own: it
    /// updates itself under a running Loom and follows its brand's policies.
    static func locate(supportDirectory: URL, choice: String?,
                       locator: ChromiumLocator = ChromiumLocator()) -> ChromiumExecutable? {
        if let choice, !choice.isEmpty,
           let chosen = locator.candidates(userChoice: URL(fileURLWithPath: choice)).first,
           locator.fileExists(chosen.url.path) {
            return chosen
        }
        let download = downloadDirectory(supportDirectory: supportDirectory)
        return locator.candidates(downloadDirectory: download)
            .first { $0.kind == .headlessShell && locator.fileExists($0.url.path) }
    }

    static func networkMode(_ access: AgentNetworkAccess) -> ChromiumNetworkMode {
        switch access {
        case .open: return .open
        case .localOnly(let hosts): return .localOnly(allowedHosts: hosts.map(\.description))
        }
    }

    static func profileKey(_ profile: AgentBrowserProfile.Kind) -> ChromiumProfileKey {
        switch profile {
        case .project(let identifier): return .project(identifier)
        case .private: return .privateShared
        }
    }

    /// The Settings' words for a binary: what it is, where it was found.
    static func describe(_ executable: ChromiumExecutable) -> String {
        let name: String
        switch executable.kind {
        case .headlessShell: name = "chrome-headless-shell"
        case .fullBrowser(let browser): name = browser + " (headless)"
        }
        switch executable.source {
        case .userChoice: return name + ", your choice"
        case .loomDownload: return name + ", downloaded by Loom"
        case .installed: return name + ", installed"
        case .playwrightCache: return name + ", from Playwright's cache"
        }
    }
}

extension AppModel {

    /// Settings: a binary of the person's choosing (an .app or an
    /// executable), nil for the automatic search.
    var agentChromiumPath: String? {
        get { AgentChromiumBinary.storedChoice() }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: AgentChromiumBinary.choiceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentChromiumBinary.choiceKey)
            }
        }
    }

    func agentChromiumExecutable() -> ChromiumExecutable? {
        AgentChromiumBinary.locate(supportDirectory: supportDirectory, choice: agentChromiumPath)
    }

    /// The profiles' folders. Stateless here: what one app run prepared is
    /// the pool's own instance's to remember.
    var agentChromiumProfiles: ChromiumProfiles {
        ChromiumProfiles(supportDirectory: supportDirectory)
    }

    /// Made on first use, on the network setting in force then; its first
    /// launch waits for the launch-time sweep (a Chromium a dead Loom left on
    /// a profile goes first, never one of this run's).
    var agentChromiumPool: ChromiumPool {
        if let pool = agentChromiumPoolStorage { return pool }
        let support = supportDirectory
        let sweep = agentChromiumSweep
        let logger = Logger(subsystem: "app.loom", category: "agent-browser")
        let pool = ChromiumPool(
            profiles: agentChromiumProfiles,
            network: AgentChromiumBinary.networkMode(agentNetworkAccess),
            executable: {
                AgentChromiumBinary.locate(supportDirectory: support, choice: AgentChromiumBinary.storedChoice())
            },
            launcher: { request in
                if let sweep { await sweep.value }
                return try await ChromiumPool.spawn(request)
            },
            log: { message in logger.info("\(message, privacy: .public)") })
        agentChromiumPoolStorage = pool
        return pool
    }

    /// Chromium takes its network at launch: the processes on the old
    /// setting stop — their pages reload at the next command, as under
    /// WebKit — and the next launch is on the new flags; local-only launches
    /// nothing without its fence. Changes reach the pool in the order they
    /// were made. No pool yet: it is made on the new setting.
    fileprivate func applyAgentChromiumNetwork(_ access: AgentNetworkAccess) {
        guard let pool = agentChromiumPoolStorage else { return }
        let mode = AgentChromiumBinary.networkMode(access)
        let previous = agentChromiumNetworkChange
        agentChromiumNetworkChange = Task {
            if let previous { await previous.value }
            await pool.setNetworkMode(mode)
        }
    }

    /// Browser tools turned off: no Chromium stays up for them. Every
    /// process stops now rather than after the idle grace; each session's
    /// tabs stay to look at, marked released (the pool's stop reaches them
    /// as Chromium stopping), and the next command after the tools come back
    /// launches again.
    fileprivate func stopAgentChromium(reason: String) {
        guard let pool = agentChromiumPoolStorage else { return }
        var keys: Set<ChromiumProfileKey> = [.privateShared]
        for browser in agentBrowsers.values where browser.engine == .chromium {
            keys.insert(AgentChromiumBinary.profileKey(browser.profile))
        }
        for project in projects {
            keys.insert(.project(AgentBrowserProfile.storeIdentifier(forProject: project.id.rawValue)))
        }
        let stopping = keys
        Task {
            await withTaskGroup(of: Void.self) { group in
                for key in stopping {
                    group.addTask { await pool.stop(key, reason: reason) }
                }
            }
        }
    }

    /// Clear agent browser data: every project's Chromium profile emptied —
    /// a running one's process stops first, its pages reload signed out — and
    /// a removed project's goes from disk. No pool in this run: the folders
    /// alone, off the main thread.
    fileprivate func clearAgentChromiumProfiles() async {
        let profiles = agentChromiumProfiles
        let onDisk = profiles.profilesOnDisk()
        guard !onDisk.isEmpty else { return }
        var kept = Set(projects.map { AgentBrowserProfile.storeIdentifier(forProject: $0.id.rawValue) })
        for browser in agentBrowsers.values where browser.engine == .chromium {
            if case .project(let identifier) = browser.profile { kept.insert(identifier) }
        }
        let keep = kept
        if let pool = agentChromiumPoolStorage {
            for identifier in onDisk {
                if keep.contains(identifier) {
                    try? await pool.clearProfile(identifier)
                } else {
                    try? await pool.removeProfile(identifier)
                }
            }
            return
        }
        await Task.detached(priority: .userInitiated) {
            for identifier in onDisk {
                if keep.contains(identifier) {
                    _ = try? profiles.clearProfile(identifier)
                } else {
                    _ = try? profiles.removeProfile(identifier)
                }
            }
        }.value
    }

    /// A removed project's Chromium profile: gone from disk, or only emptied
    /// while a session still browses with it — the launch-time sweep removes
    /// it then, its project being gone.
    fileprivate func forgetAgentChromiumProfile(_ identifier: UUID) async {
        let inUse = agentBrowsers.values.contains { $0.engine == .chromium && $0.profile == .project(identifier) }
        let profiles = agentChromiumProfiles
        guard inUse || profiles.profilesOnDisk().contains(identifier) else { return }
        if let pool = agentChromiumPoolStorage {
            if inUse {
                try? await pool.clearProfile(identifier)
            } else {
                try? await pool.removeProfile(identifier)
            }
            return
        }
        await Task.detached(priority: .utility) {
            _ = try? profiles.removeProfile(identifier)
        }.value
    }

    /// At launch, once the socket is ours (a second instance never gets
    /// here): the quit hook's handle, then the sweep — a Chromium a Loom that
    /// died left running on one of this support directory's profiles is
    /// ended (only a process whose command line names that very folder), and
    /// removed projects' profiles go. Their removal is skipped when the
    /// projects could not be read: an empty read is not proof every project
    /// is gone. The pool's first launch waits for it.
    func prepareAgentChromium() {
        Self.live = self
        let profiles = agentChromiumProfiles
        let active = activeProjectRecords().map { records in
            records.map { AgentBrowserProfile.storeIdentifier(forProject: $0.id.rawValue) }
        }
        // Listed now: the pool's start empties `private/`, and it may exist
        // before the sweep below reaches the folder.
        let projectFolders = profiles.profilesOnDisk().map { profiles.profileDirectory(for: $0) }
        let privateFolders = (try? FileManager.default.contentsOfDirectory(
            at: profiles.privateRoot, includingPropertiesForKeys: nil)) ?? []
        let folders = privateFolders + projectFolders
        guard !folders.isEmpty else { return }
        agentChromiumSweep = Task.detached(priority: .utility) {
            for folder in folders {
                guard let owner = ChromiumProfiles.lockOwner(of: folder),
                      let running = ChromiumProfiles.executablePath(of: owner.pid) else { continue }
                // Its own binary: what is checked is that it runs on this folder.
                _ = await profiles.terminateStaleProcess(holding: folder,
                                                         executable: URL(fileURLWithPath: running))
            }
            if let active {
                profiles.sweepOrphans(registered: [], active: active)
            }
        }
    }

    /// Whether quitting has a Chromium to wait for.
    var runsAgentChromium: Bool { agentChromiumPoolStorage != nil }

    /// App quit (LoomAppDelegate): every agent Chromium gets `Browser.close`
    /// to save its profile, within `budget`; past it Loom quits anyway — a
    /// Chromium still there exits when its pipe closes with Loom.
    func shutDownAgentChromium(budget: Duration) async {
        guard let pool = agentChromiumPoolStorage else { return }
        let first = FirstOfLatch()
        Task.detached {
            await pool.shutdownAll(grace: budget)
            first.finish()
        }
        Task.detached {
            try? await Task.sleep(for: budget)
            first.finish()
        }
        await first.wait()
    }

    // MARK: Settings

    /// The status line under the engine picker.
    struct AgentChromiumStatus: Equatable {
        /// The Chromium found, or that none was.
        var summary: String
        var path: String?
        /// A choice is stored (Settings offers to drop it).
        var hasChoice: Bool
        var warning: String?
        /// A full browser that is installed but used only once chosen.
        var hint: String?
        /// The chrome-headless-shell Loom downloaded, if it is still there.
        var downloaded: ChromiumInstallRecord? = nil
    }

    /// An agent's browser runs on Chromium: its binary must stay.
    var agentChromiumInUse: Bool {
        agentBrowsers.values.contains { $0.engine == .chromium }
    }

    func agentChromiumStatus() -> AgentChromiumStatus {
        let locator = ChromiumLocator()
        let choice = agentChromiumPath
        let found = AgentChromiumBinary.locate(supportDirectory: supportDirectory, choice: choice, locator: locator)
        var status = AgentChromiumStatus(summary: "", path: found?.url.path, hasChoice: choice != nil,
                                         warning: nil, hint: nil,
                                         downloaded: chromiumSetup.installed(supportDirectory: supportDirectory))
        if let found {
            let used = resolveAgentBrowserEngine() == .chromium
                ? "new sessions use it"
                : "not used: WebKit is chosen"
            status.summary = "Chromium: \(AgentChromiumBinary.describe(found)) — \(used)"
        } else {
            status.summary = "No Chromium found — WebKit is used"
        }
        if let choice, found?.source != .userChoice {
            status.warning = "\(choice) is not there or cannot run: the automatic search is used."
        } else if let found, case .fullBrowser(let name) = found.kind,
                  name.localizedCaseInsensitiveContains("brave") {
            status.warning = "Brave's shields change what pages load: the agent may test a web your users do not see."
        }
        if found == nil,
           let installed = locator.candidates().first(where: {
               $0.source == .installed && locator.fileExists($0.url.path)
           }),
           case .fullBrowser(let name) = installed.kind {
            status.hint = "\(name) is installed: Choose… to use it (headless, no window)."
        }
        return status
    }

    // MARK: Self-test

    /// LOOM_AUTOTEST=agent-browser (ContentView): the self-test on the engine
    /// LOOM_AUTOTEST_ENGINE names, WebKit when unsaid. Chromium is the binary
    /// LOOM_CHROMIUM points at, else the one Loom would use, else any it
    /// finds — a full browser included (CI runners have Chrome installed).
    /// The test runs on a pool of its own over temporary folders: never one
    /// of the app's profiles.
    func runAgentBrowserSelfTest(fixturesDirectory: URL, reportPath: String) async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["LOOM_AUTOTEST_ENGINE"]
            .flatMap { APIBrowserEngine(rawValue: $0.lowercased()) } ?? .webkit
        var chromium: ChromiumExecutable? = nil
        if engine == .chromium {
            let locator = ChromiumLocator()
            if let path = environment["LOOM_CHROMIUM"], !path.isEmpty {
                chromium = locator.candidates(userChoice: URL(fileURLWithPath: path)).first
            } else {
                chromium = agentChromiumExecutable()
                    ?? locator.locate(downloadDirectory: AgentChromiumBinary.downloadDirectory(
                        supportDirectory: supportDirectory))
            }
        }
        return await AgentBrowserSelfTest.run(fixturesDirectory: fixturesDirectory, reportPath: reportPath,
                                              engine: engine, chromium: chromium)
    }
}

/// Resumed once, by whichever of its finishers comes first; a wait after
/// that returns at once.
private final class FirstOfLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiter: CheckedContinuation<Void, Never>?

    func finish() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !done else { return nil }
            done = true
            let current = waiter
            waiter = nil
            return current
        }
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if done { return true }
                waiter = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }
}
