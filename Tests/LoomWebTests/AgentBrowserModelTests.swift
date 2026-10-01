import Testing
import Foundation
import LoomAPI
import LoomWeb

// The agent's browser (ADR-0014), its pure parts: where it may go, which
// store it uses, how keys and parameters are read, what it logs, and the
// Markdown it answers. WebKit itself is checked by the app's self-test on a
// Mac (`LOOM_AUTOTEST=agent-browser`) and the JS by Tests/AgentBrowserJS.

@Suite("Agent browser — addresses and policy")
struct AgentBrowserPolicyTests {

    @Test("loopback hosts, and the host of an address typed bare")
    func hotesDeBoucleLocale() {
        for host in ["localhost", "LOCALHOST", "app.localhost", "127.0.0.1", "127.4.5.6", "::1", "[::1]", "0.0.0.0"] {
            #expect(LoopbackHost.isLoopback(host), "\(host)")
        }
        for host in ["localhostfoo", "128.0.0.1", "127.0.0", "example.com", "10.0.0.1"] {
            #expect(!LoopbackHost.isLoopback(host), "\(host)")
        }
        #expect(LoopbackHost.host(ofAddress: "localhost:5173/app?x=1") == "localhost")
        #expect(LoopbackHost.host(ofAddress: "[::1]:8000") == "[::1]")
        #expect(LoopbackHost.host(ofAddress: "user@127.0.0.1:22") == "127.0.0.1")
        #expect(LoopbackHost.host(ofAddress: "/path") == nil)
    }

    @Test("the main frame goes to http(s) and about:blank only; frames may hold inline content")
    func politiqueDeNavigationAgent() {
        func decide(_ address: String, main: Bool = true) -> AgentNavigationPolicy.Decision {
            AgentNavigationPolicy.decide(url: URL(string: address), isMainFrame: main)
        }
        #expect(decide("http://localhost:5173") == .allow)
        #expect(decide("https://example.com") == .allow)
        #expect(decide("about:blank") == .allow)
        #expect(decide("file:///etc/hosts") == .cancel)
        #expect(decide("data:text/html,<b>x</b>") == .cancel)
        #expect(decide("javascript:alert(1)") == .cancel)
        #expect(decide("vscode://open") == .cancel)
        #expect(decide("data:text/html,x", main: false) == .allow)
        #expect(decide("about:srcdoc", main: false) == .allow)
        #expect(decide("file:///etc/hosts", main: false) == .cancel)
    }

    @Test("browser_navigate takes the address bar's rules, then the policy")
    func adresseDeNavigation() throws {
        #expect(try AgentNavigationPolicy.navigationURL("localhost:5173").absoluteString == "http://localhost:5173")
        #expect(try AgentNavigationPolicy.navigationURL("example.com").absoluteString == "https://example.com")
        #expect(throws: AgentError.self) { try AgentNavigationPolicy.navigationURL("file:///etc/passwd") }
        #expect(throws: AgentError.self) { try AgentNavigationPolicy.navigationURL("javascript:alert(1)") }
    }
}

@Suite("Agent browser — profiles")
struct AgentBrowserProfileTests {

    @Test("one store per project: deterministic, distinct, never the project's own id")
    func identifiantDeStoreParProjet() {
        let project = UUID()
        let first = AgentBrowserProfile.storeIdentifier(forProject: project)
        #expect(first == AgentBrowserProfile.storeIdentifier(forProject: project))
        #expect(first != AgentBrowserProfile.storeIdentifier(forProject: UUID()))
        #expect(first != project)
        let bytes = withUnsafeBytes(of: first.uuid) { Array($0) }
        #expect(bytes[6] >> 4 == 5, "a name-based (v5) UUID")
        #expect(bytes[8] & 0xC0 == 0x80, "RFC 4122 variant")
    }

    @Test("reviews and project-less sessions get a private store")
    func revueToujoursPrivee() {
        let project = UUID()
        #expect(AgentBrowserProfile.kind(projectID: project, isReview: true) == .private)
        #expect(AgentBrowserProfile.kind(projectID: nil, isReview: false) == .private)
        #expect(AgentBrowserProfile.kind(projectID: project, isReview: false)
                == .project(AgentBrowserProfile.storeIdentifier(forProject: project)))
    }
}

