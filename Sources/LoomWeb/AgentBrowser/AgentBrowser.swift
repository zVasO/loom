import AppKit
import Foundation
import Observation
import WebKit

/// What the panel shows while the agent works.
public struct AgentActivity: Equatable, Sendable {
    public var summary: String
    public var isRunning: Bool
    public var at: Date
}

/// A session agent's own browser (ADR-0014): its tabs, on its profile's
/// store, with the page hook and the helper installed — the one browser in
/// Loom that runs scripts in pages. Commands run one at a time, each within
/// its deadline, and answer Markdown the agent reads like Playwright MCP's.
///
/// Every wait here can end without WebKit: a deadline, a dialog the page
/// blocks on, a navigation that wipes the page, a crashed process. Nothing
/// waits on a callback that may never come.
@MainActor
@Observable
public final class AgentBrowser: NSObject {

    public struct Environment: Sendable {
        /// Where screenshots are written — the MCP server reads them there.
        public var screenshotsDirectory: URL
        /// The size a web view gets before the panel ever shows it: never
        /// zero, so layout, hit tests and screenshots work off screen too.
        public var initialViewport: CGSize
        public var limits: AgentBrowserLimits

        public init(screenshotsDirectory: URL, initialViewport: CGSize,
                    limits: AgentBrowserLimits = AgentBrowserLimits()) {
            self.screenshotsDirectory = screenshotsDirectory
            self.initialViewport = initialViewport
            self.limits = limits
        }
    }

    public let controller: BrowserController
    public let profile: AgentBrowserProfile.Kind
    private let dataStore: WKWebsiteDataStore
    @ObservationIgnored public var environment: Environment

    /// What the agent is doing, or last did.
    public private(set) var activity: AgentActivity?
    /// The dialogs pages are blocked on, per tab — the panel's banner.
    public private(set) var dialogs: [BrowserTabsModel.TabID: AgentModalState] = [:]

    @ObservationIgnored private var answers: [BrowserTabsModel.TabID: DialogAnswer] = [:]
    @ObservationIgnored private var runtimes: [BrowserTabsModel.TabID: TabRuntime] = [:]
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private var running: Task<AgentResult, Error>?
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private var screenshotSequence = 0
    @ObservationIgnored private var messageProxy: AgentMessageProxy?

    /// Project stores whose leftovers (service workers, caches) were cleared
    /// in this run — once, before any page of any session uses them.
    private static var clearedStores: Set<UUID> = []

    /// The dialog the current tab is blocked on.
    public var activeDialog: AgentModalState? {
        controller.activeTab.flatMap { dialogs[$0] }
    }

    public init(profile: AgentBrowserProfile.Kind, environment: Environment) {
        self.profile = profile
        self.dataStore = AgentBrowserProfile.dataStore(for: profile)
        self.environment = environment
        self.controller = BrowserController(agentTabs: 3)
        super.init()
        controller.attach(engine: self)
        controller.onVisit = nil   // the agent's pages never enter the user's history
        messageProxy = AgentMessageProxy(owner: self)
    }

    // MARK: - Commands

