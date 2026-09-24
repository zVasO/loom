import AppKit
import Foundation
import LoomAPI
import LoomExtensions
import LoomWeb
import Observation

/// A launch an extension asked for, waiting on the user's answer in the
/// confirmation sheet. Resolves once — the sheet's buttons and its dismissal
/// all end up here.
@MainActor
final class PendingExtensionLaunch: Identifiable {
    nonisolated let id = UUID()
    let extensionID: String
    let extensionName: String
    let params: BridgeLaunchParams
    private var continuation: CheckedContinuation<BridgeLaunchResult, Never>?

    init(extensionID: String, extensionName: String, params: BridgeLaunchParams,
         continuation: CheckedContinuation<BridgeLaunchResult, Never>) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.params = params
        self.continuation = continuation
    }

    func resolve(_ result: BridgeLaunchResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// A consent the user is asked for: to install a folder, to link one, or to
/// approve what an updated manifest now asks.
struct ExtensionConsentRequest: Identifiable {
    enum Kind {
        case install(URL)
        case link(URL)
        case update(String)
    }

    let id = UUID()
    let kind: Kind
    let manifest: ExtensionManifest
    /// What the sheet lists: everything for a new extension, the difference
    /// for an update.
    let permissions: ExtensionPermissions
}

/// A short status an extension shows in Loom's top bar (ADR-0012).
struct ExtensionStatusItem: Identifiable, Equatable {
    var id: String { extensionID }
    let extensionID: String
    let icon: String
    var text: String
    /// Loom ticks the countdown itself; the page need not run every second.
    var countdownTo: Date?
    var tooltip: String?
}

/// One extension page over the whole window (ADR-0012). Loom owns the frame
/// and the dismiss button; the extension only fills the page.
@MainActor
final class ExtensionOverlay: Identifiable {
    nonisolated let id = UUID()
    let extensionID: String
    let extensionName: String
    let page: String
    let until: Date
    let dismissLabel: String
    let host: ExtensionWebHost

    init(extensionID: String, extensionName: String, page: String, until: Date,
         dismissLabel: String, host: ExtensionWebHost) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.page = page
        self.until = until
        self.dismissLabel = dismissLabel
        self.host = host
    }
}

/// The extensions side of the app (ADR-0011): the registry, the one web host
/// per extension opened, the bridge behind each, and what flows to the pages —
/// the theme, the sessions, commands. Hosts are created the first time their
/// view shows and kept until the extension is disabled, updated or removed.
@MainActor
@Observable
final class ExtensionsModel {
    private(set) var extensions: [InstalledExtension] = []
    private(set) var problems: [ExtensionProblem] = []
    private(set) var hosts: [String: ExtensionWebHost] = [:]
    /// The extension shown in the Extensions tab.
    var selectedID: String?
    /// Kept in step with the main tab by ContentView.
    var isTabVisible = false
    var pendingLaunch: PendingExtensionLaunch?
    var consentRequest: ExtensionConsentRequest?
    /// A live session an extension asked to bring on screen.
    var openSessionRequest: SessionOpenRequest?
    var lastError: String?
    /// ADR-0012: statuses in the top bar, and the one overlay on screen.
    private(set) var statusItems: [ExtensionStatusItem] = []
    private(set) var overlay: ExtensionOverlay?

    struct SessionOpenRequest: Equatable {
        let id = UUID()
        let sessionID: String
    }

    @ObservationIgnored private let registry: ExtensionRegistry
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let http = ExtensionHTTPClient()
    @ObservationIgnored private var bridges: [String: ExtensionBridge] = [:]
    /// What each host was built from — a change means rebuilding it.
    @ObservationIgnored private var hostedFrom: [String: InstalledExtension] = [:]
    @ObservationIgnored private weak var services: ExtensionAppServices?
    @ObservationIgnored private var detector = SessionChangeDetector()
    @ObservationIgnored private var theme: BridgeTheme?
    @ObservationIgnored private let alarms: ExtensionAlarmScheduler
    @ObservationIgnored private var overlayTimeout: Task<Void, Never>?

