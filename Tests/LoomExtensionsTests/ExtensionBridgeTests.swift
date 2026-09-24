import Testing
import LoomExtensions
import LoomAPI
import Foundation

// Seam: ExtensionAppServices — the bridge's router against a fake app. What
// is tested is every guard of the bridge: permissions, the frontmost rule for
// launches, the shapes of the answers. The WebKit transport is not.

@MainActor
final class FakeServices: ExtensionAppServices {
    var appVersion = "9.9"
    var frontmost: String?
    var launches: [BridgeLaunchParams] = []
    var launchAnswer = BridgeLaunchResult(launched: true, sessionId: "11111111-1111-1111-1111-111111111111")
    var opened: [String] = []
    var external: [URL] = []
    var sessions = [APISession(id: "s1", title: "Fix PROJ-1", state: "working", badges: ["PROJ-1"],
                               createdAt: "2026-09-24T00:00:00Z")]

    func currentTheme() -> BridgeTheme { BridgeTheme(isLight: true, tokens: ["accent": "#3366FF"]) }
    func bridgeProjects() -> [BridgeProject] { [BridgeProject(id: "p1", name: "loom")] }
    func bridgeSessions(includeArchived: Bool) -> [APISession] { sessions }
    func bridgeSession(id: String) -> APISession? { sessions.first { $0.id == id } }
    func isFrontmost(extensionID: String) -> Bool { frontmost == extensionID }
    func requestLaunch(_ params: BridgeLaunchParams, from manifest: ExtensionManifest) async throws -> BridgeLaunchResult {
        launches.append(params)
        return launchAnswer
    }
    func openSession(id: String) -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        opened.append(id)
        return true
    }
    func openExternal(_ url: URL) { external.append(url) }
}

@MainActor
@Suite("Extensions — bridge router")
struct ExtensionBridgeTests {

    static let id = "dev.example.jira"