    /// Runs `command` after the ones before it, within `deadline`.
    public func run(_ command: AgentCommand, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let previous = queueTail
        let generation = queueGeneration
        let job = Task<AgentResult, Error> { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { throw AgentError.unavailable("the browser was closed") }
            guard generation == self.queueGeneration else {
                throw AgentError.unavailable("the browser's commands were cancelled")
            }
            return try await self.runNow(command, deadline: deadline)
        }
        queueTail = Task { _ = try? await job.value }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Pending and running commands fail at once (the tools were turned off,
    /// the session ended).
    public func cancelAll(_ reason: String) {
        queueGeneration += 1
        running?.cancel()
        for tab in Array(runtimes.keys) {
            interruptCalls(tab, AgentInterruption.crashed)
        }
        activity = activity.map { AgentActivity(summary: reason, isRunning: false, at: $0.at) }
    }

    private func runNow(_ command: AgentCommand, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        activity = AgentActivity(summary: Self.summary(of: command), isRunning: true, at: Date())
        let window = controller.activeTab.flatMap { controller.webView(for: $0) }?.window
        let responder = window?.firstResponder
        let worker = Task<AgentResult, Error> { @MainActor in
            try await self.execute(command, deadline: deadline)
        }
        running = worker
        let timer = Task { @MainActor in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            worker.cancel()
        }
        defer {
            timer.cancel()
            running = nil
            activity = activity.map { AgentActivity(summary: $0.summary, isRunning: false, at: Date()) }
            restoreFocus(responder, in: window)
        }
        do {
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            if ContinuousClock.now >= deadline {
                throw AgentError.timeout("the command did not finish in time")
            }
            throw AgentError.unavailable("the command was cancelled")
        } catch let interruption as AgentInterruption {
            throw Self.error(for: interruption)
        }
    }

    /// The agent's actions must never leave the user's keystrokes going to
    /// the page: if a command moved the keyboard into the web view, it goes
    /// back where it was.
    private func restoreFocus(_ responder: NSResponder?, in window: NSWindow?) {
        guard let window, let current = window.firstResponder as? NSView,
              let tab = controller.activeTab, let webView = controller.webView(for: tab),
              current === webView || current.isDescendant(of: webView),
              let responder, responder !== current else { return }
        if let view = responder as? NSView, view === webView || view.isDescendant(of: webView) { return }
        window.makeFirstResponder(responder)
    }

    private func execute(_ command: AgentCommand, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        switch command {
        case .navigate(let url):
            return try await navigate(to: url, deadline: deadline)
        case .navigateBack:
            return try await navigateBack(deadline: deadline)
        case .snapshot(let target, let depth):
            return try await snapshot(target: target, depth: depth, deadline: deadline)
        case .click(let target, let doubleClick, let button, let modifiers):
            return try await act(on: target, readiness: "click", op: "click",
                                 args: ["target": target.target, "doubleClick": doubleClick,
                                        "button": button.rawValue, "modifiers": modifiers],
                                 verb: doubleClick ? "Double-clicked" : "Clicked", deadline: deadline)
        case .type(let target, let text, let submit):
            return try await act(on: target, readiness: "type", op: "type",
                                 args: ["target": target.target, "text": text, "submit": submit],
                                 verb: "Typed into", deadline: deadline)
        case .selectOption(let target, let values):
            return try await act(on: target, readiness: "select", op: "selectOption",
                                 args: ["target": target.target, "values": values],
                                 verb: "Selected \(values.joined(separator: ", ")) in", deadline: deadline)
        case .hover(let target):
            return try await act(on: target, readiness: "hover", op: "hover",
                                 args: ["target": target.target], verb: "Hovered", deadline: deadline)
        case .pressKey(let key):
            return try await pressKey(key, deadline: deadline)
        case .waitFor(let time, let text, let textGone, let timeout):
            return try await waitFor(time: time, text: text, textGone: textGone, timeout: timeout, deadline: deadline)
        case .screenshot(let target, let format):
            return try await screenshot(target: target, format: format, deadline: deadline)
        case .console(let level, let all):
            let (tab, webView) = try currentPage()
            let text = runtimes[tab]?.console.render(level: level, all: all, limit: environment.limits.consoleChars)
                ?? "No console messages."
            return respond(text, tab: tab, webView: webView, snapshot: nil)
        case .network(let filter):
            let (tab, webView) = try currentPage()
            let text = runtimes[tab]?.network.render(filter: filter, limit: environment.limits.networkChars)
                ?? "No requests since the page loaded."
            return respond(text, tab: tab, webView: webView, snapshot: nil)
        case .evaluate(let function, let target):
            return try await evaluate(function, target: target, deadline: deadline)
        case .handleDialog(let accept, let promptText):
            return try await handleDialog(accept: accept, promptText: promptText, deadline: deadline)
        case .tabs(let action):
            return try await tabs(action, deadline: deadline)
        case .close:
            for tab in controller.tabs { controller.close(tab.id) }
            return AgentResult(text: "### Result\nClosed every tab of the agent's browser. Its profile (cookies, storage) is kept.")
        }
    }

    // MARK: - Navigation

    private func navigate(to url: URL, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        await prepareStore()
        let tab: BrowserTabsModel.TabID
        if let active = controller.activeTab, controller.webView(for: active) != nil {
            tab = active
            if runtimes[tab]?.calls.inFlight ?? 0 > 0 {
                // A script from an earlier command never yielded: a fresh
                // process instead of queueing behind it.
                controller.load(url, in: tab)
                controller.recreateWebView(for: tab)
                note(tab, "The previous page was stuck in a script: it was replaced by a fresh one.")
            } else {
                let navigation = controller.load(url, in: tab)
                didRequestLoad(navigation, tab: tab)
            }
        } else {
            tab = controller.openTab(url: url)
        }
        guard let webView = controller.webView(for: tab) else {
            throw AgentError.unavailable("the page could not be opened")
        }
        try await waitForLoad(tab: tab, limit: .seconds(30), deadline: deadline)
        if let error = runtimes[tab]?.tracker.lastError { throw AgentError.failed(error) }
        try await waitForNetworkIdle(tab: tab, after: 0, limit: .seconds(2), deadline: deadline)
        try await pause(.milliseconds(300))
        return await respondWithSnapshot("Navigated to \(webView.url?.absoluteString ?? url.absoluteString)",
                                         tab: tab, webView: webView, deadline: deadline)
    }

    private func navigateBack(deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        guard webView.canGoBack else { throw AgentError.invalid("there is nothing to go back to") }
        let mark = navigationMark(tab)
        let navigation = webView.goBack()
        didRequestLoad(navigation, tab: tab)
        try await settle(after: mark, tab: tab, deadline: deadline)
        if let error = runtimes[tab]?.tracker.lastError { throw AgentError.failed(error) }
        return await respondWithSnapshot("Went back to \(webView.url?.absoluteString ?? "the previous page")",
                                         tab: tab, webView: webView, deadline: deadline)
    }

    // MARK: - Reading

    private func snapshot(target: String?, depth: Int?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        try refuseWhileDialog(tab)
        var args: [String: Any] = ["budget": environment.limits.snapshotChars]
        if let target { args["target"] = target }
        if let depth { args["depth"] = depth }
        let answer = try await helper("snapshot", args, tab: tab, webView: webView, deadline: deadline)
        return respond(nil, tab: tab, webView: webView, snapshot: answer["yaml"] as? String)
    }

    private func waitFor(time: Double?, text: String?, textGone: String?, timeout: Double,
                         deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        if let time, time > 0 { try await pause(.milliseconds(Int(time * 1000))) }
        var result = time.map { "Waited \($0) s" } ?? ""
        if text != nil || textGone != nil {
            let limit = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
            var args: [String: Any] = [:]
            if let text { args["text"] = text }
            if let textGone { args["textGone"] = textGone }
            while true {
                try refuseWhileDialog(tab)
                do {
                    let answer = try await helper("waitText", args, tab: tab, webView: webView,
                                                  deadline: min(deadline, ContinuousClock.now + .seconds(2)))
                    if answer["found"] as? Bool == true { break }
                } catch AgentInterruption.navigated {
                    // A new page: ask it again.
                } catch AgentInterruption.deadline {
                    // The page is busy (loading): ask again.
                }
                if ContinuousClock.now >= limit {
                    throw AgentError.timeout(text.map { "\"\($0)\" did not appear" }
                                             ?? "\"\(textGone ?? "")\" did not go away")
                }
                try await pause(.milliseconds(250))
            }
            result = text.map { "\"\($0)\" appeared" } ?? "\"\(textGone ?? "")\" went away"
        }
        return await respondWithSnapshot(result, tab: tab, webView: webView, deadline: deadline)
    }

    private func screenshot(target: AgentTarget?, format: ImageFormat,
                            deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        ensureFrame(webView)
        var rect: CGRect?
        var what = "the visible page"
        if let target, dialogs[tab] == nil {
            let answer = try await helper("rect", ["target": target.target], tab: tab, webView: webView,
                                          deadline: deadline)
            guard let box = answer["rect"] as? [String: Any],
                  let x = box["x"] as? Double, let y = box["y"] as? Double,
                  let width = box["width"] as? Double, let height = box["height"] as? Double,
                  width > 0, height > 0 else {
                throw AgentError.invalid("\(target.target) has no visible box to capture")
            }
            rect = CGRect(x: x, y: y, width: width, height: height).intersection(webView.bounds)
            what = answer["description"] as? String ?? target.target
        }
        let image = try await AgentScreenshot.capture(webView, rect: rect)
        let cssSize = rect?.size ?? webView.bounds.size
        let pixels = AgentScreenshot.targetSize(for: cssSize, maxEdge: environment.limits.imageMaxEdge)
        guard let data = AgentScreenshot.encode(image, pixels: pixels, format: format) else {
            throw AgentError.failed("the screenshot could not be encoded")
        }
        screenshotSequence += 1
        let url = try AgentScreenshot.write(data, in: environment.screenshotsDirectory,
                                            sequence: screenshotSequence, format: format)
        var result = respond("Screenshot of \(what), \(Int(pixels.width))×\(Int(pixels.height)), saved to \(url.path)."
                             + " Use browser_snapshot to act on the page.",
                             tab: tab, webView: webView, snapshot: nil)
        result.image = AgentImage(url: url, mimeType: format.mimeType, width: Int(pixels.width), height: Int(pixels.height))
        return result
    }

    // MARK: - Acting

    private func act(on target: AgentTarget, readiness: String, op: String, args: [String: Any],
                     verb: String, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        try refuseWhileDialog(tab)
        let ready = try await waitUntilActionable(target, action: readiness, tab: tab, webView: webView,
                                                  deadline: deadline)
        let described = Self.described(target, ready["description"] as? String)
        let mark = navigationMark(tab)
        do {
            _ = try await helper(op, args, tab: tab, webView: webView, deadline: deadline)
        } catch AgentInterruption.dialogOpened {
            // The action opened a dialog: the page now waits on it.
        } catch AgentInterruption.navigated {
            // The action navigated: the load is followed below.
        }
        try await settle(after: mark, tab: tab, deadline: deadline)
        return await respondWithSnapshot("\(verb) \(described)", tab: tab, webView: webView, deadline: deadline)
    }

    private func pressKey(_ key: KeySpec, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        try refuseWhileDialog(tab)
        let mark = navigationMark(tab)
        let args = (try? JSONEncoder().encode(key)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var focused = ""
        do {
            let answer = try await helper("pressKey", json: args, tab: tab, webView: webView, deadline: deadline)
            focused = answer["focused"] as? String ?? ""
        } catch AgentInterruption.dialogOpened {
        } catch AgentInterruption.navigated {
        }
        try await settle(after: mark, tab: tab, deadline: deadline)
        let name = Self.keyName(key)
        return await respondWithSnapshot("Pressed \(name)" + (focused.isEmpty ? "" : " — focus: \(focused)"),
                                         tab: tab, webView: webView, deadline: deadline)
    }

    /// Single-shot readiness checks, polled from here: timers in a hidden
    /// page are throttled, a Swift sleep is not. Ready twice in a row with
    /// the same box = stable (not mid-animation).
    private func waitUntilActionable(_ target: AgentTarget, action: String, tab: BrowserTabsModel.TabID,
                                     webView: WKWebView, deadline: ContinuousClock.Instant) async throws -> [String: Any] {
        let limit = min(deadline, ContinuousClock.now + .seconds(5))
        var previousBox: NSDictionary?
        var reason = "it is not ready"
        while true {
            let answer = try await helper("prepare", ["target": target.target, "action": action],
                                          tab: tab, webView: webView, deadline: deadline)
            let box = (answer["rect"] as? [String: Any]).map { NSDictionary(dictionary: $0) }
            if answer["status"] as? String == "ready" {
                if let box, let previousBox, box.isEqual(previousBox) { return answer }
                if action == "type" || action == "select" { return answer }
                previousBox = box
            } else {
                previousBox = nil
                reason = answer["reason"] as? String ?? reason
            }
            if ContinuousClock.now >= limit {
                throw AgentError.timeout("\(Self.described(target, nil)) is not ready to \(action): \(reason)")
            }
            try await pause(.milliseconds(80))
        }
    }

    private func evaluate(_ function: String, target: AgentTarget?,
                          deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        try refuseWhileDialog(tab)
        var nonce = ""
        if let target {
            let stamped = try await helper("stamp", ["target": target.target], tab: tab, webView: webView,
                                           deadline: deadline)
            nonce = stamped["nonce"] as? String ?? ""
        }
        let output: String
        do {
            output = try await callJS(webView, tab: tab, body: AgentScripts.evaluateBody(function: function),
                                      arguments: ["nonce": nonce], world: .page, deadline: deadline)
        } catch AgentInterruption.dialogOpened {
            return respond("The function opened a dialog; it is still waiting on it.", tab: tab, webView: webView,
                           snapshot: nil)
        }
        let limit = environment.limits.evaluateChars
        let shown = output.count > limit ? String(output.prefix(limit)) + "\n… (cut at \(limit) characters)" : output
        return respond("```json\n\(shown)\n```", tab: tab, webView: webView, snapshot: nil)
    }

    private func handleDialog(accept: Bool, promptText: String?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try currentPage()
        guard let answer = answers.removeValue(forKey: tab), let dialog = dialogs.removeValue(forKey: tab) else {
            throw AgentError.invalid("no dialog is open")
        }
        let mark = navigationMark(tab)
        answer.respond(accept: accept, text: promptText)
        try await settle(after: mark, tab: tab, deadline: deadline)
        let what: String
        switch dialog.kind {
        case .fileChooser: what = "Cancelled the file chooser"
        default: what = (accept ? "Accepted" : "Dismissed") + " the dialog \(AgentModalState.quoted(dialog.message))"
        }
        return await respondWithSnapshot(what, tab: tab, webView: webView, deadline: deadline)
    }

    private func tabs(_ action: TabsAction, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        switch action {
        case .list:
            let lines = tabSummaries().map { tab in
                "- \(tab.index): " + (tab.isCurrent ? "(current) " : "") + "[\(tab.title)] (\(tab.url))"
            }
            return AgentResult(text: "### Open tabs\n" + (lines.isEmpty ? "No tab is open." : lines.joined(separator: "\n")))
        case .new(let url):
            await prepareStore()
            let tab = controller.openTab(url: url ?? URL(string: "about:blank")!)
            guard let webView = controller.webView(for: tab) else { throw AgentError.unavailable("the tab could not open") }
            try await waitForLoad(tab: tab, limit: .seconds(30), deadline: deadline)
            return await respondWithSnapshot("Opened a new tab", tab: tab, webView: webView, deadline: deadline)
        case .select(let index):
            guard controller.tabs.indices.contains(index) else {
                throw AgentError.invalid("no tab \(index): there are \(controller.tabs.count)")
            }
            let id = controller.tabs[index].id
            controller.activate(id)
            guard let webView = controller.webView(for: id) else { throw AgentError.unavailable("the tab could not open") }
            if runtimes[id]?.calls.inFlight ?? 0 > 0 { controller.recreateWebView(for: id) }
            try await waitForLoad(tab: id, limit: .seconds(10), deadline: deadline)
            return await respondWithSnapshot("Selected tab \(index)", tab: id,
                                             webView: controller.webView(for: id) ?? webView, deadline: deadline)
        case .close(let index):
            let position = index ?? controller.tabs.firstIndex(where: { $0.id == controller.activeTab }) ?? -1
            guard controller.tabs.indices.contains(position) else { throw AgentError.invalid("no tab to close") }
            controller.close(controller.tabs[position].id)
            let lines = tabSummaries().map { "- \($0.index): " + ($0.isCurrent ? "(current) " : "") + "[\($0.title)] (\($0.url))" }
            return AgentResult(text: "### Result\nClosed tab \(position)\n\n### Open tabs\n"
                               + (lines.isEmpty ? "No tab is open." : lines.joined(separator: "\n")))
        }
    }

    // MARK: - Waiting

    private struct NavigationMark {
        var started: Int
        var network: Int
    }

    private func navigationMark(_ tab: BrowserTabsModel.TabID) -> NavigationMark {
        NavigationMark(started: runtimes[tab]?.tracker.startedCount ?? 0,
                       network: runtimes[tab]?.network.lastSequence ?? 0)
    }

    /// After an action: a moment for its effects to start, then the load it
    /// caused or the requests it made, then a moment for the page to paint —
    /// Playwright MCP's wait-for-completion.
    private func settle(after mark: NavigationMark, tab: BrowserTabsModel.TabID,
                        deadline: ContinuousClock.Instant) async throws {
        try await pause(.milliseconds(300))
        if dialogs[tab] != nil { return }
        let tracker = runtimes[tab]?.tracker
        if (tracker?.startedCount ?? 0) > mark.started || tracker?.isLoading == true {
            try await waitForLoad(tab: tab, limit: .seconds(10), deadline: deadline)
        } else {
            try await waitForNetworkIdle(tab: tab, after: mark.network, limit: .seconds(5), deadline: deadline)
        }
        try await pause(.milliseconds(150))
    }

    private func waitForLoad(tab: BrowserTabsModel.TabID, limit: Duration, deadline: ContinuousClock.Instant) async throws {
        let end = min(deadline - .seconds(1), ContinuousClock.now + limit)
        while ContinuousClock.now < end {
            if dialogs[tab] != nil { return }
            guard let tracker = runtimes[tab]?.tracker else { return }
            if tracker.isSettled(at: Self.clock()) { return }
            try await pause(.milliseconds(50))
        }
        if runtimes[tab]?.tracker.isLoading == true {
            note(tab, "The page was still loading when the wait ended.")
        }
    }

    private func waitForNetworkIdle(tab: BrowserTabsModel.TabID, after sequence: Int, limit: Duration,
                                    deadline: ContinuousClock.Instant) async throws {
        let end = min(deadline - .seconds(1), ContinuousClock.now + limit)
        while ContinuousClock.now < end {
            if dialogs[tab] != nil { return }
            if (runtimes[tab]?.network.inFlight(after: sequence) ?? 0) == 0 { return }
            try await pause(.milliseconds(50))
        }
    }

    private func pause(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private static func clock() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Talking to the page

    private func helper(_ op: String, _ args: [String: Any], tab: BrowserTabsModel.TabID, webView: WKWebView,
                        deadline: ContinuousClock.Instant) async throws -> [String: Any] {
        try await helper(op, json: AgentJS.json(args), tab: tab, webView: webView, deadline: deadline)
    }

    private func helper(_ op: String, json: String, tab: BrowserTabsModel.TabID, webView: WKWebView,
                        deadline: ContinuousClock.Instant) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let answer = try await callJS(webView, tab: tab, body: AgentScripts.helperCall,
                                          arguments: ["op": op, "args": json], world: AgentScripts.world,
                                          deadline: deadline)
            do {
                return try AgentJS.decode(answer)
            } catch is AgentJS.HelperMissing where attempt == 0 {
                try await injectHelper(webView, tab: tab, deadline: deadline)
            }
        }
        throw AgentError.failed("Loom's helper could not be loaded in this page")
    }

    /// A document the user script missed (the first, empty one): the helper
    /// is evaluated into the world directly. It answers `true`, never
    /// `undefined` (see AgentJS).
    private func injectHelper(_ webView: WKWebView, tab: BrowserTabsModel.TabID,
                              deadline: ContinuousClock.Instant) async throws {
        _ = try await callJS(webView, tab: tab, body: AgentScripts.helper + "\nreturn \"loaded\";",
                             arguments: [:], world: AgentScripts.world, deadline: deadline)
    }

    /// One script call, raced against everything that can end it without
    /// WebKit's answer.
    private func callJS(_ webView: WKWebView, tab: BrowserTabsModel.TabID, body: String,
                        arguments: [String: Any], world: WKContentWorld,
                        deadline: ContinuousClock.Instant) async throws -> String {
        let box = OneShot<String>()
        let key = ObjectIdentifier(box)
        let calls = runtimes[tab]?.calls
        runtimes[tab]?.pending[key] = box
        defer { runtimes[tab]?.pending[key] = nil }
        calls?.inFlight += 1
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            calls?.inFlight -= 1
            switch result {
            case .success(let value): box.resolve(.success(value as? String ?? "null"))
            case .failure(let error): box.resolve(.failure(AgentJS.mapped(error)))
            }
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            box.resolve(.failure(AgentInterruption.deadline))
        }
        defer { timer.cancel() }
        if dialogs[tab] != nil { box.resolve(.failure(AgentInterruption.dialogOpened)) }
        return try await box.value()
    }

    private func interruptCalls(_ tab: BrowserTabsModel.TabID, _ reason: AgentInterruption) {
        for box in runtimes[tab]?.pending.values.map({ $0 }) ?? [] {
            box.resolve(.failure(reason))
        }
    }

    private static func error(for interruption: AgentInterruption) -> AgentError {
        switch interruption {
        case .deadline: return .timeout("the page did not answer in time")
        case .dialogOpened: return .conflict("a dialog is open: answer it with browser_handle_dialog")
        case .navigated: return .failed("the page navigated away during the command")
        case .crashed: return .unavailable("the page's process stopped; it is being reloaded")
        }
    }

    // MARK: - Answers

    private func currentPage() throws -> (BrowserTabsModel.TabID, WKWebView) {
        guard let tab = controller.activeTab else {
            throw AgentError.unavailable("No page is open yet — start with browser_navigate")
        }
        controller.materialize()
        guard let webView = controller.webView(for: tab) else {
            throw AgentError.unavailable("the page is not loaded — call browser_navigate")
        }
        ensureFrame(webView)
        return (tab, webView)
    }

    private func refuseWhileDialog(_ tab: BrowserTabsModel.TabID) throws {
        if dialogs[tab] != nil {
            throw AgentError.conflict("a dialog is open: answer it with browser_handle_dialog first")
        }
    }

    /// Never zero: a web view the panel never showed still lays out, hit-tests
    /// and draws at the size it will most likely have.
    private func ensureFrame(_ webView: WKWebView) {
        if webView.superview == nil, webView.frame.isEmpty {
            webView.frame = CGRect(origin: .zero, size: environment.initialViewport)
        }
    }

    private func respondWithSnapshot(_ result: String, tab: BrowserTabsModel.TabID, webView: WKWebView,
                                     deadline: ContinuousClock.Instant) async -> AgentResult {
        var yaml: String?
        if dialogs[tab] == nil, ContinuousClock.now < deadline - .milliseconds(500) {
            let answer = try? await helper("snapshot", ["budget": environment.limits.actionSnapshotChars],
                                           tab: tab, webView: webView, deadline: deadline - .milliseconds(300))
            yaml = answer?["yaml"] as? String
        }
        return respond(result, tab: tab, webView: webView, snapshot: yaml)
    }

    private func respond(_ result: String?, tab: BrowserTabsModel.TabID, webView: WKWebView,
                         snapshot: String?) -> AgentResult {
        let runtime = runtimes[tab]
        let counts = runtime?.console.counts ?? (0, 0)
        let hidden = webView.window == nil || !(webView.window?.occlusionState.contains(.visible) ?? false)
        let page = AgentPageSummary(url: webView.url?.absoluteString ?? controller.model.tab(tab)?.url.absoluteString ?? "",
                                    title: webView.title ?? "", httpStatus: runtime?.httpStatus,
                                    consoleErrors: counts.errors, consoleWarnings: counts.warnings,
                                    viewport: webView.bounds.size, hidden: hidden)
        let events = runtimes[tab]?.events ?? []
        runtimes[tab]?.events.removeAll()
        let text = AgentResponseBuilder.render(result: result, page: page, tabs: tabSummaries(),
                                               modal: dialogs[tab], snapshot: snapshot, events: events,
                                               limits: environment.limits)
        return AgentResult(text: text)
    }

    private func tabSummaries() -> [AgentTabSummary] {
        controller.tabs.enumerated().map { index, tab in
            AgentTabSummary(index: index, title: tab.title, url: tab.url.absoluteString,
                            isCurrent: tab.id == controller.activeTab, hasDialog: dialogs[tab.id] != nil)
        }
    }

    private func note(_ tab: BrowserTabsModel.TabID, _ event: String) {
        guard runtimes[tab] != nil else { return }
        runtimes[tab]?.events.append(event)
        if (runtimes[tab]?.events.count ?? 0) > 50 { runtimes[tab]?.events.removeFirst() }
    }

    static func described(_ target: AgentTarget, _ description: String?) -> String {
        let what = target.element ?? description ?? target.target
        return target.isRef ? "\(what) [ref=\(target.target)]" : what
    }

    static func keyName(_ key: KeySpec) -> String {
        var parts: [String] = []
        if key.ctrlKey { parts.append("Control") }
        if key.altKey { parts.append("Alt") }
        if key.shiftKey { parts.append("Shift") }
        if key.metaKey { parts.append("Meta") }
        parts.append(key.key == " " ? "Space" : key.key)
        return parts.joined(separator: "+")
    }

    static func summary(of command: AgentCommand) -> String {
        switch command {
        case .navigate(let url): return "Opening \(url.absoluteString)"
        case .navigateBack: return "Going back"
        case .snapshot: return "Reading the page"
        case .click(let target, _, _, _): return "Clicking \(described(target, nil))"
        case .type(let target, _, _): return "Typing into \(described(target, nil))"
        case .selectOption(let target, _): return "Choosing in \(described(target, nil))"
        case .hover(let target): return "Hovering \(described(target, nil))"
        case .pressKey(let key): return "Pressing \(keyName(key))"
        case .waitFor: return "Waiting"
        case .screenshot: return "Taking a screenshot"
        case .console: return "Reading the console"
        case .network: return "Reading the requests"
        case .evaluate: return "Running a script"
        case .handleDialog: return "Answering a dialog"
        case .tabs: return "Managing tabs"
        case .close: return "Closing its tabs"
        }
    }

    // MARK: - Lifecycle

    /// Once per project store and app run, before any page uses it.
    private func prepareStore() async {
        guard case .project(let identifier) = profile, !Self.clearedStores.contains(identifier) else { return }
        Self.clearedStores.insert(identifier)
        await AgentBrowserProfile.clearCaches(of: dataStore)
    }

    /// Everything the agent's browser kept for its profile.
    public func clearData() async {
        await AgentBrowserProfile.clearAll(of: dataStore)
    }

    /// The session ended: web views (and their processes) released, tabs kept
    /// for the user to look at.
    public func suspend() {
        cancelAll("The session ended.")
        controller.releaseWebViews()
    }

    /// The session is gone for good.
    public func tearDown() {
        cancelAll("The session was archived.")
        for tab in controller.tabs { controller.close(tab.id) }
        controller.releaseWebViews()
    }

    /// The user answers the current tab's dialog from the panel.
    public func answerDialog(accept: Bool, text: String?) {
        guard let tab = controller.activeTab, let answer = answers.removeValue(forKey: tab) else { return }
        dialogs[tab] = nil
        answer.respond(accept: accept, text: text)
    }

    // MARK: - Page events (WebKit callbacks)

    fileprivate func received(_ message: AgentHookMessage, from webView: WKWebView, frameKey: String) {
        guard let tab = controller.tabID(of: webView), runtimes[tab] != nil else { return }
        guard runtimes[tab]?.limiter.admit(at: Self.clock()) == true else {
            runtimes[tab]?.droppedMessages += 1
            return
        }
        switch message {
        case .console(let level, let text, let location):
            runtimes[tab]?.console.append(level: level, text: text, location: location)
        case .request(let id, let kind, let method, let url):
            runtimes[tab]?.network.started(key: "\(frameKey)#\(id)", kind: kind, method: method, url: url)
        case .response(let id, let status, let error, let durationMs):
            runtimes[tab]?.network.finished(key: "\(frameKey)#\(id)", status: status, error: error, durationMs: durationMs)
        case .dropped(let count):
            runtimes[tab]?.droppedMessages += count
        }
    }

    private func park(_ answer: DialogAnswer, kind: AgentModalState.Kind, message: String,
                      frame: WKFrameInfo, webView: WKWebView) {
        guard let tab = controller.tabID(of: webView), runtimes[tab] != nil else {
            answer.dismiss()
            return
        }
        runtimes[tab]?.dialogCount += 1
        if (runtimes[tab]?.dialogCount ?? 0) > 20 {
            // A page that opens dialogs in a loop: dismissed, like Safari's
            // "prevent additional dialogs".
            answer.dismiss()
            return
        }
        answers.removeValue(forKey: tab)?.dismiss()
        let host = frame.securityOrigin.host.isEmpty ? (webView.url?.host() ?? "this page") : frame.securityOrigin.host
        dialogs[tab] = AgentModalState(kind: kind, message: message, host: host)
        answers[tab] = answer
        interruptCalls(tab, .dialogOpened)
        note(tab, "\(host) opened a dialog.")
    }

    private func dismissDialog(_ tab: BrowserTabsModel.TabID) {
        dialogs[tab] = nil
        answers.removeValue(forKey: tab)?.dismiss()
    }

    private func failure(_ error: Error, webView: WKWebView) -> (cancelled: Bool, message: String) {
        let nsError = error as NSError
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return (true, "") }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return (true, "") }
        let address = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        let place = address.map { url in url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString } ?? "the page"
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost:
                return (false, "nothing is listening on \(place) — is the dev server running?")
            case NSURLErrorCannotFindHost:
                return (false, "unknown host \(place)")
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return (false, "\(place) was refused in plain http by App Transport Security")
            case NSURLErrorTimedOut:
                return (false, "\(place) did not answer in time")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
                return (false, "the TLS connection to \(place) failed (\(nsError.localizedDescription)) — a local dev server usually speaks http")
            default:
                break
            }
        }
        return (false, "\(place): \(nsError.localizedDescription)")
    }
}