    init(directory: URL, secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        registry = ExtensionRegistry(directory: directory, secrets: secrets)
        alarms = ExtensionAlarmScheduler()
        alarms.onFire = { [weak self] extensionID, name, date in
            self?.emit(.alarm(name, scheduledTime: date), to: extensionID)
        }
    }

    func start(services: ExtensionAppServices) {
        self.services = services
        theme = services.currentTheme()
        reloadRegistry()
    }

    func extensionNamed(_ id: String) -> InstalledExtension? {
        extensions.first { $0.id == id }
    }

    var readyExtensions: [InstalledExtension] { extensions.filter(\.isReady) }

    /// The extension the user is looking at — in the Extensions tab, with
    /// Loom in front. The only one that may ask for a launch.
    /// With another sheet up (⌘K, usage) a launch sheet could not show, and
    /// the page's promise would hang: not frontmost then.
    func isFrontmost(_ id: String) -> Bool {
        NSApp.isActive && isTabVisible && selectedID == id
            && NSApp.mainWindow?.attachedSheet == nil
    }

    // MARK: - Registry

    /// Rescans the disk; hosts whose extension changed (manifest, grant,
    /// state) are torn down and rebuilt on their next showing.
    func reloadRegistry() {
        registry.scan()
        extensions = registry.extensions
        problems = registry.problems
        for (id, built) in hostedFrom where extensionNamed(id) != built {
            tearDownHost(id)
        }
        if let selectedID, extensionNamed(selectedID) == nil { self.selectedID = nil }
        if selectedID == nil { selectedID = readyExtensions.first?.id ?? extensions.first?.id }
        startBackgroundExtensions()
    }

    /// ADR-0012: an extension granted `background` runs from Loom's launch —
    /// the same page its tab shows, loaded before anyone opens it.
    private func startBackgroundExtensions() {
        guard services != nil else { return }
        for installed in readyExtensions where installed.effectivePermissions.background {
            host(for: installed.id)
        }
    }

    func inspect(_ folder: URL) throws -> ExtensionManifest {
        try registry.inspect(folder)
    }

    /// Asks for consent to install (or link) a folder.
    func requestInstall(from folder: URL, linking: Bool) {
        do {
            let manifest = try registry.inspect(folder)
            consentRequest = ExtensionConsentRequest(kind: linking ? .link(folder) : .install(folder),
                                                     manifest: manifest, permissions: manifest.permissions)
        } catch {
            lastError = "\(error)"
        }
    }

    /// Asks for consent to what an extension's manifest now asks beyond its grant.
    func requestApproval(of id: String) {
        guard let installed = extensionNamed(id) else { return }
        consentRequest = ExtensionConsentRequest(
            kind: .update(id), manifest: installed.manifest,
            permissions: installed.manifest.permissions.missing(from: installed.granted))
    }

    func confirm(_ request: ExtensionConsentRequest) {
        consentRequest = nil
        do {
            switch request.kind {
            case .install(let folder):
                let installed = try registry.install(from: folder, granting: request.manifest.permissions)
                selectedID = installed.id
            case .link(let folder):
                let linked = try registry.link(folder, granting: request.manifest.permissions)
                selectedID = linked.id
            case .update(let id):
                try registry.approve(id, adding: request.permissions)
            }
        } catch {
            lastError = "\(error)"
        }
        reloadRegistry()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        do {
            try registry.setEnabled(enabled, for: id)
        } catch {
            lastError = "\(error)"
        }
        reloadRegistry()
    }

    func remove(_ id: String) {
        tearDownHost(id)
        do {
            try registry.remove(id, purgingSecrets: false)
        } catch {
            lastError = "\(error)"
        }
        // The Keychain can block on a prompt: never on the main actor.
        let secrets = self.secrets
        Task.detached { try? secrets.deleteAll(for: id) }
        reloadRegistry()
    }

