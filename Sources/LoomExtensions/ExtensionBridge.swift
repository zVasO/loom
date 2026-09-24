import Foundation
import LoomAPI

/// What the app lends the bridge: the parts of Loom an extension may see or
/// ask for. `AppModel` implements it; the tests fake it.
@MainActor
public protocol ExtensionAppServices: AnyObject {
    var appVersion: String { get }
    func currentTheme() -> BridgeTheme
    func bridgeProjects() -> [BridgeProject]
    func bridgeSessions(includeArchived: Bool) -> [APISession]
    func bridgeSession(id: String) -> APISession?
    /// Whether the extension's view is the one on screen — a launch is only
    /// ever asked for by what the user is looking at.
    func isFrontmost(extensionID: String) -> Bool
    /// Shows the confirmation sheet and waits for the user's answer. Throws
    /// `conflict` while another launch is waiting.
    func requestLaunch(_ params: BridgeLaunchParams, from manifest: ExtensionManifest) async throws -> BridgeLaunchResult
    /// Brings a live session on screen; false when there is none by that id.
    func openSession(id: String) -> Bool
    func openExternal(_ url: URL)

    // ADR-0012 — what reaches past the extension's own view.
    func scheduleAlarm(_ name: String, at date: Date, for extensionID: String) throws
    func clearAlarm(_ name: String, for extensionID: String)
    func alarms(for extensionID: String) -> [BridgeAlarm]
    /// nil clears the extension's status.
    func setStatus(_ status: BridgeStatusParams?, for manifest: ExtensionManifest)
    /// Shows `page` over the whole window until `until`, the user's dismiss, or
    /// the extension's; `conflict` while another extension's overlay is up.
    func presentOverlay(page: String, until: Date, dismissLabel: String,
                        for manifest: ExtensionManifest) throws
    func dismissOverlay(for extensionID: String)
}

/// The native side of `window.loom` for one extension: decodes a request,
/// checks the permission its method needs against what the user granted,
/// answers. Every guard of the bridge lives here — the SDK is a convenience.
@MainActor
public final class ExtensionBridge {
    public let manifest: ExtensionManifest
    /// What the extension runs with: the manifest's asks the user granted.
    public let permissions: ExtensionPermissions
    private weak var services: ExtensionAppServices?
    private let storage: ExtensionStorage
    private let secrets: any SecretStore
    private let http: ExtensionHTTPClient

    public init(manifest: ExtensionManifest, permissions: ExtensionPermissions,
                services: ExtensionAppServices, storage: ExtensionStorage,
                secrets: any SecretStore, http: ExtensionHTTPClient) {
        self.manifest = manifest
        self.permissions = permissions
        self.services = services
        self.storage = storage
        self.secrets = secrets
        self.http = http
    }

