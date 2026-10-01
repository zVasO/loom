import AppKit
import Foundation
import Network

/// The agent's browser against real WebKit (ADR-0014): `LOOM_AUTOTEST=agent-browser
/// swift run LoomApp` serves the fixture page of `Tests/AgentBrowserJS/fixtures/`
/// on 127.0.0.1, drives it through the same commands the agent sends, writes a
/// report and exits non-zero on any failure. What `swift test` cannot do: WebKit
/// needs a running app.
@MainActor
public enum AgentBrowserSelfTest {

    public struct Step: Codable {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    /// Runs every step; the report goes to `reportPath`. True when all passed.
    public static func run(fixturesDirectory: URL, reportPath: String) async -> Bool {
        var steps: [Step] = []
        func record(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append(Step(name: name, ok: ok, detail: String(detail.prefix(2_000))))
        }
        guard let html = try? Data(contentsOf: fixturesDirectory.appendingPathComponent("todo.html")) else {
            record("fixture", false, "todo.html not found in \(fixturesDirectory.path)")
            return write(steps, to: reportPath)
        }
        let server = FixtureServer(page: html)
        guard let port = await server.start() else {
            record("server", false, "the fixture server could not listen on 127.0.0.1")
            return write(steps, to: reportPath)
        }
        defer { server.stop() }
        let shots = FileManager.default.temporaryDirectory.appendingPathComponent("loom-agent-selftest-shots")
        let uploads = FileManager.default.temporaryDirectory.appendingPathComponent("loom-agent-selftest-uploads")
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let photo = uploads.appendingPathComponent("photo.png")
        FileManager.default.createFile(atPath: photo.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let browser = AgentBrowser(profile: .private, environment: .init(
            screenshotsDirectory: shots, initialViewport: CGSize(width: 900, height: 900), uploadRoots: [uploads]))
        let base = "http://127.0.0.1:\(port)"

        func send(_ command: AgentCommand, seconds: Int = 30) async -> Result<AgentResult, Error> {
            do {
                return .success(try await browser.run(command, deadline: ContinuousClock.now + .seconds(seconds)))
            } catch {
                return .failure(error)
            }
        }
        func text(_ result: Result<AgentResult, Error>) -> String {
            switch result {
            case .success(let answer): return answer.text
            case .failure(let error): return "ERROR \(error)"
            }
        }
        func ref(_ yaml: String, _ pattern: String) -> String? {
            // Lines with a ref only: a label's text line names the same words.
            guard let line = yaml.split(separator: "\n").first(where: {
                      $0.contains("[ref=") && $0.range(of: pattern, options: .regularExpression) != nil }),
                  let range = line.range(of: #"\[ref=(e\d+)\]"#, options: .regularExpression) else { return nil }
            return String(line[range].dropFirst(5).dropLast())
        }
        /// The page's own answer only — the ```json block, not the ### Page
        /// section Swift writes around it.
        func evaluate(_ function: String) async -> String {
            let answer = text(await send(.evaluate(function: function, target: nil)))
            guard let open = answer.range(of: "```json\n"),
                  let close = answer.range(of: "\n```", range: open.upperBound..<answer.endIndex) else { return answer }
            return String(answer[open.upperBound..<close.lowerBound])
        }

        // 1. Navigate: the page loads, the snapshot names it.
        let opened = text(await send(.navigate(URL(string: base + "/todo")!)))
        record("navigate", opened.contains("heading \"Todos\" [level=1]") && opened.contains("### Page"), opened)

        // 2. Type into the framework-style input and submit through the form.
        let snapshot = text(await send(.snapshot(target: nil, depth: nil)))
        if let field = ref(snapshot, #"textbox "New todo""#) {
            let typed = text(await send(.type(AgentTarget(target: field), text: "milk", submit: true, slowly: false)))
            let todos = await evaluate("() => window.state.todos.map(t => t.text)")
            record("type + submit", todos.contains("\"milk\""), typed + "\n" + todos)
            let keys = await evaluate("() => window.events")
            record("legacy keyCode reaches the page", keys.contains("keydown:Enter:13"), keys)
        } else {
            record("type + submit", false, "no textbox \"New todo\" in:\n" + snapshot)
        }

        // 3. A click that opens confirm(): modal state, then answered.
        let fresh = text(await send(.snapshot(target: nil, depth: nil)))
        if let clear = ref(fresh, #"button "Clear done""#) {
            let clicked = text(await send(.click(AgentTarget(target: clear), doubleClick: false, button: .left, modifiers: [])))
            record("dialog becomes modal state", clicked.contains("### Modal state") && clicked.contains("confirm"), clicked)
            let answered = text(await send(.handleDialog(accept: false, promptText: nil)))
            let events = await evaluate("() => window.events")
            record("dialog answered", events.contains("kept") && !answered.contains("ERROR"), answered + "\n" + events)
        } else {
            record("dialog becomes modal state", false, "no button \"Clear done\"")
        }

        // 4. Console and network.
        let page = text(await send(.snapshot(target: nil, depth: nil)))
        if let boom = ref(page, #"button "Log an error""#), let remote = ref(page, #"button "Load remote""#) {
            _ = await send(.click(AgentTarget(target: boom), doubleClick: false, button: .left, modifiers: []))
            _ = await send(.click(AgentTarget(target: remote), doubleClick: false, button: .left, modifiers: []))
            _ = await send(.waitFor(time: nil, text: "HTTP 404", textGone: nil, timeout: 5))
            let console = text(await send(.console(level: .error, all: false)))
            record("console errors", console.contains("Something broke") && console.contains("uncaught in timer"), console)
            let network = text(await send(.network(filter: "missing")))
            record("network requests", network.contains("missing.json => [404]"), network)
        } else {
            record("console errors", false, "no buttons in:\n" + page)
        }

        // 5. Screenshot: a real PNG at the CSS size.
        switch await send(.screenshot(target: nil, format: .png, fullPage: false)) {
        case .success(let answer):
            let data = answer.image.flatMap { try? Data(contentsOf: $0.url) } ?? Data()
            let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            record("screenshot", png && (answer.image?.width ?? 0) <= 1_568 && (answer.image?.width ?? 0) > 0,
                   "\(answer.image.map { "\($0.width)×\($0.height) \($0.url.path)" } ?? "no image"), \(data.count) bytes")
        case .failure(let error):
            record("screenshot", false, "\(error)")
        }

        // 6. Evaluate on a target element.
        let again = text(await send(.snapshot(target: nil, depth: nil)))
        if let add = ref(again, #"button "Add""#) {
            let content = text(await send(.evaluate(function: "(el) => el.textContent", target: AgentTarget(target: add))))
            record("evaluate on an element", content.contains("\"Add\""), content)
            // 7. A ref the latest snapshot did not print does not resolve.
            let stale = text(await send(.click(AgentTarget(target: "e9999"), doubleClick: false, button: .left,
                                               modifiers: [])))
            record("unknown ref", stale.contains("not found"), stale)
        } else {
            record("evaluate on an element", false, "no button \"Add\"")
        }

        // 8. A page cannot open a local file in a new tab.
        _ = await evaluate("() => { window.open('file:///etc/hosts'); return true }")
        let tabs = text(await send(.tabs(.list)))
        record("no file: popup", !tabs.contains("file:"), tabs)

        // 9. Tab moves focus.
        _ = await evaluate("() => { document.getElementById('new').focus(); return true }")
        let pressed = text(await send(.pressKey(try! KeySpec.parse("Tab"))))
        record("Tab moves focus", pressed.contains("focus: button \"Add\""), pressed)

        // 10. A form in one call: text, a checkbox, an option, a slider.
        let form = text(await send(.snapshot(target: nil, depth: nil)))
        if let field = ref(form, #"textbox "New todo""#), let terms = ref(form, #"checkbox "I agree""#),
           let color = ref(form, #"combobox "Color""#), let volume = ref(form, #"slider "Volume""#) {
            let filled = text(await send(.fillForm([
                FormField(name: "New todo", kind: .textbox, target: AgentTarget(target: field), value: "eggs"),
                FormField(name: "Terms", kind: .checkbox, target: AgentTarget(target: terms), value: "true"),
                FormField(name: "Color", kind: .combobox, target: AgentTarget(target: color), value: "Blue"),
                FormField(name: "Volume", kind: .slider, target: AgentTarget(target: volume), value: "7"),
            ])))
            let values = await evaluate("""
                () => [document.getElementById('new').value, document.getElementById('terms').checked,
                       document.getElementById('color').value, document.getElementById('volume').value].join('|')
                """)
            record("fill form", values.contains("eggs|true|b|7"), filled + "\n" + values)
            // 11. One key at a time: the page's key handlers see each.
            _ = await evaluate("() => { window.events = []; return true }")
            _ = await send(.type(AgentTarget(target: field), text: "Hi", submit: false, slowly: true))
            let keys = await evaluate("() => window.events")
            record("type slowly", keys.contains("keydown:H:72") && keys.contains("keydown:i:73"), keys)
        } else {
            record("fill form", false, "missing fields in:\n" + form)
        }

        // 12. A laptop's width in a narrower view: the page sees 1280 CSS pixels.
        let wide = text(await send(.resize(.css(1_280))))
        let innerWidth = await evaluate("() => 'iw=' + window.innerWidth")
        record("resize", innerWidth.contains("\"iw=1280\"") && wide.contains("Viewport: 1280×"), wide + "\n" + innerWidth)
        _ = await send(.resize(.fit))

        // 13. The whole page: taller than the view, put back where it was.
        _ = await evaluate("() => { document.body.style.minHeight = '2400px'; window.scrollTo(0, 100); return true }")
        switch await send(.screenshot(target: nil, format: .png, fullPage: true)) {
        case .success(let answer):
            let tall = (answer.image?.height ?? 0) > (answer.image?.width ?? 0)
            let scrolled = await evaluate("() => 'sy=' + window.scrollY")
            record("full-page screenshot", tall && scrolled.contains("\"sy=100\""),
                   "\(answer.image.map { "\($0.width)×\($0.height)" } ?? "no image"), scrollY \(scrolled)")
        case .failure(let error):
            record("full-page screenshot", false, "\(error)")
        }

        // 14. A file chooser answered with a file the policy allows.
        let withPhoto = text(await send(.snapshot(target: nil, depth: nil)))
        if let input = ref(withPhoto, #"button "Photo""#) {
            let opened = text(await send(.click(AgentTarget(target: input), doubleClick: false, button: .left,
                                                modifiers: [])))
            let outside = text(await send(.fileUpload(paths: ["/etc/hosts"])))
            let chosen = text(await send(.fileUpload(paths: [photo.path])))
            let events = await evaluate("() => window.events")
            record("file upload", opened.contains("File chooser") && outside.contains("outside")
                   && events.contains("file:photo.png"), opened + "\n" + outside + "\n" + chosen + "\n" + events)
        } else {
            record("file upload", false, "no file input in:\n" + withPhoto)
        }

        browser.tearDown()
        try? FileManager.default.removeItem(at: uploads)
        return write(steps, to: reportPath)
    }

    private static func write(_ steps: [Step], to path: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(steps) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        return !steps.isEmpty && steps.allSatisfy(\.ok)
    }
}

/// Serves one page on 127.0.0.1 — every other path is a JSON 404, which the
/// fixture's "Load remote" button counts on.
private final class FixtureServer: @unchecked Sendable {
    private let page: Data
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.loom.agent-selftest")

    init(page: Data) {
        self.page = page
    }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let once = Once()
        return await withCheckedContinuation { continuation in
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
            let isPage = path == "/" || path.hasPrefix("/todo")
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

/// A continuation resumed once, whatever states follow.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}
