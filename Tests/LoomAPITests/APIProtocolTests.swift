import Testing
import LoomAPI
import LoomCore
import Foundation

// Seam: the wire contract of ADR-0010, as a client and a server both read it.
// Nothing here touches a socket — that is LoomIPCTests' job.

@Suite("LoomAPI — wire contract")
struct APIProtocolTests {

    @Test("a JSON value survives the round trip, nesting included")
    func jsonValueAllerRetour() throws {
        let value: JSONValue = .object([
            "n": .number(42), "s": .string("x"), "b": .bool(true), "z": .null,
            "a": .array([.number(1), .object(["k": .string("v")])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(value["a"] != nil)
        #expect(value["s"]?.stringValue == "x")
    }

    @Test("typed models cross the JSON value both ways")
    func modelesTypes() throws {
        let params = APISetBadgesParams(sessionId: nil, badges: ["review", "urgent"])
        let value = try JSONValue.from(params)
        #expect(value["badges"] == .array([.string("review"), .string("urgent")]))
        #expect(try value.decode(APISetBadgesParams.self) == params)
    }

    @Test("a request line carries the token and the request; params default to an empty object")
    func ligneDeRequete() throws {
        let request = APIRequest(id: "r1", method: .badgeList)
        let line = try APIEnvelope.requestLine(token: "tok", request: request)
        #expect(line.last == UInt8(ascii: "\n"), "one line, newline-terminated")
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object[APIEnvelope.tokenKey] as? String == "tok")
        let inner = try #require(object[APIEnvelope.requestKey] as? [String: Any])
        #expect(inner["method"] as? String == "badge.list")

        let bare = Data(#"{"id":"r2","method":"loom.version"}"#.utf8)
        let decoded = try JSONDecoder().decode(APIRequest.self, from: bare)
        #expect(decoded.params == .object([:]), "a request without params is a request with none")
    }

    @Test("a response line decodes to a result or an error, never both")
    func ligneDeReponse() throws {
        let ok = try APIEnvelope.decodeResponse(Data(#"{"id":"r1","result":{"x":1}}"#.utf8))
        #expect(ok.result == .object(["x": .number(1)]))
        #expect(ok.error == nil)
        let failed = try APIEnvelope.decodeResponse(
            Data(#"{"id":"r1","error":{"code":"forbidden","message":"no"}}"#.utf8))
        #expect(failed.error?.code == .forbidden)
        #expect(failed.result == nil)
    }

    @Test("bad params become invalidParams, not a crash")
    func parametresInvalides() {
        let request = APIRequest(id: "r", method: .sessionSetTitle, params: .object(["title": .number(3)]))
        #expect(throws: APIError.self) { try request.decodeParams(APISetTitleParams.self) }
    }

    @Test("only the listing of every session demands the global token")
    func portees() {
        #expect(APIMethod.sessionsList.requiresGlobalScope)
        for method in APIMethod.allCases where method != .sessionsList {
            #expect(!method.requiresGlobalScope, "\(method.rawValue) works under a session token")
        }
    }

    @Test("protocol v2: the new error codes decode")
    func versionDeuxEtNouveauxCodes() throws {
        #expect(APIProtocol.version == 2)
        for code in ["timeout", "unavailable"] {
            let line = Data(#"{"id":"r","error":{"code":"\#(code)","message":"m"}}"#.utf8)
            #expect(try APIEnvelope.decodeResponse(line).error?.code.rawValue == code)
        }
    }

    @Test("every method's client waits at least 5 s, and 5 s past the app's own deadline")
    func budgetsDesMethodes() {
        for method in APIMethod.allCases {
            #expect(method.clientTimeout >= .seconds(5), "\(method.rawValue)")
            if let deadline = method.appDeadline {
                #expect(method.clientTimeout >= deadline + .seconds(5),
                        "\(method.rawValue): the app must give up before the client does")
            }
        }
    }

    @Test("a title written through the API is one bounded, printable line")
    func titreAssaini() {
        #expect(APILimits.sanitizedTitle("  Fix\nlogin\tflow  ") == "Fix login flow")
        #expect(APILimits.sanitizedTitle("a\u{0007}b\u{001B}[31m") == "ab[31m")
        #expect(APILimits.sanitizedTitle(String(repeating: "x", count: 200)).count == APILimits.titleMaxLength)
        #expect(APILimits.sanitizedTitle("\n\t ").isEmpty)
    }

    @Test("badges are bounded in number and in length")
    func badgesBornes() {
        #expect(APILimits.badgeProblem(["review", "wip"]) == nil)
        #expect(APILimits.badgeProblem(Array(repeating: "b", count: APILimits.badgesPerSession + 1)) != nil)
        #expect(APILimits.badgeProblem([String(repeating: "x", count: APILimits.badgeNameMaxLength + 1)]) != nil)
    }

    @Test("the browser answers its session's own token only, and answers Markdown")
    func outilsNavigateurPortesParLaSession() {
        let browser = APIMethod.allCases.filter(\.isBrowser)
        #expect(browser.count == 20)
        for method in browser {
            #expect(!method.allowsGlobalScope, "\(method.rawValue) refuses the global token")
            #expect(!method.requiresGlobalScope)
            #expect(method.appDeadline != nil, "\(method.rawValue) has its own deadline")
            #expect(APIToolCatalog.spec(for: method).resultFormat == .content)
        }
        for method in APIMethod.allCases where !method.isBrowser {
            #expect(method.allowsGlobalScope)
            #expect(APIToolCatalog.spec(for: method).resultFormat == .json)
        }
    }

    @Test("browser tools off: none listed, none pre-approved, nothing said about them")
    func catalogueSansNavigateur() {
        #expect(!APIToolCatalog.tools(browser: false).contains { $0.method.isBrowser })
        #expect(APIToolCatalog.tools(browser: true).count == APIToolCatalog.all.count)
        #expect(!APIToolCatalog.agentInstructions(browser: false).contains("browser_"))
        #expect(APIToolCatalog.agentInstructions(browser: true).contains("browser_snapshot"))
        let rules = APIToolCatalog.preapprovedRules(browser: false)
        #expect(rules.contains("mcp__loom__loom_session_get"))
        #expect(!rules.contains { $0.contains("browser_") })
        #expect(APIToolCatalog.preapprovedRules(browser: true).contains("mcp__loom__browser_click"))
        #expect(!APIToolCatalog.preapprovedRules(browser: true).contains("mcp__loom"),
                "never the whole server: a tool added later is not pre-approved by default")
    }

    @Test("the actions that answer a snapshot, and only they, may leave it out")
    func optionInstantane() {
        let answering = APIMethod.allCases.filter(\.answersSnapshot)
        #expect(answering.count == 14)
        #expect(APIMethod.browserRunCode.answersSnapshot, "a snapshot at the end, unless snapshot none")
        #expect(!APIMethod.browserSnapshot.answersSnapshot, "it is the snapshot")
        #expect(!APIMethod.browserScreenshot.answersSnapshot && !APIMethod.browserEvaluate.answersSnapshot)
        for method in APIMethod.allCases where method.isBrowser {
            let property = APIToolCatalog.spec(for: method).inputSchema["properties"]?["snapshot"]
            if method.answersSnapshot {
                #expect(property?["enum"] == .array([.string("full"), .string("none")]), "\(method.rawValue)")
                guard case .array(let required)? = APIToolCatalog.spec(for: method).inputSchema["required"] else { continue }
                #expect(!required.contains(.string("snapshot")), "opt-in: never required")
            } else {
                #expect(property == nil, "\(method.rawValue) takes no snapshot option")
            }
        }
        #expect(APIToolCatalog.agentInstructions(browser: true).contains("snapshot \"none\""))
    }

    @Test("the engine words the tools: real events on Chromium, synthetic ones on WebKit")
    func outilsSelonLeMoteur() {
        func description(_ name: String, _ engine: APIBrowserEngine) -> String {
            APIToolCatalog.tools(browser: true, engine: engine).first { $0.name == name }?.description ?? ""
        }
        #expect(description("browser_hover", .webkit).contains("CSS :hover does not"))
        #expect(description("browser_hover", .chromium).contains("CSS :hover applies"))
        #expect(APIToolCatalog.agentInstructions(browser: true, engine: .webkit).contains("Events are synthetic"))
        let chromium = APIToolCatalog.agentInstructions(browser: true, engine: .chromium)
        #expect(chromium.contains("real") && !chromium.contains("synthetic"))
        #expect(APIToolCatalog.all == APIToolCatalog.all(engine: .webkit), "loom docs: the WebKit words")
        #expect(Set(APIToolCatalog.tools(browser: true, engine: .webkit).map(\.name))
                .isSubset(of: Set(APIToolCatalog.tools(browser: true, engine: .chromium).map(\.name))))
        #expect(APIToolCatalog.preapprovedRules(browser: true, engine: .chromium).contains("mcp__loom__browser_hover"))
        #expect(APIBrowserEngine(environment: ["LOOM_BROWSER_ENGINE": "chromium"]) == .chromium)
        #expect(APIBrowserEngine(environment: [:]) == .webkit)
        #expect(APIBrowserEngine(environment: ["LOOM_BROWSER_ENGINE": "gecko"]) == .webkit)
    }

    @Test("the browser tools' schemas require what the method cannot do without")
    func schemasNavigateurRequis() {
        func required(_ method: APIMethod) -> Set<String> {
            guard case .array(let names)? = APIToolCatalog.spec(for: method).inputSchema["required"] else { return [] }
            return Set(names.compactMap(\.stringValue))
        }
        #expect(required(.browserNavigate) == ["url"])
        #expect(required(.browserType) == ["text"])
        #expect(required(.browserPressKey) == ["key"])
        #expect(required(.browserEvaluate) == ["function"])
        #expect(required(.browserHandleDialog) == ["accept"])
        #expect(APIToolCatalog.spec(named: "browser_take_screenshot")?.method == .browserScreenshot)
    }

    @Test("a client reads an image only under the screenshots directory, symlinks resolved")
    func imageSousLeDossier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-shots-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("000001.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: inside)
        let image = APIImageRef(path: inside.path, mimeType: "image/png", width: 1, height: 1)
        #expect(APIImageFile.validated(image, root: root) != nil)
        #expect(APIImageFile.validated(APIImageRef(path: "/etc/hosts", mimeType: "image/png", width: 1, height: 1),
                                       root: root) == nil)
        #expect(APIImageFile.validated(APIImageRef(path: root.path + "/../x.png", mimeType: "image/png",
                                                   width: 1, height: 1), root: root) == nil)
        #expect(APIImageFile.validated(APIImageRef(path: inside.path, mimeType: "text/plain", width: 1, height: 1),
                                       root: root) == nil)
        #expect(APIImageFile.validated(image, root: root, sizeOf: { _ in APIImageFile.maxBytes + 1 }) == nil)
        #expect(APIProtocol.screenshotsDirectory(socketPath: "/support/loom.sock").path
                == "/support/agent-browser/screenshots")
    }

    @Test("a badge color is #RRGGBB, nothing else")
    func couleurDeBadge() {
        #expect(APIBadge.isValidColor("#4CC38A"))
        #expect(APIBadge.isValidColor("#4cc38a"))
        #expect(!APIBadge.isValidColor("4CC38A"))
        #expect(!APIBadge.isValidColor("#4CC38"))
        #expect(!APIBadge.isValidColor("#GGGGGG"))
    }

    @Test("the tool catalog covers every method, with MCP-legal unique names")
    func catalogueDesOutils() {
        let names = APIToolCatalog.all(engine: .chromium).map(\.name)
        #expect(Set(names).count == names.count, "one name per tool")
        for method in APIMethod.allCases {
            #expect(APIToolCatalog.all(engine: .chromium).contains { $0.method == method }, "\(method.rawValue) has a tool")
            if method != .browserRunCode {
                #expect(APIToolCatalog.all.contains { $0.method == method }, "\(method.rawValue) is on WebKit too")
            }
        }
        for name in names {
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" },
                    "\(name) fits an MCP tool name")
            #expect(APIToolCatalog.spec(named: name)?.name == name)
        }
        #expect(APIToolCatalog.spec(named: "nope") == nil)
        let docs = APIToolCatalog.markdown()
        for method in APIMethod.allCases {
            #expect(docs.contains("`\(method.rawValue)`"), "the reference names \(method.rawValue)")
        }
        #expect(docs.contains("(required)"), "required parameters are marked")
    }

    @Test("browser_run_code: Chromium only, pre-approved there, the largest deadline, code required")
    func executerDuCode() throws {
        func names(_ engine: APIBrowserEngine) -> [String] {
            APIToolCatalog.tools(browser: true, engine: engine).map(\.name)
        }
        #expect(names(.chromium).contains("browser_run_code"))
        #expect(!names(.webkit).contains("browser_run_code"), "no public way stops a WebKit script that spins")
        #expect(!APIToolCatalog.tools(browser: false, engine: .chromium).contains { $0.method == .browserRunCode })
        #expect(APIToolCatalog.preapprovedRules(browser: true, engine: .chromium).contains("mcp__loom__browser_run_code"))
        #expect(!APIToolCatalog.preapprovedRules(browser: true, engine: .webkit).contains("mcp__loom__browser_run_code"))
        #expect(!APIToolCatalog.preapprovedRules(browser: false, engine: .chromium).contains { $0.contains("run_code") })
        #expect(APIToolCatalog.agentInstructions(browser: true, engine: .chromium).contains("browser_run_code"))
        #expect(!APIToolCatalog.agentInstructions(browser: true, engine: .webkit).contains("browser_run_code"))

        let spec = APIToolCatalog.spec(for: .browserRunCode)
        #expect(spec.name == "browser_run_code" && spec.preapprovable && spec.resultFormat == .content)
        #expect(APIToolCatalog.spec(named: "browser_run_code")?.method == .browserRunCode)
        #expect(spec.inputSchema["required"] == .array([.string("code")]))
        #expect(spec.inputSchema["properties"]?["filename"] == nil, "refused, so never offered")
        #expect(spec.inputSchema["properties"]?["snapshot"] != nil)
        #expect(spec.description.contains("async (page) =>"))
        #expect(APIMethod.browserRunCode.rawValue == "browser.runCode" && APIMethod.browserRunCode.isBrowser)
        #expect(!APIMethod.browserRunCode.allowsGlobalScope, "it acts in the session's own profile")

        // 56 s of script and 4 s to stop it, settle and answer; above every other method.
        let deadline = try #require(APIMethod.browserRunCode.appDeadline)
        #expect(deadline == .seconds(60))
        #expect(APIMethod.browserRunCode.clientTimeout == .seconds(65))
        for method in APIMethod.allCases where method != .browserRunCode {
            #expect((method.appDeadline ?? .zero) < deadline, "\(method.rawValue)")
        }
        // loom docs: the reference names it, as Chromium's.
        let docs = APIToolCatalog.markdown()
        #expect(docs.contains("`browser.runCode`") && docs.contains("Chromium engine only"))
    }

    @Test("a tool answer's isError: nil, and absent from the JSON, unless the answer is a failure")
    func contenuEnErreur() throws {
        let plain = try JSONValue.from(APIToolContent(text: "### Page"))
        #expect(plain["isError"] == nil, "every other tool's JSON is unchanged")
        let failed = try JSONValue.from(APIToolContent(text: "### Error\nboom", isError: true))
        #expect(failed["isError"] == .bool(true))
        #expect(try failed.decode(APIToolContent.self).isError == true)
        #expect(try plain.decode(APIToolContent.self).isError == nil)
        let params = try JSONValue.object(["code": .string("async (page) => 1"), "snapshot": .string("none")])
            .decode(APIBrowserRunCodeParams.self)
        #expect(params == APIBrowserRunCodeParams(code: "async (page) => 1", snapshot: "none"))
    }

    @Test("the client finds its way from the environment Loom gives an agent")
    func clientDepuisLEnvironnement() {
        #expect(APIClient.fromEnvironment([:]) == nil, "outside Loom: no client")
        let client = APIClient.fromEnvironment([APIProtocol.socketEnvironmentKey: "/tmp/loom.sock",
                                                APIProtocol.sessionTokenEnvironmentKey: "t"])
        #expect(client?.socketPath == "/tmp/loom.sock")
        #expect(client?.token == "t")
    }
}
