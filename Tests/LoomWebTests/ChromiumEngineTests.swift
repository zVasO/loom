import Testing
import CoreGraphics
import Foundation
import LoomAPI
import Network
@testable import LoomWeb

// The Chromium engine's commands, facade and surface (ADR-0016): its pure
// rules (viewport, live tabs, which addresses a page may show, how a failed
// load reads), the facade where no page exists yet — none of which launches
// Chromium — and, with LOOM_CHROMIUM pointing at a binary, a real session
// against a page served here.

private func uniqueDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("loom-\(name)-" + UUID().uuidString, isDirectory: true)
}

@MainActor
private func environment(in root: URL) -> AgentBrowser.Environment {
    AgentBrowser.Environment(screenshotsDirectory: root.appendingPathComponent("shots", isDirectory: true),
                             initialViewport: CGSize(width: 1_000, height: 800))
}

/// The command's error message, or what it answered instead.
@MainActor
private func failure(of command: AgentCommand, on browser: ChromiumAgentBrowser) async -> String {
    do {
        let answer = try await browser.run(command, deadline: ContinuousClock.now + .seconds(10))
        return "answered: " + answer.text
    } catch let error as AgentError {
        return error.message
    } catch {
        return "\(error)"
    }
}

@Suite("Chromium engine — its rules")
struct ChromiumEngineRulesTests {