@Suite("Agent browser — profiles on disk")
struct AgentProfileSweepTests {

    @Test("the sweep deletes the profiles of removed projects, never a current one's")
    func profilsOrphelins() {
        let kept = UUID()
        let removed = UUID()
        let registered = [kept, removed].map(AgentBrowserProfile.storeIdentifier(forProject:))
        #expect(AgentBrowserProfile.orphanedStores(registered: registered, projects: [kept])
                == [AgentBrowserProfile.storeIdentifier(forProject: removed)])
        #expect(AgentBrowserProfile.orphanedStores(registered: registered, projects: [kept, removed]).isEmpty)
        #expect(AgentBrowserProfile.orphanedStores(registered: [], projects: []).isEmpty)
    }
}

@Suite("Agent browser — keys")
struct AgentKeysTests {

    @Test("Playwright's key syntax, as the page's events carry it")
    func touchesClavier() throws {
        let enter = try KeySpec.parse("Enter")
        #expect(enter.key == "Enter" && enter.code == "Enter" && enter.keyCode == 13 && enter.text == nil)
        let back = try KeySpec.parse("Shift+Tab")
        #expect(back.key == "Tab" && back.shiftKey && !back.ctrlKey)
        let all = try KeySpec.parse("ControlOrMeta+a")
        #expect(all.metaKey && all.key == "a" && all.text == nil, "a shortcut types nothing")
        let upper = try KeySpec.parse("Shift+a")
        #expect(upper.key == "A" && upper.text == "A" && upper.code == "KeyA" && upper.keyCode == 65)
        #expect(try KeySpec.parse("F5").keyCode == 116)
        #expect(try KeySpec.parse("7").code == "Digit7")
        #expect(try KeySpec.parse("/").code == "Slash")
        #expect(try KeySpec.parse("+").key == "+")
        #expect(try KeySpec.parse("Shift++").shiftKey)
        #expect(try KeySpec.parse("escape").key == "Escape", "named keys forgive case")
        #expect(throws: AgentError.self) { try KeySpec.parse("Hyper+x") }
        #expect(throws: AgentError.self) { try KeySpec.parse("NotAKey") }
        #expect(throws: AgentError.self) { try KeySpec.parse("") }
    }

    @Test("typing a text key by key: capitals shifted, a newline is Enter, anything else types itself")
    func toucheParCaractere() {
        let capital = KeySpec.typing("M")
        #expect(capital.key == "M" && capital.text == "M" && capital.shiftKey && capital.code == "KeyM")
        #expect(KeySpec.typing("m").shiftKey == false)
        #expect(KeySpec.typing(" ").code == "Space" && KeySpec.typing(" ").text == " ")
        #expect(KeySpec.typing("\n").key == "Enter")
        #expect(KeySpec.typing("é").text == "é" && KeySpec.typing("é").keyCode == 0)
        #expect(KeySpec.typing("4").code == "Digit4")
    }
}

@Suite("Agent browser — what pages log")
struct AgentLogsTests {

    @Test("console: capacity, levels including the more severe, generations")
    func journalConsole() {
        var log = ConsoleLog(capacity: 3)
        log.append(level: .debug, text: "d")
        log.append(level: .info, text: "i")
        log.append(level: .warning, text: "w")
        log.append(level: .error, text: "e")
        #expect(log.entries.count == 3, "the oldest goes first")
        #expect(log.messages(level: .warning, all: false).map(\.text) == ["w", "e"])
        #expect(log.counts.errors == 1 && log.counts.warnings == 1)
        log.navigationCommitted()
        #expect(log.messages(level: .debug, all: false).isEmpty, "a new page starts clean")
        #expect(log.messages(level: .debug, all: true).count == 3)
        log.append(level: .error, text: String(repeating: "x", count: 5_000))
        #expect(log.entries.last?.text.count == ConsoleLog.maxText)
    }

    @Test("console render keeps the newest within its limit")
    func rendusRecents() {
        var log = ConsoleLog()
        for i in 0..<100 { log.append(level: .error, text: "message \(i)", location: "app.js:\(i)") }
        let text = log.render(level: .info, all: false, limit: 200)
        #expect(text.contains("[ERROR] message 99 @ app.js:99"))
        #expect(!text.contains("message 0 "))
        #expect(text.hasPrefix("("), "says how many were left out")
    }

