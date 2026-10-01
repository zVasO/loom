import Foundation
import LoomAPI
import LoomCore
import LoomUI
import LoomWeb

// The session's own browser through the agents API (ADR-0014): one browser
// per claude session, on its project's agent profile (a private one for
// reviews), driven by browser.* methods — the session's own token only.

extension AppModel {

    /// Settings: the browser tools of every session. Off, new sessions do not
    /// list them, and calls are refused at once — whatever is queued included.
    public var agentBrowserToolsEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.agents.browserTools") as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "loom.agents.browserTools")
            if !newValue {
                for browser in agentBrowsers.values {
                    browser.cancelAll("Browser tools were turned off in Loom's Settings.")
                }
            }
        }
    }

    /// Settings: Claude Code runs Loom's own tools without a permission
    /// prompt. Applies to sessions started or resumed afterwards.
    public var preapprovesLoomTools: Bool {
        get { (UserDefaults.standard.object(forKey: "loom.agents.preapproveLoomTools") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loom.agents.preapproveLoomTools") }
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
        guard let browser = agentBrowser(for: id, create: command.createsBrowser) else {
            throw APIError(code: .unavailable, message: "No page is open yet — start with browser_navigate.")
        }
        // Before running: a panel that opens now hosts the page while it loads.
        if command.touchesPage { noteAgentBrowserUse(for: id) }
        guard let budget = method.appDeadline else {
            throw APIError(code: .internalError, message: "\(method.rawValue) has no deadline")
        }
        do {
            let result = try await browser.run(command, deadline: ContinuousClock.now + budget)
            return .ok(request.id, result.apiContent)
        } catch let error as AgentError {
            throw error.apiError
        }
    }

    /// The stack's agent browser; `create` makes it for a running claude
    /// session that has none.
    func agentBrowser(for parent: SessionID, create: Bool) -> AgentBrowser? {
        if let existing = agentBrowsers[parent] { return existing }
        guard create, agentBrowserToolsEnabled,
              let item = sessions.first(where: { $0.id == parent }), !item.isShell else { return nil }
        let isReview = runsUntrustedCode(parent)
        let profile = AgentBrowserProfile.kind(projectID: item.projectID?.rawValue, isReview: isReview)
        let viewport = CGSize(width: storedSidePanelWidth ?? 640, height: 900)
        let browser = AgentBrowser(profile: profile, environment: .init(
            screenshotsDirectory: agentScreenshotsDirectory(for: parent),
            initialViewport: viewport,
            uploadRoots: agentUploadRoots(for: item),
            viewportWidth: agentViewportWidth(for: item.projectID)))
        let projectID = item.projectID
        browser.onViewportChange = { [weak self] width in self?.rememberAgentViewportWidth(width, for: projectID) }
        agentBrowsers[parent] = browser
        return browser
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

    /// The page width a project's agent browser last had (the agent's
    /// browser_resize, the panel's menu) — a layout under test stays put.
    private func agentViewportWidth(for project: ProjectID?) -> ViewportWidth {
        guard let project,
              let data = UserDefaults.standard.data(forKey: "loom.agentBrowser.viewport." + project.rawValue.uuidString),
              let width = try? JSONDecoder().decode(ViewportWidth.self, from: data) else { return .fit }
        return width
    }

    private func rememberAgentViewportWidth(_ width: ViewportWidth, for project: ProjectID?) {
        guard let project else { return }
        let key = "loom.agentBrowser.viewport." + project.rawValue.uuidString
        if width == .fit {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(width) {
            UserDefaults.standard.set(data, forKey: key)
        }
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

    /// Settings: everything the agents' browsers kept, every profile.
    public func clearAgentBrowserData() async {
        for browser in agentBrowsers.values { await browser.clearData() }
        await AgentBrowserProfile.clearAllProjectStores()
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