    @Test("Fit is the panel's page area; a set width keeps the panel's aspect")
    func largeurs() {
        let initial = CGSize(width: 900, height: 900)
        #expect(ChromiumAgentCore.cssViewport(width: .fit, panel: CGSize(width: 600, height: 800), initial: initial)
                == CGSize(width: 600, height: 800))
        #expect(ChromiumAgentCore.cssViewport(width: .fit, panel: CGSize(width: 600.7, height: 800.4), initial: initial)
                == CGSize(width: 600, height: 800))
        #expect(ChromiumAgentCore.cssViewport(width: .fit, panel: nil, initial: initial) == initial)
        #expect(ChromiumAgentCore.cssViewport(width: .css(1_280), panel: CGSize(width: 640, height: 480), initial: initial)
                == CGSize(width: 1_280, height: 960))
        #expect(ChromiumAgentCore.cssViewport(width: .css(1_280), panel: nil, initial: CGSize(width: 640, height: 900))
                == CGSize(width: 1_280, height: 1_800))
    }

    @Test("At most three live tabs: the least recently used go first, never a kept one")
    func ongletsVivants() {
        let ids = (0..<4).map { _ in BrowserTabsModel.TabID(rawValue: UUID()) }
        let all = Set(ids)
        #expect(ChromiumAgentCore.releaseCandidates(usage: ids, live: all, keeping: [ids[3]], limit: 3) == [ids[0]])
        #expect(ChromiumAgentCore.releaseCandidates(usage: ids, live: all, keeping: [ids[0], ids[3]], limit: 3)
                == [ids[1]])
        #expect(ChromiumAgentCore.releaseCandidates(usage: ids, live: Set(ids.prefix(3)), keeping: [], limit: 3).isEmpty)
        let two = ChromiumAgentCore.releaseCandidates(usage: ids, live: all, keeping: [], limit: 2)
        #expect(two == [ids[0], ids[1]])
        // A live tab the usage order never saw goes after the ones it did.
        let unseen = ChromiumAgentCore.releaseCandidates(usage: Array(ids.prefix(3)), live: all, keeping: [ids[0]],
                                                         limit: 2)
        #expect(unseen == [ids[1], ids[2]])
    }

    @Test("A main frame shows http(s) and about:blank only; Chromium's error page is left alone")
    func adressesDuCadrePrincipal() {
        for refused in ["file:///etc/hosts", "data:text/html,<p>x</p>", "blob:http://localhost:3000/8f2c",
                        "chrome://version", "javascript:alert(1)", "view-source:http://localhost/"] {
            #expect(ChromiumCoreRouter.refusesMainFrame(refused), "\(refused)")
        }
        for shown in ["https://example.com/a?b#c", "http://localhost:5173/", "about:blank",
                      "chrome-error://chromewebdata/", ""] {
            #expect(!ChromiumCoreRouter.refusesMainFrame(shown), "\(shown)")
        }
    }

    @Test("A popup opens empty, on about:blank, or on an address the network setting allows")
    func popups() {
        #expect(ChromiumCoreRouter.admitsPopup(url: "", access: .open))
        #expect(ChromiumCoreRouter.admitsPopup(url: "about:blank", access: .open))
        #expect(ChromiumCoreRouter.admitsPopup(url: "https://accounts.example.com/oauth", access: .open))
        #expect(!ChromiumCoreRouter.admitsPopup(url: "file:///etc/hosts", access: .open))
        #expect(!ChromiumCoreRouter.admitsPopup(url: "javascript:alert(1)", access: .open))
        #expect(!ChromiumCoreRouter.admitsPopup(url: "data:text/html,x", access: .open))
        #expect(!ChromiumCoreRouter.admitsPopup(url: "https://example.com/", access: .localOnly(allowedHosts: [])))
        #expect(ChromiumCoreRouter.admitsPopup(url: "http://localhost:5173/", access: .localOnly(allowedHosts: [])))
    }

    @Test("Schemes other than http(s) and about:blank are refused before Chromium is asked")
    func schemas() {
        for address in ["file:///etc/hosts", "data:text/html,x", "javascript:alert(1)", "chrome://version"] {
            let url = URL(string: address)!
            #expect(throws: AgentError.self, "\(address)") { try ChromiumAgentCore.refuseScheme(url) }
        }
        for address in ["https://example.com/", "http://127.0.0.1:8080/x", "about:blank"] {
            let url = URL(string: address)!
            #expect(throws: Never.self, "\(address)") { try ChromiumAgentCore.refuseScheme(url) }
        }
    }

    @Test("Failed loads read as the WebKit engine says them; a cancelled load is no failure")
    func echecsDeChargement() {
        let auth = ChromiumAgentCore.loadFailure(errorText: "net::ERR_INVALID_AUTH_CREDENTIALS",
                                                 url: URL(string: "http://intranet.test/"), localOnly: false)
        #expect(auth?.contains("intranet.test asks for a sign-in") == true, "\(auth ?? "nil")")
        let refused = ChromiumAgentCore.loadFailure(errorText: "net::ERR_CONNECTION_REFUSED",
                                                    url: URL(string: "http://localhost:9/"), localOnly: false)
        #expect(refused == "nothing is listening on localhost:9 — is the dev server running?", "\(refused ?? "nil")")
        #expect(ChromiumAgentCore.loadFailure(errorText: "net::ERR_ABORTED", url: URL(string: "http://localhost/"),
                                              localOnly: false) == nil)
    }

    @Test("Accept-Language follows the system's first three languages")
    func langues() {
        #expect(ChromiumAgentCore.acceptLanguage(["fr-FR", "en-US"]) == "fr-FR,fr,en-US,en")
        #expect(ChromiumAgentCore.acceptLanguage(["en"]) == "en")
        #expect(ChromiumAgentCore.acceptLanguage([]) == "en-US,en")
        #expect(ChromiumAgentCore.acceptLanguage(["de-DE", "de-AT", "en-GB", "ja-JP"]) == "de-DE,de,de-AT,en-GB,en")
    }

    @Test("The activity pill and the key names use the WebKit engine's words")
    func libelles() throws {
        let target = AgentTarget(target: "e3", element: "Save button")
        #expect(ChromiumAgentCore.summary(of: .click(target, doubleClick: false, button: .left, modifiers: []))
                == "Clicking Save button [ref=e3]")
        #expect(ChromiumAgentCore.summary(of: .resize(.css(1_280))) == "Setting the page width: 1280 px")
        #expect(ChromiumAgentCore.described(AgentTarget(target: "#go"), "button \"Go\"") == "button \"Go\"")
        #expect(ChromiumAgentCore.keyName(try KeySpec.parse("Shift+Tab")) == "Shift+Tab")
        #expect(ChromiumAgentCore.keyName(try KeySpec.parse("ControlOrMeta+a")) == "Meta+a")
        #expect(ChromiumAgentCore.keyName(try KeySpec.parse("Space")) == "Space")
    }
}