    @Test("network: in flight since a mark, outcomes, the filter, abandoned by navigation")
    func journalReseau() {
        var log = NetworkLog()
        log.started(key: "main#1", kind: .fetch, method: "GET", url: "http://localhost/api/todos")
        let mark = log.lastSequence
        log.started(key: "main#2", kind: .xhr, method: "POST", url: "http://localhost/api/save")
        #expect(log.inFlight() == 2)
        #expect(log.inFlight(after: mark) == 1)
        log.finished(key: "main#1", status: 200, error: nil, durationMs: 34)
        log.finished(key: "main#2", status: nil, error: "Load failed", durationMs: 5)
        #expect(log.inFlight() == 0)
        let text = log.render(filter: "save", limit: 10_000)
        #expect(text == "[POST] http://localhost/api/save => [FAILED] Load failed (5 ms)")
        log.started(key: "main#3", kind: .fetch, method: "GET", url: "http://localhost/slow")
        log.navigationCommitted()
        #expect(log.inFlight() == 0, "the old page's requests never answer anyone")
    }

    @Test("hook messages: only the expected shapes, with bounded strings")
    func messagesDuCrochet() {
        #expect(AgentHookMessage.parse(["t": "console", "level": "error", "text": "boom", "loc": "a.js:1"] as [String: Any])
                == .console(level: .error, text: "boom", location: "a.js:1"))
        #expect(AgentHookMessage.parse(["t": "req", "id": 3, "kind": "fetch", "method": "GET", "url": "http://x"] as [String: Any])
                == .request(id: 3, kind: .fetch, method: "GET", url: "http://x"))
        #expect(AgentHookMessage.parse(["t": "res", "id": 3.0, "status": 404, "ms": 12] as [String: Any])
                == .response(id: 3, status: 404, error: nil, durationMs: 12))
        #expect(AgentHookMessage.parse(["t": "req", "id": 1, "kind": "document", "url": "x"] as [String: Any]) == nil,
                "a page cannot forge a document entry")
        #expect(AgentHookMessage.parse(["t": "console", "level": "shout", "text": "x"] as [String: Any]) == nil)
        #expect(AgentHookMessage.parse("not a dictionary") == nil)
        #expect(AgentHookMessage.parse(["t": "dropped", "n": Int.max] as [String: Any]) == nil,
                "a forged count never reaches Loom's arithmetic")
        #expect(AgentHookMessage.parse(["t": "dropped", "n": 999_999_999] as [String: Any]) == .dropped(1_000_000))
        #expect(AgentHookMessage.parse(["t": "res", "id": 9e18] as [String: Any]) == nil)
        if case .console(_, let text, _)? = AgentHookMessage.parse(
            ["t": "console", "level": "info", "text": String(repeating: "y", count: 10_000)] as [String: Any]) {
            #expect(text.count == ConsoleLog.maxText)
        } else {
            Issue.record("a long message is cut, not dropped")
        }
    }

    @Test("Loom's own rate limit, whatever the page's hook does")
    func limiteDeDebit() {
        var limiter = AgentRateLimiter(perSecond: 10, burst: 10)
        let admitted = (0..<50).filter { _ in limiter.admit(at: 100) }.count
        #expect(admitted == 10)
        #expect(limiter.admit(at: 100.5), "half a second later, five more")
    }
}

@Suite("Agent browser — loads")
struct MainFrameLoadTrackerTests {

    private final class Token {}

    @Test("settled once the started load finishes")
    func chargementSimple() {
        var tracker = MainFrameLoadTracker()
        let token = Token()
        let nav = ObjectIdentifier(token)
        tracker.requested(at: 0)
        #expect(!tracker.isSettled(at: 0.1), "requested, not started yet")
        tracker.started(nav)
        tracker.committed(nav)
        #expect(!tracker.isSettled(at: 1))
        tracker.finished(nav)
        #expect(tracker.isSettled(at: 1))
        #expect(tracker.startedCount == 1)
    }