    func revealInFinder(_ id: String) {
        guard let installed = extensionNamed(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installed.root])
    }

    /// Rereads the manifest and reloads the page — the development loop of a
    /// linked extension.
    func reload(_ id: String) {
        reloadRegistry()
        if let host = hosts[id] {
            host.reload()
        } else {
            _ = host(for: id)
        }
    }

    // MARK: - Hosts

    /// The extension's web host, created and loaded on first request —
    /// nil while it is not ready to run (disabled, awaiting consent).
    @discardableResult
    func host(for id: String) -> ExtensionWebHost? {
        if let existing = hosts[id] { return existing }
        guard let installed = extensionNamed(id), installed.isReady, let services else { return nil }
        let bridge = ExtensionBridge(
            manifest: installed.manifest, permissions: installed.effectivePermissions,
            services: services,
            storage: ExtensionStorage(file: registry.storageFile(for: id)),
            secrets: secrets, http: http)
        let host = makeHost(installed, bridge: bridge, page: nil)
        // The first listener: the detector's baseline is now, or the first
        // change would only set it.
        if !needsSessionSnapshots, installed.effectivePermissions.allows(.sessions(.read)) {
            detector = SessionChangeDetector()
            _ = detector.update(services.bridgeSessions(includeArchived: false))
        }
        bridges[id] = bridge
        hosts[id] = host
        hostedFrom[id] = installed
        host.load()
        return host
    }

    /// A web view for one of the extension's pages, answered by its bridge.
    private func makeHost(_ installed: InstalledExtension, bridge: ExtensionBridge,
                          page: String?) -> ExtensionWebHost {
        let theme = self.theme ?? services?.currentTheme() ?? BridgeTheme(isLight: false, tokens: [:])
        let host = ExtensionWebHost(
            manifest: installed.manifest, root: installed.root,
            userScript: BridgeScripts.userScript(boot: BridgeBoot(extensionId: installed.id, theme: theme)),
            inspectable: installed.isLinked,
            page: page,
            dispatch: { [weak bridge] text in
                guard let bridge else {
                    return BridgeResponse.failure("", BridgeError(.internalError, "the extension was unloaded")).jsonText
                }
                return await bridge.handle(json: text)
            })
        host.onOpenExternal = { url in NSWorkspace.shared.open(url) }
        return host
    }

    private func tearDownHost(_ id: String) {
        hosts[id]?.tearDown()
        hosts[id] = nil
        bridges[id] = nil
        hostedFrom[id] = nil
        alarms.clearAll(for: id)
        statusItems.removeAll { $0.extensionID == id }
        if overlay?.extensionID == id { closeOverlay(reason: nil) }
        if let pending = pendingLaunch, pending.extensionID == id {
            finishLaunch(BridgeLaunchResult(launched: false), for: pending)
        }
    }

    /// Every page of the extension hears it: its view (or background page)
    /// and its overlay, when one is up.
    private func emit(_ event: BridgeEvent, to id: String) {
        hosts[id]?.emit(event)
        if let overlay, overlay.extensionID == id { overlay.host.emit(event) }
    }

    // MARK: - Alarms, status, overlay (ADR-0012)

    func scheduleAlarm(_ name: String, at date: Date, for id: String) throws {
        try alarms.schedule(name, at: date, for: id)
    }

    func clearAlarm(_ name: String, for id: String) {
        alarms.clear(name, for: id)
    }

    func alarmList(for id: String) -> [BridgeAlarm] {
        alarms.alarms(for: id)
    }

    func setStatus(_ status: BridgeStatusParams?, for manifest: ExtensionManifest) {
        guard let status else {
            statusItems.removeAll { $0.extensionID == manifest.id }
            return
        }
        let item = ExtensionStatusItem(
            extensionID: manifest.id, icon: manifest.icon ?? "puzzlepiece.extension",
            text: status.text ?? "",
            countdownTo: status.countdownTo.map { Date(timeIntervalSince1970: $0 / 1000) },
            tooltip: status.tooltip ?? manifest.name)
        if let index = statusItems.firstIndex(where: { $0.extensionID == manifest.id }) {
            statusItems[index] = item
        } else {
            statusItems.append(item)
        }
    }

    /// One overlay at a time, app-wide: another extension's gets `conflict`;
    /// the same extension's replaces it.
    func presentOverlay(page: String, until: Date, dismissLabel: String,
                        for manifest: ExtensionManifest) throws {
        if let overlay, overlay.extensionID != manifest.id {
            throw BridgeError(.conflict, "\(overlay.extensionName) is already showing a page over Loom")
        }
        guard let installed = extensionNamed(manifest.id), let bridge = bridges[manifest.id] else {
            throw BridgeError(.internalError, "the extension is not running")
        }
        if overlay != nil { closeOverlay(reason: .replaced) }
        let host = makeHost(installed, bridge: bridge, page: page)
        overlay = ExtensionOverlay(extensionID: manifest.id, extensionName: manifest.name, page: page,
                                   until: until, dismissLabel: dismissLabel, host: host)
        host.load()
        overlayTimeout = Task { [weak self] in
            let delay = max(0, until.timeIntervalSinceNow)
            try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.closeOverlay(reason: .timeout)
        }
        // Loom in the background: the break still starts — say so.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func dismissOverlay(for id: String) {
        guard overlay?.extensionID == id else { return }
        closeOverlay(reason: .extension)
    }

    /// The native button, or Escape.
    func dismissOverlayByUser() {
        closeOverlay(reason: .user)
    }

    /// `reason` nil: the extension itself is going away — nobody to tell.
    private func closeOverlay(reason: BridgeEvent.OverlayDismissal?) {
        guard let current = overlay else { return }
        overlayTimeout?.cancel()
        overlayTimeout = nil
        current.host.tearDown()
        overlay = nil
        if let reason { hosts[current.extensionID]?.emit(.overlayDismissed(reason, page: current.page)) }
    }

    /// A ⌘K command: shows the extension and hands it the command.
    func sendCommand(_ command: String, to id: String) {
        selectedID = id
        host(for: id)
        emit(.command(command), to: id)
    }

    // MARK: - What flows to the pages

    func themeDidChange(_ theme: BridgeTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        for (id, host) in hosts {
            host.updateUserScript(BridgeScripts.userScript(boot: BridgeBoot(extensionId: id, theme: theme)))
            emit(.themeChanged(theme), to: id)
        }
    }

    /// Whether anyone listens to the sessions — the snapshot is not even
    /// built when no open extension may read them.
    var needsSessionSnapshots: Bool {
        bridges.values.contains { $0.permissions.allows(.sessions(.read)) }
    }

    func sessionsDidChange(_ snapshot: [APISession]) {
        guard needsSessionSnapshots else {
            detector = SessionChangeDetector()
            return
        }
        let events = detector.update(snapshot)
        guard !events.isEmpty else { return }
        for id in hosts.keys {
            guard let permissions = bridges[id]?.permissions else { continue }
            for event in events where event.requirement.map(permissions.allows) ?? true {
                emit(event, to: id)
            }
        }
    }

    // MARK: - Launches

    func beginLaunch(_ params: BridgeLaunchParams, from manifest: ExtensionManifest) async throws -> BridgeLaunchResult {
        guard pendingLaunch == nil else {
            throw BridgeError(.conflict, "another launch is already waiting for the user")
        }
        return await withCheckedContinuation { continuation in
            pendingLaunch = PendingExtensionLaunch(extensionID: manifest.id, extensionName: manifest.name,
                                                   params: params, continuation: continuation)
        }
    }

    /// Answers `request` — and clears the pending slot only if it still holds
    /// that request, never a newer one.
    func finishLaunch(_ result: BridgeLaunchResult, for request: PendingExtensionLaunch) {
        request.resolve(result)
        if pendingLaunch === request { pendingLaunch = nil }
    }
}
