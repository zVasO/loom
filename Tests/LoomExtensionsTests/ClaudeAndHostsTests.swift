import Testing
import LoomExtensions
import LoomAPI
import Foundation

// ADR-0015 — the two doors a tech-watch extension needed: `claude.complete`
// (text from the user's Claude Code, from the background too) and hosts granted
// at use (`optionalNetwork` + `network.request`). Their permissions, their
// checks, and the bridge's guards against the fake app.

@Suite("Extensions — Claude and hosts at use: permissions and parameters")
struct ClaudeAndHostsParamsTests {

    private func decode(_ json: String) throws -> ExtensionPermissions {
        try JSONDecoder().decode(ExtensionPermissions.self, from: Data(json.utf8))
    }

    @Test("a manifest asks for optionalNetwork and claude; anything else in claude is refused")
    func decodage() throws {
        let permissions = try decode(#"{"network":["hn.algolia.com"],"optionalNetwork":true,"claude":["complete"]}"#)
        #expect(permissions.optionalNetwork)
        #expect(permissions.claude == [.complete])
        #expect(!permissions.isEmpty)
        #expect(throws: ManifestError.self) { try decode(#"{"claude":["tools"]}"#) }
        #expect(throws: ManifestError.self) { try decode(#"{"optionalNetwork":"yes"}"#) }
    }

    @Test("missing, intersection and union carry the new permissions")
    func algebre() {
        let asked = ExtensionPermissions(network: ["a.example.com"], optionalNetwork: true, claude: [.complete])
        let missing = asked.missing(from: ExtensionPermissions(network: ["a.example.com"]))
        #expect(missing == ExtensionPermissions(optionalNetwork: true, claude: [.complete]))
        #expect(asked.missing(from: asked).isEmpty)
        #expect(asked.intersection(.empty) == .empty)
        #expect(asked.intersection(asked) == asked)
        #expect(ExtensionPermissions(network: ["a.example.com"]).union(missing) == asked)
    }

    @Test("http.fetch needs hosts: declared ones, or the right to ask for some")
    func autorisations() {
        #expect(ExtensionPermissions(optionalNetwork: true).allows(.network))
        #expect(ExtensionPermissions(optionalNetwork: true).allows(.optionalNetwork))
        #expect(!ExtensionPermissions(network: ["a.example.com"]).allows(.optionalNetwork))
        #expect(ExtensionPermissions(claude: [.complete]).allows(.claude(.complete)))
        #expect(!ExtensionPermissions.empty.allows(.claude(.complete)))
    }

    @Test("the consent sheet says both in plain words")
    func resume() {
        let summary = ExtensionPermissions(optionalNetwork: true, claude: [.complete]).summary
        #expect(summary.contains { $0.contains("other sites") })
        #expect(summary.contains { $0.contains("Claude") && $0.contains("plan") })
    }

    @Test("an old-style grant encodes no new key — an older Loom still reads state.json")
    func encodageCompatible() throws {
        let old = ExtensionPermissions(network: ["a.example.com"], sessions: [.read], background: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["network", "sessions", "background"])
        let full = ExtensionPermissions(network: ["a.example.com"], optionalNetwork: true, claude: [.complete])
        #expect(try JSONDecoder().decode(ExtensionPermissions.self, from: JSONEncoder().encode(full)) == full)
        #expect(try JSONDecoder().decode(ExtensionPermissions.self, from: JSONEncoder().encode(ExtensionPermissions.empty)) == .empty)
    }

    @Test("each new method needs its permission; network.granted none")
    func exigences() {
        #expect(BridgeMethod.claudeComplete.requirement == .claude(.complete))
        #expect(BridgeMethod.networkRequest.requirement == .optionalNetwork)
        #expect(BridgeMethod.networkRevoke.requirement == .optionalNetwork)
        #expect(BridgeMethod.networkGranted.requirement == nil)
        #expect(BridgeEvent.networkChanged(granted: []).requirement == .optionalNetwork)
    }

    @Test("claude.complete's parameters: a prompt, a known model, a timeout clamped to 10 s … 5 min")
    func parametresClaude() throws {
        let checked = try BridgeClaudeCompleteParams(prompt: "Résume", system: "  ", model: "haiku", timeoutMs: 1_000).validated()
        #expect(checked == ClaudeCompletionRequest(prompt: "Résume", system: nil, model: "haiku", timeout: 10))
        #expect(try BridgeClaudeCompleteParams(prompt: "x", timeoutMs: 3_600_000).validated().timeout == 300)
        #expect(try BridgeClaudeCompleteParams(prompt: "x").validated().timeout == 120)
        #expect(throws: BridgeError(.invalidParams, "claude.complete needs a prompt")) {
            try BridgeClaudeCompleteParams(prompt: "  \n").validated()
        }
        #expect(throws: BridgeError.self) { try BridgeClaudeCompleteParams(prompt: "x", model: "gpt").validated() }
        let tooLong = String(repeating: "a", count: BridgeClaudeCompleteParams.maxPromptLength + 1)
        do {
            _ = try BridgeClaudeCompleteParams(prompt: tooLong).validated()
            Issue.record("expected tooLarge")
        } catch let error as BridgeError {
            #expect(error.code == .tooLarge)
        }
    }