    @Test("a redirect supersedes a load: the cancelled one is no failure, the new one is awaited")
    func chargementRemplace() {
        var tracker = MainFrameLoadTracker()
        // Kept alive: a freed object's identifier can be handed to the next.
        let tokens = (Token(), Token())
        let first = ObjectIdentifier(tokens.0)
        let second = ObjectIdentifier(tokens.1)
        tracker.started(first)
        tracker.started(second)
        tracker.failed(first, cancelled: true, message: "")
        #expect(!tracker.isSettled(at: 1))
        #expect(tracker.lastError == nil)
        tracker.committed(second)
        tracker.finished(second)
        #expect(tracker.isSettled(at: 1))
    }

    @Test("a request that never starts was same-document: settled after the grace")
    func memeDocument() {
        var tracker = MainFrameLoadTracker()
        tracker.requested(at: 10)
        #expect(!tracker.isSettled(at: 10.1))
        #expect(tracker.isSettled(at: 10 + MainFrameLoadTracker.noStartGrace))
    }

    @Test("a real failure is kept for the answer; a crash ends every wait")
    func echecs() {
        var tracker = MainFrameLoadTracker()
        let token = Token()
        let nav = ObjectIdentifier(token)
        tracker.started(nav)
        tracker.failed(nav, cancelled: false, message: "nothing is listening on localhost:5173")
        #expect(tracker.isSettled(at: 1))
        #expect(tracker.lastError == "nothing is listening on localhost:5173")
        tracker.started(nil)
        tracker.terminated()
        #expect(tracker.isSettled(at: 2))
        tracker.terminated(reloading: false)
        #expect(tracker.lastError?.contains("not reloaded") == true)
    }

    @Test("a new request forgets the last failure: it never fails a later load that worked")
    func echecOublie() {
        var tracker = MainFrameLoadTracker()
        let token = Token()
        let nav = ObjectIdentifier(token)
        tracker.started(nav)
        tracker.failed(nav, cancelled: false, message: "unknown host nowhere.invalid")
        tracker.requested(at: 5)
        #expect(tracker.lastError == nil, "a same-document load never starts: nothing else would clear it")
    }
}

@Suite("Agent browser — answers")
struct AgentResponseTests {

    private let page = AgentPageSummary(url: "http://localhost:5173/", title: "Todos")

    @Test("sections in Playwright's order, each only when it says something")
    func reponseSectionsOrdonnees() {
        let text = AgentResponseBuilder.render(
            result: "Clicked button \"Add\" [ref=e5]",
            page: AgentPageSummary(url: "http://localhost:5173/", title: "Todos", httpStatus: 200,
                                   consoleErrors: 1, consoleWarnings: 0),
            tabs: [AgentTabSummary(index: 0, title: "Todos", url: "http://localhost:5173/", isCurrent: true)],
            modal: nil, snapshot: "- button \"Add\" [ref=e5]", events: ["The page opened a new tab"])
        let result = text.range(of: "### Result")!.lowerBound
        let pageRange = text.range(of: "### Page")!.lowerBound
        let snapshot = text.range(of: "### Snapshot")!.lowerBound
        let events = text.range(of: "### Events")!.lowerBound
        #expect(result < pageRange && pageRange < snapshot && snapshot < events)
        #expect(!text.contains("### Open tabs"), "one tab: no list")
        #expect(!text.contains("HTTP status"), "a 2xx says nothing")
        #expect(text.contains("- Console: 1 errors, 0 warnings"))
        #expect(text.contains("```yaml\n- button \"Add\" [ref=e5]\n```"))
    }

