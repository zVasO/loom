import AppKit
import Foundation
import LoomAPI
import LoomCore
import LoomExtensions
import LoomPersistence
import LoomUI

// The app's side of the extensions bridge (ADR-0011): what an extension may
// see of Loom, and how its one consequential ask — a launch — reaches the
// user. Same calls as the UI, same projection of a session as the agents API
// (ADR-0010): a session looks the same to an agent and to an extension.

extension AppModel: ExtensionAppServices {

    public var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public func currentTheme() -> BridgeTheme {
        bridgeTheme()
    }

    func bridgeTheme() -> BridgeTheme {
        let palette = ThemeStore.shared.palette
        var tokens: [String: String] = [:]
        if case .object(let object)? = try? JSONValue.from(palette.tokens) {
            for (name, value) in object {
                if let hex = value.stringValue { tokens[name] = hex }
            }
        }
        return BridgeTheme(isLight: palette.isLight, tokens: tokens)
    }

    public func bridgeProjects() -> [BridgeProject] {
        projects.map { BridgeProject(id: $0.id.rawValue.uuidString, name: $0.name) }
    }

    public func bridgeSessions(includeArchived: Bool) -> [APISession] {
        allRecords
            .filter { includeArchived || $0.state != .archived }
            .map { apiSession(record: $0) }
    }

    public func bridgeSession(id: String) -> APISession? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try? apiSession(SessionID(uuid))
    }

    public func isFrontmost(extensionID: String) -> Bool {
        extensions.isFrontmost(extensionID)
    }

    /// Opens the confirmation sheet; the user's answer comes back through
    /// `ExtensionLaunchSheet`. Nothing starts without their click (ADR-0010:
    /// a launch is never a bare token's to make).
    public func requestLaunch(_ params: BridgeLaunchParams,
                              from manifest: ExtensionManifest) async throws -> BridgeLaunchResult {
        try await extensions.beginLaunch(params, from: manifest)
    }

    /// Live sessions only: waking a dormant one starts a process, and that is
    /// a launch.
    public func openSession(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id),
              sessions.contains(where: { $0.id == SessionID(uuid) && !$0.isDormant })
        else { return false }
        extensions.openSessionRequest = .init(sessionID: id)
        return true
    }

    public func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // ADR-0012: alarms, the top-bar status and the overlay live in the
    // extensions model; the app only lends its window.

    public func scheduleAlarm(_ name: String, at date: Date, for extensionID: String) throws {
        try extensions.scheduleAlarm(name, at: date, for: extensionID)
    }

    public func clearAlarm(_ name: String, for extensionID: String) {
        extensions.clearAlarm(name, for: extensionID)
    }

    public func alarms(for extensionID: String) -> [BridgeAlarm] {
        extensions.alarmList(for: extensionID)
    }

    public func setStatus(_ status: BridgeStatusParams?, for manifest: ExtensionManifest) {
        extensions.setStatus(status, for: manifest)
    }

    public func presentOverlay(page: String, until: Date, dismissLabel: String,
                               for manifest: ExtensionManifest) throws {
        try extensions.presentOverlay(page: page, until: until, dismissLabel: dismissLabel, for: manifest)
    }

    public func dismissOverlay(for extensionID: String) {
        extensions.dismissOverlay(for: extensionID)
    }

    /// Hands the extensions the sessions as they now are — skipped when no
    /// open extension may read them.
    func publishSessionSnapshot() {
        guard extensions.needsSessionSnapshots else { return }
        extensions.sessionsDidChange(bridgeSessions(includeArchived: false))
    }

    /// The launch the user confirmed, with what they kept of the proposal.
    /// Badges need no definition: like `PR #42`, an undefined one wears the
    /// neutral colour — a ticket key does not belong in the catalog.
    func launchFromExtension(prompt: String, projectID: ProjectID?, placement: LaunchPlacement,
                             title: String?, badges: [String]) async -> SessionID? {
        await launchSession(prompt: prompt, in: projectID, placement: placement,
                            title: title, badges: badges)
    }
}