@Suite("Chromium engine — the facade before any page")
struct ChromiumEngineFacadeTests {

    /// A pool on a binary that does not exist: nothing here may launch it.
    @MainActor
    private func makeBrowser(_ root: URL) -> ChromiumAgentBrowser {
        ChromiumAgentBrowser.standalone(executablePath: root.appendingPathComponent("no-chrome-headless-shell").path,
                                        root: root, environment: environment(in: root))
    }

    @Test("It is the Chromium engine, and the panel shows its surface")
    @MainActor
    func moteur() async {
        let root = uniqueDirectory("chromium-facade")
        let browser = makeBrowser(root)
        #expect(browser.engine == .chromium)
        if case .chromium(let surface) = browser.panelContent {
            #expect(surface === browser.surface)
        } else {
            Issue.record("the panel content is not Chromium's")
        }
        #expect(browser.activity == nil)
        await browser.shutDown()
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Commands with no page answer as the WebKit engine does, without launching Chromium")
    @MainActor
    func sansPage() async throws {
        let root = uniqueDirectory("chromium-facade")
        let browser = makeBrowser(root)
        let snapshot = await failure(of: .snapshot(target: nil, depth: nil), on: browser)
        #expect(snapshot == "No page is open yet — start with browser_navigate", "\(snapshot)")
        let tabs = try await browser.run(.tabs(.list), deadline: ContinuousClock.now + .seconds(10))
        #expect(tabs.text == "### Open tabs\nNo tab is open.", "\(tabs.text)")
        let select = await failure(of: .tabs(.select(0)), on: browser)
        #expect(select == "no tab 0: there are 0", "\(select)")
        let dialog = await failure(of: .handleDialog(accept: true, promptText: nil), on: browser)
        #expect(dialog == "no dialog is open", "\(dialog)")
        let closed = try await browser.run(.close, deadline: ContinuousClock.now + .seconds(10))
        #expect(closed.text.contains("Closed every tab"), "\(closed.text)")
        let resized = try await browser.run(.resize(.css(1_280)), deadline: ContinuousClock.now + .seconds(10))
        #expect(resized.text == "### Result\nThe page is 1280 CSS pixels wide, scaled into the panel; it applies to the next page.",
                "\(resized.text)")
        // The facade follows the core's state, applied on main in order.
        for _ in 0..<100 where browser.viewportWidth != .css(1_280) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(browser.viewportWidth == .css(1_280))
        #expect(browser.surface.viewport.width == 1_280)
        await browser.shutDown()
        try? FileManager.default.removeItem(at: root)
    }