    @Test("a pending dialog replaces the snapshot; a hidden page says so")
    func etatModal() {
        let modal = AgentModalState(kind: .confirm, message: "Delete \"3\" items?", host: "localhost")
        let text = AgentResponseBuilder.render(
            result: nil, page: AgentPageSummary(url: "u", title: "t", httpStatus: 500, hidden: true),
            tabs: [], modal: modal, snapshot: "- button", events: [])
        #expect(text.contains("### Modal state\n- [\"confirm\" dialog with message \"Delete \\\"3\\\" items?\"]: can be handled by browser_handle_dialog"))
        #expect(!text.contains("### Snapshot"))
        #expect(text.contains("- HTTP status: 500"))
        #expect(text.contains("- Visibility: hidden"))
        let chooser = AgentModalState(kind: .fileChooser(multiple: true), message: "", host: "localhost")
        #expect(chooser.line == "- [File chooser (multiple files)]: can be handled by browser_file_upload")
        let beside = AgentResponseBuilder.render(result: nil, page: page, tabs: [], modal: chooser,
                                                 snapshot: "- button \"Upload\" [ref=e3]", events: [])
        #expect(beside.contains("### Modal state") && beside.contains("### Snapshot"),
                "a file chooser leaves the page running: its snapshot shows")
    }

    @Test("a set width shows in CSS pixels, and says the page is scaled")
    func largeurAffichee() {
        let text = AgentResponseBuilder.render(
            result: nil, page: AgentPageSummary(url: "u", title: "t", viewport: CGSize(width: 1280, height: 1800),
                                                viewportScaled: true),
            tabs: [], modal: nil, snapshot: nil, events: [])
        #expect(text.contains("- Viewport: 1280×1800 (width set, scaled into the panel; browser_resize 0 to fit)"))
    }

    @Test("a previous run's screenshots: the numbering goes on after them")
    func numerotationContinue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-shots-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AgentScreenshot.lastSequence(in: directory) == 0)
        for name in ["000007.png", "000012.jpg", "notes.txt"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }
        #expect(AgentScreenshot.lastSequence(in: directory) == 12)
    }

    @Test("the answer never outgrows its limit: the snapshot is cut first")
    func limiteDeReponse() {
        var limits = AgentBrowserLimits()
        limits.responseChars = 2_000
        let huge = String(repeating: "- button \"x\" [ref=e1]\n", count: 1_000)
        let text = AgentResponseBuilder.render(result: "ok", page: page, tabs: [], modal: nil,
                                               snapshot: huge, events: ["kept"], limits: limits)
        #expect(text.count <= 2_000)
        #expect(text.contains("snapshot cut to fit"))
        #expect(text.contains("- kept"), "events survive the cut")
    }

    @Test("screenshots: the CSS size capped, never the Retina backing; the newest kept")
    func tailleDeCapture() {
        #expect(AgentScreenshot.targetSize(for: CGSize(width: 2400, height: 1600), maxEdge: 1568)
                == CGSize(width: 1568, height: 1045))
        #expect(AgentScreenshot.targetSize(for: CGSize(width: 800, height: 600), maxEdge: 1568)
                == CGSize(width: 800, height: 600))
        let names = (1...40).map { String(format: "%06d.png", $0) }
        let removed = AgentScreenshot.pruned(names, keep: 30)
        #expect(removed.count == 10)
        #expect(removed.contains("000001.png") && !removed.contains("000040.png"))
    }
}

@Suite("Agent browser — commands from the API")
struct AgentCommandAPITests {

    private func command(_ method: APIMethod, _ params: [String: JSONValue]) throws -> AgentCommand {
        try AgentCommand(method: method, params: .object(params))
    }

