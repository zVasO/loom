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

    init(directory: URL, secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        registry = ExtensionRegistry(directory: directory, secrets: secrets)
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
    func isFrontmost(_ id: String) -> Bool {
        NSApp.isActive && isTabVisible && selectedID == id
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
                try registry.approve(id)
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
            try registry.remove(id)
        } catch {
            lastError = "\(error)"
        }
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
        let theme = self.theme ?? services.currentTheme()
        let host = ExtensionWebHost(
            manifest: installed.manifest, root: installed.root,
            userScript: BridgeScripts.userScript(boot: BridgeBoot(extensionId: id, theme: theme)),
            inspectable: installed.isLinked,
            dispatch: { [weak bridge] text in
                guard let bridge else {
                    return BridgeResponse.failure("", BridgeError(.internalError, "the extension was unloaded")).jsonText
                }
                return await bridge.handle(json: text)
            })
        host.onOpenExternal = { url in NSWorkspace.shared.open(url) }
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

    private func tearDownHost(_ id: String) {
        hosts[id]?.tearDown()
        hosts[id] = nil
        bridges[id] = nil
        hostedFrom[id] = nil
        if pendingLaunch?.extensionID == id {
            pendingLaunch?.resolve(BridgeLaunchResult(launched: false))
            pendingLaunch = nil
        }
    }

    /// A ⌘K command: shows the extension and hands it the command.
    func sendCommand(_ command: String, to id: String) {
        selectedID = id
        host(for: id)?.emit(.command(command))
    }

    // MARK: - What flows to the pages

    func themeDidChange(_ theme: BridgeTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        for (id, host) in hosts {
            host.updateUserScript(BridgeScripts.userScript(boot: BridgeBoot(extensionId: id, theme: theme)))
            host.emit(.themeChanged(theme))
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
        for (id, host) in hosts {
            guard let permissions = bridges[id]?.permissions else { continue }
            for event in events where event.requirement.map(permissions.allows) ?? true {
                host.emit(event)
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

    func finishLaunch(_ result: BridgeLaunchResult) {
        pendingLaunch?.resolve(result)
        pendingLaunch = nil
    }
}