    @Test("A file:, javascript: or local-only refused address never reaches Chromium")
    @MainActor
    func adressesRefusees() async {
        let root = uniqueDirectory("chromium-facade")
        let browser = makeBrowser(root)
        let file = await failure(of: .navigate(URL(string: "file:///etc/hosts")!), on: browser)
        #expect(file == "the agent's browser opens http(s) addresses only, not file:", "\(file)")
        let script = await failure(of: .tabs(.new(URL(string: "javascript:alert(1)")!)), on: browser)
        #expect(script.contains("http(s) addresses only"), "\(script)")
        browser.setNetworkAccess(.localOnly(allowedHosts: []))
        let outside = await failure(of: .navigate(URL(string: "https://example.com/")!), on: browser)
        #expect(outside.hasPrefix("example.com is outside local sites only"), "\(outside)")
        await browser.shutDown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Chromium engine — a real session (LOOM_CHROMIUM)",
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_CHROMIUM"].map { !$0.isEmpty } ?? false))
struct ChromiumEngineSessionTests {

    static let page = """
        <!doctype html>
        <html><head><title>Engine test</title></head>
        <body>
        <h1>Engine test</h1>
        <label>Name <input id="name"></label>
        <button id="go">Go</button>
        <p id="out">waiting</p>
        <script>
        window.clicks = [];
        document.getElementById('go').addEventListener('click', (event) => {
          window.clicks.push(event.isTrusted);
          document.getElementById('out').textContent = 'clicked ' + window.clicks.length;
        });
        </script>
        </body></html>
        """

    @Test("Navigate, click, type and snapshot on a real Chromium; the clicks are trusted")
    @MainActor
    func boutEnBout() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOOM_CHROMIUM"])
        let server = TestPageServer(page: Data(Self.page.utf8))
        let started = await server.start()
        let port = try #require(started, "the test page could not be served on 127.0.0.1")
        defer { server.stop() }
        let root = uniqueDirectory("chromium-session")
        let browser = ChromiumAgentBrowser.standalone(executablePath: path, root: root.appendingPathComponent("chromium"),
                                                      environment: environment(in: root))
        func send(_ command: AgentCommand, _ options: AgentCommandOptions = AgentCommandOptions()) async throws -> String {
            try await browser.run(command, options: options, deadline: ContinuousClock.now + .seconds(30)).text
        }
        let go = AgentTarget(target: "#go", element: "Go button")
        do {
            let opened = try await send(.navigate(URL(string: "http://127.0.0.1:\(port)/")!))
            #expect(opened.contains("Navigated to http://127.0.0.1:\(port)/"), "\(opened)")
            #expect(opened.contains("### Snapshot") && opened.contains("heading \"Engine test\""), "\(opened)")

            let clicked = try await send(.click(go, doubleClick: false, button: .left, modifiers: []))
            #expect(clicked.contains("Clicked Go button") && clicked.contains("clicked 1"), "\(clicked)")

            let quiet = try await send(.click(go, doubleClick: false, button: .left, modifiers: []),
                                       AgentCommandOptions(snapshot: .none))
            #expect(!quiet.contains("### Snapshot") && quiet.contains("### Page"), "\(quiet)")

            let typed = try await send(.type(AgentTarget(target: "#name"), text: "Ada", submit: false, slowly: false))
            #expect(typed.contains("Typed into"), "\(typed)")
            let value = try await send(.evaluate(function: "() => document.getElementById('name').value", target: nil))
            #expect(value.contains("\"Ada\""), "\(value)")

            let trusted = try await send(.evaluate(function: "() => window.clicks.join(',')", target: nil))
            #expect(trusted.contains("\"true,true\""), "\(trusted)")

            let snapshot = try await send(.snapshot(target: nil, depth: nil))
            #expect(snapshot.contains("### Snapshot") && snapshot.contains("clicked 2"), "\(snapshot)")
            #expect(!snapshot.contains("Visibility: hidden"), "\(snapshot)")
        } catch {
            Issue.record("\(error)")
        }
        await browser.shutDown()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Serves one page on 127.0.0.1 — any other path is a JSON 404.
private final class TestPageServer: @unchecked Sendable {
    private let page: Data
    private let queue = DispatchQueue(label: "app.loom.tests.chromium-engine")
    private var listener: NWListener?

    init(page: Data) {
        self.page = page
    }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [page] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let isPage = path == "/" || path.hasPrefix("/?")
            let body = isPage ? page : Data("{}".utf8)
            let head = "HTTP/1.1 \(isPage ? "200 OK" : "404 Not Found")\r\n"
                + "Content-Type: \(isPage ? "text/html; charset=utf-8" : "application/json")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