    @Test("each method decodes to its command; ref is target's alias")
    func decodage() throws {
        #expect(try command(.browserNavigate, ["url": .string("localhost:3000")])
                == .navigate(URL(string: "http://localhost:3000")!))
        #expect(try command(.browserClick, ["ref": .string("e12"), "element": .string("Save")])
                == .click(AgentTarget(target: "e12", element: "Save"), doubleClick: false, button: .left, modifiers: []))
        #expect(try command(.browserType, ["target": .string("#name"), "text": .string("Ada"), "submit": .bool(true)])
                == .type(AgentTarget(target: "#name"), text: "Ada", submit: true, slowly: false))
        #expect(try command(.browserPressKey, ["key": .string("Enter")]) == .pressKey(try KeySpec.parse("Enter")))
        #expect(try command(.browserTabs, ["action": .string("select"), "index": .number(1)]) == .tabs(.select(1)))
        #expect(try command(.browserConsole, [:]) == .console(level: .info, all: false))
        #expect(try command(.browserSnapshot, ["depth": .number(2)]) == .snapshot(target: nil, depth: 2))
        #expect(try command(.browserScreenshot, ["fullPage": .bool(true)])
                == .screenshot(target: nil, format: .png, fullPage: true))
        #expect(try command(.browserType, ["target": .string("e3"), "text": .string("Par"), "slowly": .bool(true)])
                == .type(AgentTarget(target: "e3"), text: "Par", submit: false, slowly: true))
        #expect(try command(.browserResize, ["width": .number(375), "height": .number(812)]) == .resize(.css(375)))
        #expect(try command(.browserResize, ["width": .number(0)]) == .resize(.fit))
        #expect(try command(.browserFileUpload, [:]) == .fileUpload(paths: nil), "no paths: cancel")
        #expect(try command(.browserFileUpload, ["paths": .array([.string("/w/a.png")])]) == .fileUpload(paths: ["/w/a.png"]))
    }

    @Test("a form: each field its kind, target and value; a boolean for a checkbox is accepted")
    func formulaire() throws {
        let fields: JSONValue = .array([
            .object(["name": .string("Email"), "type": .string("textbox"), "ref": .string("e4"), "value": .string("a@b.c")]),
            .object(["name": .string("Terms"), "type": .string("checkbox"), "target": .string("e7"), "value": .bool(true)]),
            .object(["name": .string("Volume"), "type": .string("slider"), "target": .string("#vol"), "value": .number(7)]),
        ])
        #expect(try command(.browserFillForm, ["fields": fields]) == .fillForm([
            FormField(name: "Email", kind: .textbox, target: AgentTarget(target: "e4", element: "Email"), value: "a@b.c"),
            FormField(name: "Terms", kind: .checkbox, target: AgentTarget(target: "e7", element: "Terms"), value: "true"),
            FormField(name: "Volume", kind: .slider, target: AgentTarget(target: "#vol", element: "Volume"), value: "7"),
        ]))
    }

    @Test("invalid parameters are the API's invalidParams, in words the agent can fix")
    func parametresInvalides() {
        func code(_ method: APIMethod, _ params: [String: JSONValue]) -> APIError.Code? {
            do {
                _ = try command(method, params)
                return nil
            } catch let error as APIError {
                return error.code
            } catch {
                return .internalError
            }
        }
        #expect(code(.browserClick, [:]) == .invalidParams, "no target")
        #expect(code(.browserType, ["target": .string("e1")]) == .invalidParams, "no text")
        #expect(code(.browserNavigate, ["url": .string("file:///etc/passwd")]) == .invalidParams)
        #expect(code(.browserWaitFor, [:]) == .invalidParams, "nothing to wait for")
        #expect(code(.browserWaitFor, ["time": .number(20), "text": .string("x"), "timeout": .number(20)])
                == .invalidParams, "longer than 30 s in all")
        #expect(code(.browserTabs, ["action": .string("select"), "index": .number(1.5)]) == .invalidParams)
        #expect(code(.browserClick, ["target": .string("e1"), "button": .string("thumb")]) == .invalidParams)
        #expect(code(.sessionGet, [:]) == .unknownMethod)
        #expect(code(.browserScreenshot, ["target": .string("e1"), "fullPage": .bool(true)]) == .invalidParams)
        #expect(code(.browserType, ["target": .string("e1"), "text": .string(String(repeating: "x", count: 201)),
                                    "slowly": .bool(true)]) == .invalidParams, "slowly is for short texts")
        #expect(code(.browserResize, ["width": .number(100)]) == .invalidParams)
        #expect(code(.browserFileUpload, ["paths": .array([.string("relative.png")])]) == .invalidParams)
        #expect(code(.browserFillForm, ["fields": .array([])]) == .invalidParams)
        #expect(code(.browserFillForm, ["fields": .array([.object(["name": .string("X"), "type": .string("checkbox"),
                                                                   "target": .string("e1"), "value": .string("yes")])])])
                == .invalidParams, "a checkbox takes true or false")
        #expect(code(.browserFillForm, ["fields": .array([.object(["name": .string("X"), "type": .string("date"),
                                                                   "target": .string("e1"), "value": .string("x")])])])
                == .invalidParams)
    }

    @Test("a set width is a page zoom: the CSS width shown in the view's points")
    func largeurDePage() {
        #expect(ViewportWidth.fit.zoom(forViewWidth: 640) == 1)
        #expect(ViewportWidth.css(1_280).zoom(forViewWidth: 640) == 0.5)
        #expect(ViewportWidth.css(375).zoom(forViewWidth: 750) == 2)
        #expect(ViewportWidth.css(1_280).zoom(forViewWidth: 0) == 1, "no view yet: no zoom")
        #expect(ViewportWidth.presets.first == .fit)
    }

    @Test("every command fits its method's deadline at its validation maximum")
    func budgetsTenus() throws {
        let wait = try #require(APIMethod.browserWaitFor.appDeadline)
        #expect(wait >= .seconds(Int(AgentCommand.maxWait)) + .seconds(3))
        let navigate = try #require(APIMethod.browserNavigate.appDeadline)
        #expect(navigate >= .seconds(33), "a 30 s load, then the snapshot")
    }

    @Test("errors and results cross to the API's shapes")
    func passageALAPI() {
        #expect(AgentError.timeout("slow").apiError.code == .timeout)
        #expect(AgentError.conflict("dialog").apiError.code == .conflict)
        #expect(AgentError.notFound("e9").apiError.code == .notFound)
        let image = AgentImage(url: URL(fileURLWithPath: "/tmp/a.png"), mimeType: "image/png", width: 10, height: 20)
        let content = AgentResult(text: "### Result", image: image).apiContent
        #expect(content == APIToolContent(text: "### Result",
                                          image: APIImageRef(path: "/tmp/a.png", mimeType: "image/png",
                                                             width: 10, height: 20)))
    }
}