// MARK: - The engine of its controller

extension AgentBrowser: BrowserTabEngine {

    func makeWebView(for tab: BrowserTabsModel.TabID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Popups only from what the agent clicks — its clicks carry the gesture.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Off screen, the page keeps running: the agent drives it whether the
        // panel shows it or not (rendering itself still pauses when hidden).
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: AgentScripts.pageHook, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: AgentScripts.helper, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: AgentScripts.world))
        if let messageProxy {
            content.add(messageProxy, contentWorld: .page, name: AgentScripts.messageHandlerName)
        }
        configuration.userContentController = content
        let webView = WKWebView(frame: CGRect(origin: .zero, size: environment.initialViewport),
                                configuration: configuration)
        webView.customUserAgent = BrowserController.safariUserAgent
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        runtimes[tab] = TabRuntime()
        return webView
    }

    func didRelease(_ webView: WKWebView, tab: BrowserTabsModel.TabID) {
        interruptCalls(tab, .crashed)
        dismissDialog(tab)
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        runtimes[tab] = nil
    }

    func didRequestLoad(_ navigation: WKNavigation?, tab: BrowserTabsModel.TabID) {
        runtimes[tab]?.tracker.requested(at: Self.clock())
    }
}

extension AgentBrowser: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let tab = controller.tabID(of: webView)
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            if let tab { note(tab, "A download was ignored: \(navigationAction.request.url?.absoluteString ?? "")") }
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch AgentNavigationPolicy.decide(url: navigationAction.request.url, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
            if isMainFrame, let tab {
                note(tab, "Blocked a navigation to \(navigationAction.request.url?.absoluteString ?? "an empty address") — http(s) only.")
            }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let tab = controller.tabID(of: webView),
           let http = navigationResponse.response as? HTTPURLResponse {
            runtimes[tab]?.pendingDocument = (http.url?.absoluteString ?? "", http.statusCode)
        }
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if let tab = controller.tabID(of: webView) {
                note(tab, "A download was ignored: \(navigationResponse.response.url?.absoluteString ?? "")")
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = controller.tabID(of: webView) else { return }
        runtimes[tab]?.tracker.started(navigation.map { ObjectIdentifier($0) })
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = controller.tabID(of: webView), runtimes[tab] != nil else { return }
        runtimes[tab]?.tracker.committed(navigation.map { ObjectIdentifier($0) })
        runtimes[tab]?.console.navigationCommitted()
        runtimes[tab]?.network.navigationCommitted()
        runtimes[tab]?.httpStatus = nil
        runtimes[tab]?.dialogCount = 0
        if let document = runtimes[tab]?.pendingDocument {
            runtimes[tab]?.httpStatus = document.status
            runtimes[tab]?.network.document(url: document.url, status: document.status)
            runtimes[tab]?.pendingDocument = nil
        }
        // A new document: scripts running in the old one will never answer.
        interruptCalls(tab, .navigated)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = controller.tabID(of: webView) {
            runtimes[tab]?.tracker.finished(navigation.map { ObjectIdentifier($0) })
        }
        controller.recordFinished(webView)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = controller.tabID(of: webView) else { return }
        let outcome = failure(error, webView: webView)
        runtimes[tab]?.tracker.failed(navigation.map { ObjectIdentifier($0) }, cancelled: outcome.cancelled,
                                      message: outcome.message)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        guard let tab = controller.tabID(of: webView) else { return }
        let outcome = failure(error, webView: webView)
        runtimes[tab]?.tracker.failed(navigation.map { ObjectIdentifier($0) }, cancelled: outcome.cancelled,
                                      message: outcome.message)
    }

    /// The page's process died (memory, a crash): reloaded, and whatever
    /// waited on it is told.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = controller.tabID(of: webView) else { return }
        runtimes[tab]?.tracker.terminated()
        interruptCalls(tab, .crashed)
        dismissDialog(tab)
        note(tab, "The page's process stopped; it was reloaded.")
        webView.reload()
    }

    /// Server trust takes WebKit's own decision; any other challenge (a
    /// client certificate, HTTP auth) is cancelled — never answered with the
    /// user's keychain.
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