    private func makeBridge(_ services: FakeServices,
                        permissions: ExtensionPermissions = ExtensionPermissions(
                            network: ["*.atlassian.net"], sessions: [.read, .launch], projects: [.read]),
                        secrets: InMemorySecretStore = InMemorySecretStore()) -> ExtensionBridge {
        let manifest = ExtensionManifest(id: Self.id, name: "Jira", version: "1", permissions: permissions)
        let storage = ExtensionStorage(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-bridge-\(UUID().uuidString)/storage.json"))
        return ExtensionBridge(manifest: manifest, permissions: permissions, services: services,
                               storage: storage, secrets: secrets, http: ExtensionHTTPClient())
    }

    private func call(_ bridge: ExtensionBridge, _ method: String,
                      _ params: JSONValue = .object([:])) async -> BridgeResponse {
        await bridge.handle(BridgeRequest(id: "r", method: method, params: params))
    }

    @Test("text that is not a request gets invalidRequest, with its id when it had one")
    func requeteMalformee() async throws {
        let services = FakeServices()
        let bridge = makeBridge(services)
        let text = await bridge.handle(json: #"{"id":"42","method":7}"#)
        let response = try JSONDecoder().decode(BridgeResponse.self, from: Data(text.utf8))
        #expect(response.id == "42")
        #expect(response.error?.code == .invalidRequest)
        let garbage = await bridge.handle(json: "nope")
        #expect(garbage.contains("invalidRequest"))
    }

    @Test("an unknown method is named in the error")
    func methodeInconnue() async {
        let response = await call(makeBridge(FakeServices()), "sessions.delete")
        #expect(response.error?.code == .unknownMethod)
    }

    @Test("a method outside the grant is forbidden, before the app is asked")
    func horsAutorisation() async {
        let services = FakeServices()
        services.frontmost = Self.id
        let bare = makeBridge(services, permissions: .empty)
        for method in ["sessions.list", "sessions.launch", "projects.list", "http.fetch", "sessions.open"] {
            let response = await call(bare, method, .object(["prompt": .string("x"), "sessionId": .string("s1"),
                                                             "url": .string("https://a.atlassian.net/")]))
            #expect(response.error?.code == .forbidden, "\(method)")
        }
        #expect(services.launches.isEmpty)
        #expect(services.opened.isEmpty)
    }

    @Test("info, projects and sessions answer with the app's values")
    func lectures() async throws {
        let bridge = makeBridge(FakeServices())
        let info = try #require(await call(bridge, "loom.info").result)
        #expect(info["extensionId"] == .string(Self.id))
        #expect(info["loomApi"] == .number(1))
        let projects = try #require(await call(bridge, "projects.list").result)
        #expect(projects["projects"] == .array([.object(["id": .string("p1"), "name": .string("loom")])]))
        let sessions = try #require(await call(bridge, "sessions.list").result)
        #expect(sessions["sessions"] != nil)
        let missing = await call(bridge, "sessions.get", .object(["sessionId": .string("nope")]))
        #expect(missing.error?.code == .notFound)
    }

    @Test("a launch is forwarded to the app only while the extension is on screen")
    func lancement() async throws {
        let services = FakeServices()
        let bridge = makeBridge(services)
        let params: JSONValue = .object(["prompt": .string("Fix PROJ-1"), "title": .string("PROJ-1 · Fix"),
                                         "badges": .array([.string("PROJ-1")])])
        let hidden = await call(bridge, "sessions.launch", params)
        #expect(hidden.error?.code == .forbidden)
        #expect(services.launches.isEmpty)

        services.frontmost = Self.id
        let shown = await call(bridge, "sessions.launch", params)
        #expect(shown.result?["launched"] == .bool(true))
        #expect(services.launches.first?.badges == ["PROJ-1"])

        let empty = await call(bridge, "sessions.launch", .object(["prompt": .string(" ")]))
        #expect(empty.error?.code == .invalidParams)
    }

    @Test("opening a session reaches live ones only")
    func ouverture() async {
        let services = FakeServices()
        let bridge = makeBridge(services)
        #expect(await call(bridge, "sessions.open", .object(["sessionId": .string("s1")])).error == nil)
        #expect(await call(bridge, "sessions.open", .object(["sessionId": .string("zz")])).error?.code == .notFound)
        #expect(services.opened == ["s1"])
    }

    @Test("storage and secrets round-trip through the bridge, secrets per extension")
    func stockageEtSecrets() async throws {
        let secrets = InMemorySecretStore()
        let bridge = makeBridge(FakeServices(), secrets: secrets)
        _ = await call(bridge, "storage.set", .object(["key": .string("board"), "value": .number(12)]))
        #expect(await call(bridge, "storage.get", .object(["key": .string("board")])).result?["value"] == .number(12))
        _ = await call(bridge, "storage.delete", .object(["key": .string("board")]))
        #expect(await call(bridge, "storage.get", .object(["key": .string("board")])).result?["value"] == .null)

        _ = await call(bridge, "secrets.set", .object(["key": .string("token"), "value": .string("s3cr3t")]))
        #expect(try secrets.secret("token", for: Self.id) == "s3cr3t")
        #expect(await call(bridge, "secrets.get", .object(["key": .string("token")])).result?["value"]
                == .string("s3cr3t"))
        #expect(await call(bridge, "secrets.get", .object(["key": .string("../x")])).error?.code == .invalidParams)
    }

    @Test("http.fetch to a host the extension may not reach is forbidden")
    func reseauHorsListe() async {
        let response = await call(makeBridge(FakeServices()), "http.fetch",
                                  .object(["url": .string("https://example.com/")]))
        #expect(response.error?.code == .forbidden)
    }

    @Test("openExternal takes https only, and only from the extension on screen")
    func ouvertureExterne() async {
        let services = FakeServices()
        let bridge = makeBridge(services)
        let url: JSONValue = .object(["url": .string("https://acme.atlassian.net/browse/PROJ-1")])
        #expect(await call(bridge, "ui.openExternal", url).error?.code == .forbidden)
        services.frontmost = Self.id
        #expect(await call(bridge, "ui.openExternal", url).error == nil)
        #expect(await call(bridge, "ui.openExternal", .object(["url": .string("file:///etc/hosts")])).error?.code
                == .invalidParams)
        #expect(services.external.count == 1)
    }
}