@Suite("Agent browser — evaluate")
struct AgentEvaluateTests {

    @Test("functions pass as they are; an expression is wrapped into one")
    func fonctionOuExpression() {
        #expect(AgentScripts.isFunction("() => document.title"))
        #expect(AgentScripts.isFunction("(el) => el.textContent"))
        #expect(AgentScripts.isFunction("el => el.value"))
        #expect(AgentScripts.isFunction("async () => 1"))
        #expect(AgentScripts.isFunction("function () { return 1 }"))
        #expect(!AgentScripts.isFunction("document.title"))
        #expect(!AgentScripts.isFunction("items.map(x => x.id)"))
        #expect(AgentScripts.evaluateBody(function: "document.title").contains("() => (\ndocument.title\n)"))
    }
}

@Suite("Agent browser — uploads")
struct AgentUploadPolicyTests {

    private let policy = AgentUploadPolicy(roots: [URL(fileURLWithPath: "/work/app"),
                                                  URL(fileURLWithPath: "/support/agent-browser/uploads/s1")])

    private func files(_ existing: Set<String>, folders: Set<String> = []) -> (URL) -> (exists: Bool, isDirectory: Bool) {
        { url in (existing.contains(url.path) || folders.contains(url.path), folders.contains(url.path)) }
    }

    @Test("files under the roots pass; anything else is said plainly")
    func racines() {
        let probe = files(["/work/app/fixtures/a.png", "/etc/hosts", "/work/application/x"], folders: ["/work/app/src"])
        #expect(policy.validate(["/work/app/fixtures/a.png"], allowsMultiple: false, exists: probe)
                == .success([URL(fileURLWithPath: "/work/app/fixtures/a.png")]))
        #expect(policy.validate(["/etc/hosts"], allowsMultiple: false, exists: probe) == .failure(.outside("/etc/hosts")))
        #expect(policy.validate(["/work/application/x"], allowsMultiple: false, exists: probe)
                == .failure(.outside("/work/application/x")), "a sibling sharing the prefix is outside")
        #expect(policy.validate(["/work/app/src"], allowsMultiple: false, exists: probe) == .failure(.directory("/work/app/src")))
        #expect(policy.validate(["/work/app/nope"], allowsMultiple: false, exists: probe) == .failure(.missing("/work/app/nope")))
        #expect(policy.validate(["/work/app/../../etc/hosts"], allowsMultiple: false, exists: probe)
                == .failure(.outside("/work/app/../../etc/hosts")), "dot-dot resolved first")
    }

    @Test("several files only where the input takes several")
    func plusieurs() {
        let probe = files(["/work/app/a", "/work/app/b"])
        #expect(policy.validate(["/work/app/a", "/work/app/b"], allowsMultiple: false, exists: probe) == .failure(.tooMany))
        #expect(policy.validate(["/work/app/a", "/work/app/b"], allowsMultiple: true, exists: probe)
                == .success([URL(fileURLWithPath: "/work/app/a"), URL(fileURLWithPath: "/work/app/b")]))
    }
}