extension AgentBrowser: WKUIDelegate {

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        park(.alert(completionHandler), kind: .alert, message: message, frame: frame, webView: webView)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        park(.confirm(completionHandler), kind: .confirm, message: message, frame: frame, webView: webView)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping (String?) -> Void) {
        park(.prompt(completionHandler), kind: .prompt(defaultText: defaultText), message: prompt,
             frame: frame, webView: webView)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        park(.files(completionHandler), kind: .fileChooser(multiple: parameters.allowsMultipleSelection),
             message: "", frame: frame, webView: webView)
    }

    /// `target=_blank` and `window.open`: a new tab of the agent's browser,
    /// through the same policy as any navigation. `window.opener` is lost.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        let source = controller.tabID(of: webView)
        guard let url = navigationAction.request.url,
              AgentNavigationPolicy.decide(url: url, isMainFrame: true) == .allow,
              url.absoluteString != "about:blank" else {
            if let source { note(source, "Blocked a popup to \(navigationAction.request.url?.absoluteString ?? "an empty page").") }
            return nil
        }
        let opened = controller.openTab(url: url)
        note(opened, "Opened by the previous tab (\(url.absoluteString)).")
        if let source { note(source, "The page opened a new tab: \(url.absoluteString)") }
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if let tab = controller.tabID(of: webView) { controller.close(tab) }
    }

    /// Camera, microphone, screen: never from the agent's browser.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

