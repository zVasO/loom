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
                == .type(AgentTarget(target: "#name"), text: "Ada", submit: true))
        #expect(try command(.browserPressKey, ["key": .string("Enter")]) == .pressKey(try KeySpec.parse("Enter")))
        #expect(try command(.browserTabs, ["action": .string("select"), "index": .number(1)]) == .tabs(.select(1)))
        #expect(try command(.browserConsole, [:]) == .console(level: .info, all: false))
        #expect(try command(.browserSnapshot, ["depth": .number(2)]) == .snapshot(target: nil, depth: 2))
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