    @Test("the hourly budget refuses the 31st run, then frees up as the hour slides")
    func budget() {
        var budget = ClaudeCompletionBudget()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Taken before #expect: it hands a checked call's receiver to a
        // closure as an immutable value, and admit is mutating.
        for minute in 0..<ClaudeCompletionBudget.maxPerHour {
            let admitted = budget.admit(now: start.addingTimeInterval(Double(minute) * 60))
            #expect(admitted)
        }
        let thirtyFirst = budget.admit(now: start.addingTimeInterval(40 * 60))
        #expect(!thirtyFirst)
        let anHourLater = budget.admit(now: start.addingTimeInterval(3600))
        #expect(anHourLater)
    }

    @Test("hosts asked at use: exact names, lowercased, each once, at most ten")
    func hotes() throws {
        #expect(try BridgeHostsParams(hosts: ["Blog.Example.com", "blog.example.com", "x.dev"]).validatedHosts()
                == ["blog.example.com", "x.dev"])
        for bad in ["*.example.com", "example", "1.2.3.4", "https://x.dev/feed", "x.dev:8443"] {
            #expect(throws: BridgeError.self, "\(bad)") { try BridgeHostsParams(hosts: [bad]).validatedHosts() }
        }
        #expect(throws: BridgeError.self) { try BridgeHostsParams(hosts: []).validatedHosts() }
        let eleven = (0..<11).map { "h\($0).example.com" }
        #expect(throws: BridgeError.self) { try BridgeHostsParams(hosts: eleven).validatedHosts() }
    }
}

@MainActor
@Suite("Extensions — Claude and hosts at use: the bridge")
struct ClaudeAndHostsBridgeTests {

    static let id = "dev.loom.tech-watch"