// MARK: - Per tab

/// Calls in flight for a tab, counted from WebKit's completions.
final class CallCounter {
    var inFlight = 0
}

private struct TabRuntime {
    var console = ConsoleLog()
    var network = NetworkLog()
    var tracker = MainFrameLoadTracker()
    var limiter = AgentRateLimiter()
    var httpStatus: Int?
    var pendingDocument: (url: String, status: Int)?
    var events: [String] = []
    var pending: [ObjectIdentifier: OneShot<String>] = [:]
    let calls = CallCounter()
    var dialogCount = 0
    var droppedMessages = 0
}

/// A dialog's completion, called exactly once: WebKit raises if one is
/// dropped without being called.
private enum DialogAnswer {
    case alert(() -> Void)
    case confirm((Bool) -> Void)
    case prompt((String?) -> Void)
    case files(([URL]?) -> Void)

    func respond(accept: Bool, text: String?) {
        switch self {
        case .alert(let done): done()
        case .confirm(let done): done(accept)
        case .prompt(let done): done(accept ? (text ?? "") : nil)
        case .files(let done): done(nil)
        }
    }

    func dismiss() {
        respond(accept: false, text: nil)
    }
}

/// The page hook's channel. Weak towards the browser: the user content
/// controller retains its handlers.
final class AgentMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AgentBrowser?

    init(owner: AgentBrowser) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let parsed = AgentHookMessage.parse(message.body), let webView = message.webView else { return }
        // A frame of another origin is named by its origin only: a URL's path
        // and query can carry tokens.
        let frame = message.frameInfo
        let frameKey = frame.isMainFrame ? "main"
            : "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host):\(frame.securityOrigin.port)"
        // WebKit delivers on the main thread: handled there at once, in order.
        MainActor.assumeIsolated {
            owner?.received(parsed, from: webView, frameKey: frameKey)
        }
    }
}