    /// JSON text in, JSON text out — what the message handler passes through.
    public func handle(json: String) async -> String {
        let data = Data(json.utf8)
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let id = object?["id"] as? String ?? ""
            return BridgeResponse.failure(id, BridgeError(.invalidRequest,
                "a request is {id, method, params} as JSON text")).jsonText
        }
        return await handle(request).jsonText
    }

    public func handle(_ request: BridgeRequest) async -> BridgeResponse {
        guard let method = BridgeMethod(rawValue: request.method) else {
            return .failure(request.id, BridgeError(.unknownMethod, "unknown method \(request.method)"))
        }
        if let requirement = method.requirement, !permissions.allows(requirement) {
            return .failure(request.id, BridgeError(.forbidden,
                "\(method.rawValue) needs the permission \"\(requirement)\" in loom-extension.json"))
        }
        guard let services else {
            return .failure(request.id, BridgeError(.internalError, "Loom is shutting down"))
        }
        do {
            return try await answer(method, request, services)
        } catch let error as BridgeError {
            return .failure(request.id, error)
        } catch let error as KeychainError {
            return .failure(request.id, BridgeError(.internalError, error.description))
        } catch {
            return .failure(request.id, BridgeError(.internalError, "\(error)"))
        }
    }

    private func answer(_ method: BridgeMethod, _ request: BridgeRequest,
                        _ services: ExtensionAppServices) async throws -> BridgeResponse {
        let id = manifest.id
        switch method {
        case .info:
            return .ok(request.id, BridgeInfo(loomApi: ExtensionManifest.supportedAPIVersion,
                                              appVersion: services.appVersion,
                                              extensionId: id, theme: services.currentTheme()))

        case .projectsList:
            return .ok(request.id, BridgeProjectsList(projects: services.bridgeProjects()))

        case .sessionsList:
            let params = try request.decodeParams(BridgeSessionsListParams.self)
            return .ok(request.id, BridgeSessionsList(
                sessions: services.bridgeSessions(includeArchived: params.includeArchived == true)))

        case .sessionsGet:
            let params = try request.decodeParams(BridgeSessionRef.self)
            guard let session = services.bridgeSession(id: params.sessionId) else {
                throw BridgeError(.notFound, "no session \(params.sessionId)")
            }
            return .ok(request.id, session)

        case .sessionsOpen:
            let params = try request.decodeParams(BridgeSessionRef.self)
            guard services.openSession(id: params.sessionId) else {
                throw BridgeError(.notFound, "no live session \(params.sessionId)")
            }
            return .ok(request.id, BridgeOK())

        case .sessionsLaunch:
            let params = try request.decodeParams(BridgeLaunchParams.self)
            try params.validate()
            guard services.isFrontmost(extensionID: id) else {
                throw BridgeError(.forbidden, "sessions.launch is only accepted while the extension is on screen")
            }
            return .ok(request.id, try await services.requestLaunch(params, from: manifest))

        case .httpFetch:
            let params = try request.decodeParams(BridgeHTTPRequest.self)
            return .ok(request.id, try await http.perform(params, allowed: permissions.hostPatterns))

        case .secretsGet:
            let params = try request.decodeParams(BridgeKeyParams.self)
            try SecretPolicy.validate(key: params.key)
            let secrets = self.secrets
            let value = try await Task.detached { try secrets.secret(params.key, for: id) }.value
            return BridgeResponse(id: request.id, result: .object(["value": value.map(JSONValue.string) ?? .null]))

        case .secretsSet:
            let params = try request.decodeParams(BridgeSecretSetParams.self)
            try SecretPolicy.validate(key: params.key)
            try SecretPolicy.validate(value: params.value)
            let secrets = self.secrets
            try await Task.detached { try secrets.setSecret(params.value, params.key, for: id) }.value
            return .ok(request.id, BridgeOK())

        case .secretsDelete:
            let params = try request.decodeParams(BridgeKeyParams.self)
            try SecretPolicy.validate(key: params.key)
            let secrets = self.secrets
            try await Task.detached { try secrets.deleteSecret(params.key, for: id) }.value
            return .ok(request.id, BridgeOK())

        case .storageGet:
            let params = try request.decodeParams(BridgeKeyParams.self)
            let value = try storage.value(for: params.key)
            return BridgeResponse(id: request.id, result: .object(["value": value ?? .null]))

        case .storageSet:
            let params = try request.decodeParams(BridgeStorageSetParams.self)
            try storage.set(params.value, for: params.key)
            return .ok(request.id, BridgeOK())

        case .storageDelete:
            let params = try request.decodeParams(BridgeKeyParams.self)
            try storage.set(nil, for: params.key)
            return .ok(request.id, BridgeOK())

        case .openExternal:
            let params = try request.decodeParams(BridgeURLParams.self)
            guard let url = URL(string: params.url), url.scheme?.lowercased() == "https", url.host != nil else {
                throw BridgeError(.invalidParams, "ui.openExternal opens https URLs only")
            }
            guard services.isFrontmost(extensionID: id) else {
                throw BridgeError(.forbidden, "ui.openExternal is only accepted while the extension is on screen")
            }
            services.openExternal(url)
            return .ok(request.id, BridgeOK())

        case .alarmsCreate:
            let params = try request.decodeParams(BridgeAlarmParams.self)
            let date = try params.fireDate(now: Date())
            try services.scheduleAlarm(params.name, at: date, for: id)
            return .ok(request.id, BridgeAlarm(name: params.name,
                                               scheduledTime: (date.timeIntervalSince1970 * 1000).rounded()))

        case .alarmsClear:
            let params = try request.decodeParams(BridgeNameParams.self)
            services.clearAlarm(params.name, for: id)
            return .ok(request.id, BridgeOK())

        case .alarmsList:
            return .ok(request.id, BridgeAlarmList(alarms: services.alarms(for: id)))

        case .uiSetStatus:
            let params = try request.decodeParams(BridgeStatusParams.self)
            try params.validate()
            services.setStatus(params.isClear ? nil : params, for: manifest)
            return .ok(request.id, BridgeOK())

        case .uiPresentOverlay:
            let params = try request.decodeParams(BridgeOverlayParams.self)
            let checked = try params.validated(now: Date())
            try services.presentOverlay(page: checked.page, until: checked.until,
                                        dismissLabel: checked.dismissLabel, for: manifest)
            return .ok(request.id, BridgeOK())

        case .uiDismissOverlay:
            services.dismissOverlay(for: id)
            return .ok(request.id, BridgeOK())
        }
    }
}