    private func makeBridge(_ services: FakeServices,
                            permissions: ExtensionPermissions = ExtensionPermissions(
                                network: ["hn.algolia.com"], optionalNetwork: true, claude: [.complete]),
                            grantedHosts: [String] = []) -> ExtensionBridge {
        let manifest = ExtensionManifest(id: Self.id, name: "Veille", version: "1", permissions: permissions)
        let storage = ExtensionStorage(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-bridge-\(UUID().uuidString)/storage.json"))
        return ExtensionBridge(manifest: manifest, permissions: permissions, services: services,
                               storage: storage, secrets: InMemorySecretStore(), http: ExtensionHTTPClient(),
                               grantedHosts: grantedHosts)
    }

    private func call(_ bridge: ExtensionBridge, _ method: String,
                      _ params: JSONValue = .object([:])) async -> BridgeResponse {
        await bridge.handle(BridgeRequest(id: "r", method: method, params: params))
    }

    @Test("without the permissions: forbidden, and the app is never asked")
    func horsAutorisation() async {
        let services = FakeServices()
        services.frontmost = Self.id
        let bare = makeBridge(services, permissions: ExtensionPermissions(network: ["hn.algolia.com"]))
        let complete = await call(bare, "claude.complete", .object(["prompt": .string("x")]))
        #expect(complete.error?.code == .forbidden)
        let request = await call(bare, "network.request", .object(["hosts": .array([.string("blog.example.com")])]))
        #expect(request.error?.code == .forbidden)
        #expect(services.completions.isEmpty)
        #expect(services.hostRequests.isEmpty)
    }

    @Test("claude.complete answers from the background — no screen needed")
    func claudeEnArrierePlan() async throws {
        let services = FakeServices()
        let bridge = makeBridge(services)
        let response = await call(bridge, "claude.complete",
                                  .object(["prompt": .string("Résume"), "model": .string("sonnet")]))
        let result = try #require(response.result)
        #expect(result["text"] == .string("Résumé"))
        #expect(result["truncated"] == .bool(false))
        #expect(services.completions == [ClaudeCompletionRequest(prompt: "Résume", model: "sonnet")])
    }

    @Test("a second run while one is going: conflict")
    func uneALaFois() async throws {
        let services = FakeServices()
        services.holdCompletions = true
        let bridge = makeBridge(services)
        let first = Task { await self.call(bridge, "claude.complete", .object(["prompt": .string("one")])) }
        while services.completionGate == nil { await Task.yield() }
        let second = await call(bridge, "claude.complete", .object(["prompt": .string("two")]))
        #expect(second.error?.code == .conflict)
        services.holdCompletions = false
        services.completionGate?.resume()
        #expect(await first.value.result != nil)
        let third = await call(bridge, "claude.complete", .object(["prompt": .string("three")]))
        #expect(third.result != nil)
    }

    @Test("the app's errors reach the page as they are: unavailable, timeout")
    func erreursDeClaude() async {
        let services = FakeServices()
        services.completionAnswer = .failure(BridgeError(.unavailable, "Claude: Not logged in"))
        let bridge = makeBridge(services)
        let response = await call(bridge, "claude.complete", .object(["prompt": .string("x")]))
        #expect(response.error == BridgeError(.unavailable, "Claude: Not logged in"))
    }

    @Test("network.request off screen: forbidden; hosts already allowed need no sheet")
    func demandeHorsEcran() async throws {
        let services = FakeServices()
        let bridge = makeBridge(services)
        let offScreen = await call(bridge, "network.request", .object(["hosts": .array([.string("blog.example.com")])]))
        #expect(offScreen.error?.code == .forbidden)
        let declared = try #require(await call(bridge, "network.request",
                                               .object(["hosts": .array([.string("hn.algolia.com")])])).result)
        #expect(declared["granted"] == .array([.string("hn.algolia.com")]))
        #expect(services.hostRequests.isEmpty)
    }

    @Test("an approved host becomes reachable; a denied one stays out")
    func accordEtRefus() async throws {
        let services = FakeServices()
        services.frontmost = Self.id
        services.hostAnswer = ["blog.example.com"]
        let bridge = makeBridge(services)
        let response = try #require(await call(bridge, "network.request", .object(["hosts": .array([
            .string("blog.example.com"), .string("evil.example.net"), .string("hn.algolia.com"),
        ])])).result)
        #expect(services.hostRequests == [["blog.example.com", "evil.example.net"]])
        #expect(response["granted"] == .array([.string("blog.example.com"), .string("hn.algolia.com")]))
        #expect(response["denied"] == .array([.string("evil.example.net")]))
        #expect(bridge.allowedHostPatterns.contains { $0.matches(host: "blog.example.com") })
        #expect(!bridge.allowedHostPatterns.contains { $0.matches(host: "evil.example.net") })
        let listed = try #require(await call(bridge, "network.granted").result)
        #expect(listed["declared"] == .array([.string("hn.algolia.com")]))
        #expect(listed["granted"] == .array([.string("blog.example.com")]))
    }

    @Test("revoking takes the host back, from the bridge and the app")
    func revocation() async throws {
        let services = FakeServices()
        let bridge = makeBridge(services, grantedHosts: ["blog.example.com"])
        #expect(bridge.allowedHostPatterns.contains { $0.matches(host: "blog.example.com") })
        let response = await call(bridge, "network.revoke", .object(["hosts": .array([.string("blog.example.com")])]))
        #expect(response.result != nil)
        #expect(services.revoked == [["blog.example.com"]])
        #expect(!bridge.allowedHostPatterns.contains { $0.matches(host: "blog.example.com") })
    }

    @Test("http.fetch to a host never granted: forbidden, even with optionalNetwork")
    func fetchHorsListe() async {
        // The bridge holds its services weakly: they live as long as the test.
        let services = FakeServices()
        let bridge = makeBridge(services, permissions: ExtensionPermissions(optionalNetwork: true))
        let response = await call(bridge, "http.fetch", .object(["url": .string("https://blog.example.com/feed.xml")]))
        #expect(response.error?.code == .forbidden)
        withExtendedLifetime(services) {}
    }

    @Test("hosts granted without optionalNetwork in the grant reach nothing")
    func hotesSansPermission() {
        let services = FakeServices()
        let bridge = makeBridge(services, permissions: ExtensionPermissions(network: ["hn.algolia.com"]),
                                grantedHosts: ["blog.example.com"])
        #expect(!bridge.allowedHostPatterns.contains { $0.matches(host: "blog.example.com") })
        withExtendedLifetime(services) {}
    }
}