@Suite("Agent browser — local sites only")
struct AgentNetworkRulesTests {

    private func rules(_ hosts: String = "") throws -> [[String: Any]] {
        let json = AgentNetworkRules.json(allowedHosts: AgentNetworkRules.parse(hosts).hosts)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func filters(_ rules: [[String: Any]]) -> [String] {
        rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    }

    private func allowed(_ url: String, by rules: [[String: Any]]) -> Bool {
        // WebKit's semantics: the last matching rule wins.
        var blocked = false
        for rule in rules {
            guard let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String,
                  url.range(of: filter, options: .regularExpression) != nil else { continue }
            blocked = ((rule["action"] as? [String: Any])?["type"] as? String) == "block"
        }
        return !blocked
    }

    @Test("everything remote is blocked, the machine's own addresses are not")
    func boucleLocaleSeulement() throws {
        let list = try rules()
        #expect(Array(filters(list).prefix(2)) == ["^https?://", "^wss?://"])
        #expect(!filters(list).contains { $0.contains("|") }, "WebKit's url-filter has no alternation")
        for url in ["http://localhost:5173/", "http://127.0.0.1:8000/api", "ws://localhost:5173/hmr",
                    "http://app.localhost:3000/", "http://[::1]:5173/", "https://localhost/"] {
            #expect(allowed(url, by: list), "\(url)")
        }
        for url in ["https://example.com/", "http://localhost.evil.com/", "https://evil.com/?localhost:",
                    "wss://example.com/socket", "http://localhost:5173@evil.com/", "http://localhost@evil.com/",
                    "http://x.localhost:1@evil.com/", "http://127.0.0.1.evil.com/"] {
            #expect(!allowed(url, by: list), "\(url)")
        }
        #expect(allowed("data:text/html,x", by: list), "inline content is not a network load")
    }

    @Test("allowed hosts open exactly what they name")
    func hotesAutorises() throws {
        let list = try rules("api.example.com, *.staging.dev")
        #expect(allowed("https://api.example.com/v1", by: list))
        #expect(allowed("https://eu.staging.dev/", by: list))
        #expect(!allowed("https://staging.dev/", by: list), "a wildcard excludes its own domain")
        #expect(!allowed("https://api.example.com.evil.net/", by: list))
        #expect(!allowed("https://example.com/", by: list))
        #expect(AgentNetworkRules.parse("ok.dev, *, 10.0.0.1").invalid == ["*", "10.0.0.1"])
        #expect(!allowed("https://api.example.com:8443@evil.com/", by: list), "a user name is not the host")
        #expect(allowed("https://api.example.com:8443/v1", by: list))
    }

    @Test("navigations in local-only mode: the machine, the allowed hosts, about:blank")
    func navigationsLocales() throws {
        let hosts = AgentNetworkRules.parse("api.example.com").hosts
        for url in ["http://localhost:5173/", "http://127.0.0.1:8000/", "http://[::1]:3000/", "about:blank",
                    "https://api.example.com/login"] {
            #expect(AgentNetworkRules.allows(URL(string: url), allowedHosts: hosts), "\(url)")
        }
        for url in ["https://example.com/", "http://localhost:5173@evil.com/", "https://api.example.com.evil.net/"] {
            #expect(!AgentNetworkRules.allows(URL(string: url), allowedHosts: hosts), "\(url)")
        }
        #expect(!AgentNetworkRules.allows(nil, allowedHosts: hosts))
    }

    @Test("local-only refuses network addresses only: an inline frame loads nothing")
    func cadresEnLigne() {
        let access = AgentNetworkAccess.localOnly(allowedHosts: [])
        for url in ["data:text/html,<p>preview</p>", "blob:http://localhost:5173/6f1e", "about:srcdoc", "about:blank"] {
            #expect(!AgentNetworkRules.refuses(URL(string: url), under: access), "\(url)")
        }
        #expect(AgentNetworkRules.refuses(URL(string: "https://example.com/"), under: access))
        #expect(AgentNetworkRules.refuses(URL(string: "WSS://example.com/socket"), under: access))
        #expect(!AgentNetworkRules.refuses(URL(string: "https://example.com/"), under: .open))
    }
}
