import AppKit
import Foundation
import LoomAPI
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
        /// Where browser_file_upload may take files from: the session's
        /// working tree, and a folder of Loom's (AgentUploadPolicy).
        public var uploadRoots: [URL]
        /// The page's width the project last chose.
        public var viewportWidth: ViewportWidth
        /// "Local sites only" (Settings ▸ Agents).
        public var networkAccess: AgentNetworkAccess
        public var limits: AgentBrowserLimits

        public init(screenshotsDirectory: URL, initialViewport: CGSize, uploadRoots: [URL] = [],
                    viewportWidth: ViewportWidth = .fit, networkAccess: AgentNetworkAccess = .open,
                    limits: AgentBrowserLimits = AgentBrowserLimits()) {
            self.screenshotsDirectory = screenshotsDirectory
            self.initialViewport = initialViewport
            self.uploadRoots = uploadRoots
            self.viewportWidth = viewportWidth
            self.networkAccess = networkAccess
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
    /// The page's width: the panel's, or a CSS width it is scaled to.
    public private(set) var viewportWidth: ViewportWidth = .fit
    /// The width changed (the agent, the panel's menu): the app keeps it per project.
    @ObservationIgnored public var onViewportChange: ((ViewportWidth) -> Void)?

    @ObservationIgnored private var answers: [BrowserTabsModel.TabID: DialogAnswer] = [:]
    @ObservationIgnored private var runtimes: [BrowserTabsModel.TabID: TabRuntime] = [:]
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private var running: Task<AgentResult, Error>?
    /// The running command's options: commands run one at a time.
    @ObservationIgnored private var currentOptions = AgentCommandOptions()
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private var cancelledReason = "the browser's commands were cancelled"
    @ObservationIgnored private var screenshotSequence = 0
    @ObservationIgnored private var messageProxy: AgentMessageProxy?

    /// Local-only mode: the compiled rule list on every web view, and no
    /// navigation while it compiles — none at all if it failed (fail closed).
    @ObservationIgnored private var networkAccess: AgentNetworkAccess = .open
    @ObservationIgnored private var contentRules: WKContentRuleList?
    @ObservationIgnored private var rulesPreparation: Task<Void, Never>?
    @ObservationIgnored private var rulesFailure: String?
    private static var compiledRules: [String: WKContentRuleList] = [:]

    /// Each project store's leftovers (service workers, caches) cleared once
    /// per app run, shared by every session of the project: no page of the
    /// store loads before it ends (see the navigation policy).
    private static var storePreparations: [UUID: Task<Void, Never>] = [:]
    private static var preparedStores: Set<UUID> = []

    /// The dialog the current tab is blocked on.
    public var activeDialog: AgentModalState? {
        controller.activeTab.flatMap { dialogs[$0] }
    }

    public init(profile: AgentBrowserProfile.Kind, environment: Environment) {
        self.profile = profile
        self.dataStore = AgentBrowserProfile.dataStore(for: profile)
        self.environment = environment
        self.viewportWidth = environment.viewportWidth
        self.controller = BrowserController(agentTabs: 3)
        super.init()
        controller.attach(engine: self)
        controller.onVisit = nil   // the agent's pages never enter the user's history
        messageProxy = AgentMessageProxy(owner: self)
        if case .project(let identifier) = profile, Self.storePreparations[identifier] == nil {
            let store = dataStore
            Self.storePreparations[identifier] = Task { @MainActor in
                await AgentBrowserProfile.clearCaches(of: store)
                Self.preparedStores.insert(identifier)
            }
        }
        setNetworkAccess(environment.networkAccess)
    }

    // MARK: - Local sites only

    /// The setting changed (or the browser starts): the rules every web view
    /// carries, compiled once per rule set. Never a moment without rules on a
    /// page that had them: the ones in force stay until the new ones replace
    /// them in the same turn. Turned on, the open pages are made again — with
    /// no peer connections (WebRTC bypasses the rules), loading only once the
    /// rules are on.
    public func setNetworkAccess(_ access: AgentNetworkAccess) {
        guard access != networkAccess else { return }
        let wasOpen = networkAccess == .open
        networkAccess = access
        rulesFailure = nil
        guard case .localOnly(let hosts) = access else {
            rulesPreparation = nil
            contentRules = nil
            for webView in liveWebViews {
                webView.configuration.userContentController.removeAllContentRuleLists()
                Self.setSideChannels(webView.configuration.preferences, enabled: true)
            }
            return
        }
        let json = AgentNetworkRules.json(allowedHosts: hosts)
        rulesPreparation = Task { @MainActor [weak self] in
            let compiled = await Self.compile(json)
            guard let self, self.networkAccess == access else { return }
            if let list = compiled.list {
                for webView in self.liveWebViews {
                    let content = webView.configuration.userContentController
                    content.removeAllContentRuleLists()
                    content.add(list)
                }
                self.contentRules = list
            } else {
                // Fail closed: navigations are refused (finishAllowing); the
                // rules in force, if any, stay on the pages.
                self.rulesFailure = compiled.error ?? "unknown error"
            }
            self.rulesPreparation = nil
        }
        if wasOpen, !liveWebViews.isEmpty {
            // Before this, the pages ran free: they start again under the
            // mode, their loads held until the rules are on. A command on
            // them ends first — it would hold a page outside the mode.
            cancelAll("Local sites only was turned on: the pages were loaded again under it.")
            let hadDialog = Set(dialogs.keys)
            controller.releaseWebViews()
            controller.materialize()
            for tab in controller.tabs where controller.webView(for: tab.id) != nil {
                note(tab.id, "Local sites only was turned on: the page was loaded again under it"
                     + (hadDialog.contains(tab.id) ? " (its dialog was dismissed)." : "."))
            }
        }
    }

    /// Local-only mode leaves no way around its rules that WebKit offers to
    /// turn off: peer connections (WebRTC's sockets are not loads) and DNS
    /// prefetching. WebKit's own preferences, through key-value coding — set
    /// only where the running WebKit has them.
    private static func setSideChannels(_ preferences: WKPreferences, enabled: Bool) {
        for (key, setter) in [("peerConnectionEnabled", "_setPeerConnectionEnabled:"),
                              ("DNSPrefetchingEnabled", "_setDNSPrefetchingEnabled:")]
        where preferences.responds(to: NSSelectorFromString(setter)) {
            preferences.setValue(enabled, forKey: key)
        }
    }

    private var liveWebViews: [WKWebView] {
        controller.tabs.compactMap { controller.webView(for: $0.id) }
    }

    private static func compile(_ json: String) async -> CompiledRules {
        if let cached = compiledRules[json] { return CompiledRules(list: cached, error: nil) }
        guard let store = WKContentRuleListStore.default() else {
            return CompiledRules(list: nil, error: "WebKit has no rule store")
        }
        let compiled = await withCheckedContinuation { (continuation: CheckedContinuation<CompiledRules, Never>) in
            store.compileContentRuleList(forIdentifier: AgentNetworkRules.identifier(for: json),
                                         encodedContentRuleList: json) { list, error in
                continuation.resume(returning: CompiledRules(
                    list: list, error: list == nil ? (error?.localizedDescription ?? "unknown error") : nil))
            }
        }
        if let list = compiled.list { compiledRules[json] = list }
        return compiled
    }

    /// What a navigation waits for: the store's clearing, the rules' compiling.
    private var pendingPreparations: [Task<Void, Never>] {
        var waits: [Task<Void, Never>] = []
        if case .project(let identifier) = profile, !Self.preparedStores.contains(identifier),
           let preparation = Self.storePreparations[identifier] {
            waits.append(preparation)
        }
        if let rulesPreparation { waits.append(rulesPreparation) }
        return waits
    }

    /// Until no preparation is pending — a setting changed while waiting
    /// starts another.
    private func preparationsSettled() async {
        while true {
            let waits = pendingPreparations
            if waits.isEmpty { return }
            for wait in waits { await wait.value }
        }
    }

    /// Outside what local-only mode allows: the navigation's URL, refused.
    private func refusedByNetworkAccess(_ url: URL?) -> Bool {
        AgentNetworkRules.refuses(url, under: networkAccess)
    }

    /// Before the engine touches a tab for `url`: refused outright when the
    /// mode forbids it, rather than a load WebKit drops without a word.
    private func refuseOutsideNetworkAccess(_ url: URL) async throws {
        guard networkAccess != .open else { return }
        await preparationsSettled()
        try Task.checkCancellation()
        if refusedByNetworkAccess(url) {
            throw AgentError.invalid("\(url.host() ?? url.absoluteString) is outside local sites only "
                                     + "(Loom's Settings ▸ Agents lists the hosts it lets through)")
        }
        if let rulesFailure {
            throw AgentError.unavailable("the local-only rules could not be set up (\(rulesFailure)): nothing loads")
        }
    }

    // MARK: - Commands

    /// Runs `command` after the ones before it, within `deadline`, answering
    /// as `options` ask.
    public func run(_ command: AgentCommand, options: AgentCommandOptions,
                    deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let previous = queueTail
        let generation = queueGeneration
        let job = Task<AgentResult, Error> { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { throw AgentError.unavailable("the browser was closed") }
            guard generation == self.queueGeneration, !Task.isCancelled else {
                throw AgentError.unavailable(self.cancelledReason)
            }
            // Its turn came too late: it never acts on the page only to
            // report a timeout.
            guard ContinuousClock.now < deadline - .seconds(1) else {
                throw AgentError.timeout("another browser command was still running when this one's time ran out; it did not run")
            }
            return try await self.runNow(command, options: options, deadline: deadline)
        }
        queueTail = Task { _ = try? await job.value }
        // The caller's wait is bounded even while the job queues or overruns:
        // the app answers before the client gives up (APIProtocol.clientTimeout).
        let answer = OneShot<AgentResult>()
        let forward = Task { @MainActor in
            do {
                let value = try await job.value
                answer.resolve(.success(value))
            } catch {
                answer.resolve(.failure(error))
            }
        }
        let backstop = Task { @MainActor in
            do { try await Task.sleep(until: deadline + .seconds(2), clock: .continuous) } catch { return }
            answer.resolve(.failure(AgentError.timeout("another browser command was still running when this one's time ran out")))
        }
        defer {
            backstop.cancel()
            _ = forward
        }
        return try await withTaskCancellationHandler {
            try await answer.value()
        } onCancel: {
            job.cancel()
        }
    }

    /// Pending and running commands fail at once (the tools were turned off,
    /// the session ended); a running one's script calls end with its task.
    public func cancelAll(_ reason: String) {
        queueGeneration += 1
        cancelledReason = reason
        running?.cancel()
        activity = activity.map { AgentActivity(summary: reason, isRunning: false, at: $0.at) }
    }

    private func runNow(_ command: AgentCommand, options: AgentCommandOptions,
                        deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let generation = queueGeneration
        currentOptions = options
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
            currentOptions = AgentCommandOptions()
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
            if generation != queueGeneration { throw AgentError.unavailable(cancelledReason) }
            throw AgentError.unavailable("the command was cancelled")
        } catch is AgentJS.HelperMissing {
            throw AgentError.failed("Loom's helper could not be loaded in this page")
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
        // A tab the user opened, or one brought back, loads only once the
        // store is clean: no command reads a page before.
        await prepareStore()
        try Task.checkCancellation()
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
        case .type(let target, let text, let submit, let slowly):
            if slowly { return try await typeSlowly(into: target, text: text, submit: submit, deadline: deadline) }
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
        case .screenshot(let target, let format, let fullPage):
            return try await screenshot(target: target, format: format, fullPage: fullPage, deadline: deadline)
        case .console(let level, let all):
            let (tab, webView) = try await currentPage(deadline: deadline)
            let text = runtimes[tab]?.console.render(level: level, all: all, limit: environment.limits.consoleChars)
                ?? "No console messages."
            return respond(text, tab: tab, webView: webView, snapshot: nil)
        case .network(let filter):
            let (tab, webView) = try await currentPage(deadline: deadline)
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
            controller.closeAll()
            return AgentResult(text: "### Result\nClosed every tab of the agent's browser. Its profile (cookies, storage) is kept.")
        case .fillForm(let fields):
            return try await fillForm(fields, deadline: deadline)
        case .fileUpload(let paths):
            return try await fileUpload(paths, deadline: deadline)
        case .resize(let width):
            return try await resize(to: width, deadline: deadline)
        }
    }

    // MARK: - Navigation

    private func navigate(to url: URL, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        try await refuseOutsideNetworkAccess(url)
        let tab: BrowserTabsModel.TabID
        if let active = controller.activeTab {
            tab = active
            if let current = controller.webView(for: active) {
                if dialogs[tab] != nil {
                    // Leaving the page answers its dialog, as a browser does:
                    // the load then runs instead of queueing behind it.
                    dismissDialog(tab)
                    note(tab, "The page's dialog was dismissed by the navigation.")
                }
                let stuck = await isStuck(tab, current)
                try Task.checkCancellation()
                if stuck {
                    // A script from an earlier command never yielded: a fresh
                    // process instead of queueing behind it.
                    controller.load(url, in: tab)
                    controller.recreateWebView(for: tab)
                    note(tab, "The previous page was stuck in a script: it was replaced by a fresh one.")
                } else {
                    didRequestLoad(controller.load(url, in: tab), tab: tab)
                }
            } else {
                // Released (the session ended, then resumed): the tab comes
                // back at the new address — the old page is never fetched.
                controller.load(url, in: tab)
                controller.materialize()
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
        let (tab, webView) = try await currentPage(deadline: deadline)
        // The page's process is blocked on its dialog: the load would wait too.
        try refuseWhileDialog(tab)
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
        let (tab, webView) = try await currentPage(deadline: deadline)
        // Reading is fine beside a file chooser; a JS dialog holds the page.
        if blocksPage(tab) { try refuseWhileDialog(tab) }
        var args: [String: Any] = ["budget": environment.limits.snapshotChars]
        if let target { args["target"] = target }
        if let depth { args["depth"] = depth }
        let answer = try await helper("snapshot", args, tab: tab, webView: webView, deadline: deadline)
        return respond(nil, tab: tab, webView: webView, snapshot: answer["yaml"] as? String)
    }

    private func waitFor(time: Double?, text: String?, textGone: String?, timeout: Double,
                         deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
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
                try await pause(.milliseconds(100))
            }
            result = text.map { "\"\($0)\" appeared" } ?? "\"\(textGone ?? "")\" went away"
        }
        return await respondWithSnapshot(result, tab: tab, webView: webView, deadline: deadline)
    }

    private func screenshot(target: AgentTarget?, format: ImageFormat, fullPage: Bool,
                            deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
        // A JS dialog blocks the page's process, and its drawing with it; a
        // file chooser does not.
        if blocksPage(tab) { try refuseWhileDialog(tab) }
        ensureFrame(webView)
        // The page's CSS pixels are the view's points times its zoom (a set width).
        let zoom = max(webView.pageZoom, 0.1)
        let data: Data
        let pixels: CGSize
        var what = "the visible page"
        if fullPage {
            let page = try await fullPageImage(format: format, tab: tab, webView: webView, deadline: deadline)
            data = page.data
            pixels = page.pixels
            what = page.what
        } else {
            var rect: CGRect?
            if let target {
                let answer = try await helper("rect", ["target": target.target], tab: tab, webView: webView,
                                              deadline: deadline)
                guard let box = answer["rect"] as? [String: Any],
                      let x = box["x"] as? Double, let y = box["y"] as? Double,
                      let width = box["width"] as? Double, let height = box["height"] as? Double,
                      width > 0, height > 0 else {
                    throw AgentError.invalid("\(target.target) has no visible box to capture")
                }
                rect = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
                    .intersection(webView.bounds)
                guard let visible = rect, !visible.isEmpty else {
                    throw AgentError.invalid("\(target.target) is outside the visible page")
                }
                what = answer["description"] as? String ?? target.target
            }
            let image = try await AgentScreenshot.capture(webView, rect: rect)
            let viewSize = rect?.size ?? webView.bounds.size
            let cssSize = CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom)
            pixels = AgentScreenshot.targetSize(for: cssSize, maxEdge: environment.limits.imageMaxEdge)
            guard let encoded = AgentScreenshot.encode(image, pixels: pixels, format: format) else {
                throw AgentError.failed("the screenshot could not be encoded")
            }
            data = encoded
        }
        if screenshotSequence == 0 {
            // A resumed session's folder holds a previous run's files: the
            // numbering goes on after them, never under (they would be pruned).
            screenshotSequence = AgentScreenshot.lastSequence(in: environment.screenshotsDirectory)
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
        let (tab, webView) = try await currentPage(deadline: deadline)
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
        noteFailedLoad(since: mark, tab: tab)
        return await respondWithSnapshot("\(verb) \(described)", tab: tab, webView: webView, deadline: deadline)
    }

    private func pressKey(_ key: KeySpec, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
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
        noteFailedLoad(since: mark, tab: tab)
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
        let (tab, webView) = try await currentPage(deadline: deadline)
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
        let head = output.prefix(limit)   // never a walk over a huge answer
        let shown = head.endIndex == output.endIndex ? output : String(head) + "\n… (cut at \(limit) characters)"
        return respond("```json\n\(shown)\n```", tab: tab, webView: webView, snapshot: nil)
    }

    private func handleDialog(accept: Bool, promptText: String?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
        guard answers[tab] != nil, dialogs[tab] != nil else {
            if let other = controller.tabs.firstIndex(where: { dialogs[$0.id] != nil }) {
                throw AgentError.invalid("no dialog is open on this tab; tab \(other) has one — browser_tabs select \(other), then answer it")
            }
            throw AgentError.invalid("no dialog is open")
        }
        guard let answer = answers.removeValue(forKey: tab), let dialog = dialogs.removeValue(forKey: tab) else {
            throw AgentError.invalid("no dialog is open")
        }
        let mark = navigationMark(tab)
        answer.respond(accept: accept, text: promptText)
        try await settle(after: mark, tab: tab, deadline: deadline)
        noteFailedLoad(since: mark, tab: tab)
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
            if let url { try await refuseOutsideNetworkAccess(url) }
            let tab = controller.openTab(url: url ?? URL(string: "about:blank")!)
            guard let webView = controller.webView(for: tab) else { throw AgentError.unavailable("the tab could not open") }
            try await waitForLoad(tab: tab, limit: .seconds(30), deadline: deadline)
            // As browser_navigate: the tab stays, the failure is the answer.
            if let error = runtimes[tab]?.tracker.lastError { throw AgentError.failed(error) }
            return await respondWithSnapshot("Opened a new tab", tab: tab, webView: webView, deadline: deadline)
        case .select(let index):
            guard controller.tabs.indices.contains(index) else {
                throw AgentError.invalid("no tab \(index): there are \(controller.tabs.count)")
            }
            let id = controller.tabs[index].id
            controller.activate(id)
            guard let webView = controller.webView(for: id) else { throw AgentError.unavailable("the tab could not open") }
            // A call blocked on the tab's own dialog waits, it is not stuck:
            // a fresh view would dismiss the dialog and reload the page.
            var stuck = false
            if dialogs[id] == nil { stuck = await isStuck(id, webView) }
            try Task.checkCancellation()
            if stuck {
                controller.recreateWebView(for: id)
                note(id, "The page was stuck in a script: it was replaced by a fresh one.")
            }
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

    /// `browser_type slowly`: the field focused and emptied, then each
    /// character a key press — for handlers that watch keys (autocomplete).
    /// Sent in small batches from here: a hidden page's timers are throttled.
    private func typeSlowly(into target: AgentTarget, text: String, submit: Bool,
                            deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
        try refuseWhileDialog(tab)
        let ready = try await waitUntilActionable(target, action: "type", tab: tab, webView: webView,
                                                  deadline: deadline)
        let described = Self.described(target, ready["description"] as? String)
        let mark = navigationMark(tab)
        _ = try await helper("focusField", ["target": target.target, "clear": true], tab: tab, webView: webView,
                             deadline: deadline)
        var keys = text.map(KeySpec.typing)
        if submit { keys.append(KeySpec(key: "Enter", code: "Enter", keyCode: 13)) }
        let batches = stride(from: 0, to: keys.count, by: 8).map { Array(keys[$0..<min($0 + 8, keys.count)]) }
        var interrupted = false
        for batch in batches {
            let json = (try? JSONEncoder().encode(["keys": batch])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            do {
                _ = try await helper("typeKeys", json: json, tab: tab, webView: webView, deadline: deadline)
            } catch AgentInterruption.dialogOpened {
                interrupted = true
            } catch AgentInterruption.navigated {
                interrupted = true
            }
            if interrupted { break }
            try await pause(.milliseconds(40))
        }
        try await settle(after: mark, tab: tab, deadline: deadline)
        noteFailedLoad(since: mark, tab: tab)
        let how = interrupted ? " (stopped: the page opened a dialog or navigated)" : " one key at a time"
        return await respondWithSnapshot("Typed into \(described)\(how)", tab: tab, webView: webView, deadline: deadline)
    }

    /// Several fields in order, each when it is ready; the first failure
    /// stops the form and says which fields were filled.
    private func fillForm(_ fields: [FormField], deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
        try refuseWhileDialog(tab)
        let mark = navigationMark(tab)
        var filled: [String] = []
        for field in fields {
            do {
                try await fill(field, tab: tab, webView: webView, deadline: deadline)
                filled.append(field.name)
            } catch AgentInterruption.dialogOpened {
                filled.append(field.name)
                if filled.count < fields.count { note(tab, "\(field.name) opened a dialog: the fields after it were left.") }
                break
            } catch AgentInterruption.navigated {
                filled.append(field.name)
                if filled.count < fields.count { note(tab, "\(field.name) left the page: the fields after it were left.") }
                break
            } catch let error as AgentError {
                let done = filled.isEmpty ? "no field was filled" : "filled before it: " + filled.joined(separator: ", ")
                throw error.prefixed("\(field.name): ", suffix: " (\(done))")
            }
        }
        try await settle(after: mark, tab: tab, deadline: deadline)
        noteFailedLoad(since: mark, tab: tab)
        return await respondWithSnapshot("Filled \(filled.joined(separator: ", "))", tab: tab, webView: webView,
                                         deadline: deadline)
    }

    private func fill(_ field: FormField, tab: BrowserTabsModel.TabID, webView: WKWebView,
                      deadline: ContinuousClock.Instant) async throws {
        let readiness: String
        let op: String
        var args: [String: Any] = ["target": field.target.target]
        switch field.kind {
        case .textbox:
            readiness = "type"
            op = "type"
            args["text"] = field.value
            args["submit"] = false
        case .combobox:
            readiness = "select"
            op = "selectOption"
            args["values"] = [field.value]
        case .checkbox, .radio:
            readiness = "click"
            op = "setChecked"
            args["checked"] = field.value == "true"
        case .slider:
            readiness = "click"
            op = "setValue"
            args["value"] = field.value
        }
        _ = try await waitUntilActionable(field.target, action: readiness, tab: tab, webView: webView, deadline: deadline)
        let answer = try await helper(op, args, tab: tab, webView: webView, deadline: deadline)
        if field.kind == .checkbox || field.kind == .radio, let checked = answer["checked"] as? Bool,
           checked != (field.value == "true") {
            throw AgentError.failed(field.kind == .radio && field.value == "false"
                ? "a radio is unchecked by choosing another of its group"
                : "it stayed \(checked ? "checked" : "unchecked") — the page undid the click")
        }
    }

    /// Answers the file chooser the page opened, with files the policy
    /// allows — or none, which cancels it.
    private func fileUpload(_ paths: [String]?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (tab, webView) = try await currentPage(deadline: deadline)
        guard let dialog = dialogs[tab], answers[tab] != nil else {
            throw AgentError.invalid("no file chooser is open: click the file input first, then call browser_file_upload")
        }
        guard case .fileChooser(let multiple) = dialog.kind else {
            throw AgentError.conflict("the page waits on a dialog, not a file chooser: answer it with browser_handle_dialog")
        }
        var files: [URL] = []
        if let paths, !paths.isEmpty {
            let policy = AgentUploadPolicy(roots: environment.uploadRoots)
            switch policy.validate(paths, allowsMultiple: multiple) {
            case .success(let accepted): files = accepted
            case .failure(let refusal):
                throw AgentError.invalid(AgentUploadPolicy.message(for: refusal, roots: policy.roots))
            }
        }
        guard let answer = answers.removeValue(forKey: tab) else { throw AgentError.invalid("no file chooser is open") }
        dialogs[tab] = nil
        let mark = navigationMark(tab)
        answer.provide(files.isEmpty ? nil : files)
        try await settle(after: mark, tab: tab, deadline: deadline)
        noteFailedLoad(since: mark, tab: tab)
        let what = files.isEmpty ? "Cancelled the file chooser"
            : "Chose " + files.map(\.lastPathComponent).joined(separator: ", ")
        return await respondWithSnapshot(what, tab: tab, webView: webView, deadline: deadline)
    }

    private func resize(to width: ViewportWidth, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        setViewportWidth(width)
        let what: String
        switch width {
        case .fit: what = "The page fits the panel again"
        case .css(let pixels): what = "The page is \(pixels) CSS pixels wide, scaled into the panel"
        }
        guard controller.activeTab != nil else {
            return AgentResult(text: "### Result\n\(what); it applies to the next page.")
        }
        let (tab, webView) = try await currentPage(deadline: deadline)
        // A width change is a relayout, and maybe a media query's new layout.
        try await pause(.milliseconds(250))
        return await respondWithSnapshot(what, tab: tab, webView: webView, deadline: deadline)
    }

    /// Every live page at the width; the app remembers it for the project.
    public func setViewportWidth(_ width: ViewportWidth) {
        viewportWidth = width
        for tab in controller.tabs {
            if let webView = controller.webView(for: tab.id) { applyZoom(webView) }
        }
        onViewportChange?(width)
    }

    private func applyZoom(_ webView: WKWebView) {
        let zoom = viewportWidth.zoom(forViewWidth: webView.bounds.width)
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
    }

    /// The panel resized a page: a set width stays the same CSS width.
    @objc private func webViewFrameDidChange(_ notification: Notification) {
        guard let webView = notification.object as? WKWebView else { return }
        applyZoom(webView)
    }

    /// The whole page, a viewport at a time — scrolled through, then put back
    /// where it was. Fixed and sticky elements show in every slice.
    private func fullPageImage(format: ImageFormat, tab: BrowserTabsModel.TabID, webView: WKWebView,
                               deadline: ContinuousClock.Instant) async throws -> (data: Data, pixels: CGSize, what: String) {
        let info = try await helper("pageInfo", [:], tab: tab, webView: webView, deadline: deadline)
        let width = CGFloat(info["width"] as? Double ?? 0)
        let viewportHeight = CGFloat(info["height"] as? Double ?? 0)
        let scrollHeight = CGFloat(info["scrollHeight"] as? Double ?? 0)
        let startX = info["scrollX"] as? Double ?? 0
        let startY = info["scrollY"] as? Double ?? 0
        guard width > 0, viewportHeight > 0 else { throw AgentError.failed("the page has no size to capture") }
        let total = min(max(scrollHeight, viewportHeight), Self.fullPageMaxHeight)
        let zoom = max(webView.pageZoom, 0.1)
        var slices: [AgentScreenshot.Slice] = []
        var covered: CGFloat = 0
        var stuck = false
        do {
            while covered < total {
                let top = covered
                let scrolled = try await helper("scrollTo", ["x": startX, "y": Double(top)], tab: tab,
                                                webView: webView, deadline: deadline)
                let actual = CGFloat(scrolled["y"] as? Double ?? Double(top))
                try await pause(.milliseconds(120))   // a frame to paint the new position
                let image = try await AgentScreenshot.capture(webView, rect: nil)
                // The slice [top, bottom) of the page, in a view that shows
                // [actual, actual + viewport): never past what it shows — a
                // page that shrank, or would not scroll, ends the capture.
                // A set width scales the page: WebKit keeps the scroll in
                // whole device pixels, a fraction of a CSS pixel off; and
                // scrollHeight is rounded up, scrollY down, a pixel each at
                // most — on a 1× screen the page's last pixel was "cut".
                let slack = 1 / zoom + 1.5
                let shown = actual + webView.bounds.height / zoom
                var bottom = min(top + viewportHeight, total)
                if actual + viewportHeight + slack < bottom {
                    bottom = actual + viewportHeight
                    stuck = true
                }
                // A scroll snapped past `top` leaves a band unseen: the
                // capture ends there rather than skip it.
                guard bottom > top, actual <= top + slack else { stuck = true; break }
                slices.append(AgentScreenshot.Slice(image: NSImageBox(image: image),
                                                    sourceTop: max(0, top - actual) * zoom,
                                                    sourceHeight: (min(bottom, shown) - top) * zoom,
                                                    pageTop: top, pageHeight: bottom - top))
                covered = bottom
                if stuck { break }
            }
        } catch {
            await scrollBackUncancelled(x: startX, y: startY, tab: tab, webView: webView)
            throw error
        }
        // Put back: the agent's next action expects the page where it was.
        await scrollBackUncancelled(x: startX, y: startY, tab: tab, webView: webView)
        guard covered > 0 else { throw AgentError.failed("the page could not be captured") }
        let size = CGSize(width: width, height: covered)
        let pixels = AgentScreenshot.targetSize(for: size, maxEdge: environment.limits.imageMaxEdge)
        guard let data = AgentScreenshot.encode(slices: slices, pageSize: size, pixels: pixels, format: format) else {
            throw AgentError.failed("the screenshot could not be encoded")
        }
        let cut: String
        if stuck {
            cut = " (cut: the page would not scroll further)"
        } else if scrollHeight > Self.fullPageMaxHeight {
            cut = " (cut at \(Int(Self.fullPageMaxHeight)) of \(Int(scrollHeight)) CSS pixels)"
        } else {
            cut = ""
        }
        return (data, pixels, "the whole page, \(Int(width))×\(Int(covered)) CSS pixels\(cut)")
    }

    /// In a task of its own: a capture cut short by its deadline or a cancel
    /// still puts the page back (a cancelled task's script calls end at once).
    private func scrollBackUncancelled(x: Double, y: Double, tab: BrowserTabsModel.TabID,
                                       webView: WKWebView) async {
        await Task { @MainActor [weak self] in
            _ = try? await self?.helper("scrollTo", ["x": x, "y": y], tab: tab, webView: webView,
                                        deadline: ContinuousClock.now + .seconds(2))
        }.value
    }

    /// A full-page capture stops there: past it, the image would be scaled
    /// to illegible anyway.
    static let fullPageMaxHeight: CGFloat = 8_000

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
        if (tracker?.startedCount ?? 0) > mark.started || tracker?.isLoading == true
            || controller.webView(for: tab)?.isLoading == true {
            try await waitForLoad(tab: tab, limit: .seconds(10), deadline: deadline)
        } else {
            // 2 s at most: a long-poll request would otherwise cost every action its whole limit.
            try await waitForNetworkIdle(tab: tab, after: mark.network, limit: .seconds(2), deadline: deadline)
        }
        try await pause(.milliseconds(150))
    }

    private func waitForLoad(tab: BrowserTabsModel.TabID, limit: Duration, deadline: ContinuousClock.Instant) async throws {
        let end = min(deadline - .seconds(1), ContinuousClock.now + limit)
        while ContinuousClock.now < end {
            if dialogs[tab] != nil { return }
            guard let tracker = runtimes[tab]?.tracker else { return }
            // WebKit's own flag, true from load()/goBack() until the load
            // starts and ends: a cold process can take longer than the
            // tracker's grace to start the first one.
            let pending = controller.webView(for: tab)?.isLoading ?? false
            if !pending, tracker.isSettled(at: Self.clock()) { return }
            try await pause(.milliseconds(50))
        }
        if runtimes[tab]?.tracker.isLoading == true || controller.webView(for: tab)?.isLoading == true {
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
            } catch is AgentJS.HelperMissing {
                if attempt == 0 { try await injectHelper(webView, tab: tab, deadline: deadline) }
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
        // A page blocked on a dialog would run the script once the dialog is
        // answered, long after the command reported: refused before it starts.
        // A file chooser blocks nothing.
        if blocksPage(tab) { try refuseWhileDialog(tab) }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AgentInterruption.deadline }
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
        return try await box.value()
    }

    /// Stuck: a call is still pending AND the page cannot answer a trivial
    /// one within a second. A browser_evaluate awaiting a promise has
    /// yielded — its page answers, and keeps its history and storage.
    private func isStuck(_ tab: BrowserTabsModel.TabID, _ webView: WKWebView) async -> Bool {
        guard runtimes[tab]?.calls.inFlight ?? 0 > 0, dialogs[tab] == nil else { return false }
        do {
            _ = try await callJS(webView, tab: tab, body: "return 1;", arguments: [:], world: AgentScripts.world,
                                 deadline: ContinuousClock.now + .seconds(1))
            // A trivial answer came: the earlier call is waiting on the page
            // (a promise), not blocking it.
            return false
        } catch AgentInterruption.deadline {
            return true
        } catch {
            return false   // navigated, crashed, cancelled: not a script that never yields
        }
    }

    /// A load the action started, and that failed: said in its answer.
    private func noteFailedLoad(since mark: NavigationMark, tab: BrowserTabsModel.TabID) {
        guard let tracker = runtimes[tab]?.tracker, tracker.startedCount > mark.started,
              let error = tracker.lastError else { return }
        note(tab, "The page load it started failed: \(error)")
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
        case .crashed: return .unavailable("the page's process stopped during the command")
        case .closed(let unloaded):
            return .unavailable(unloaded
                ? "the tab was unloaded during the command; select it again with browser_tabs"
                : "the tab was closed during the command")
        }
    }

    // MARK: - Answers

    /// The current tab's page — brought back, and loaded, if the session's
    /// end released it.
    private func currentPage(deadline: ContinuousClock.Instant) async throws -> (BrowserTabsModel.TabID, WKWebView) {
        guard let tab = controller.activeTab else {
            throw AgentError.unavailable("No page is open yet — start with browser_navigate")
        }
        let restored = controller.webView(for: tab) == nil
        controller.materialize()
        guard let webView = controller.webView(for: tab) else {
            throw AgentError.unavailable("the page is not loaded — call browser_navigate")
        }
        ensureFrame(webView)
        if restored { try await waitForLoad(tab: tab, limit: .seconds(10), deadline: deadline) }
        return (tab, webView)
    }

    /// A JS dialog holds the page's script thread (and its drawing); a file
    /// chooser leaves the page running.
    private func blocksPage(_ tab: BrowserTabsModel.TabID) -> Bool {
        guard let kind = dialogs[tab]?.kind else { return false }
        if case .fileChooser = kind { return false }
        return true
    }

    private func refuseWhileDialog(_ tab: BrowserTabsModel.TabID) throws {
        if case .fileChooser? = dialogs[tab]?.kind {
            throw AgentError.conflict("a file chooser is open: answer it with browser_file_upload (no paths cancels it)")
        }
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
        if currentOptions.snapshot == .full, !blocksPage(tab), ContinuousClock.now < deadline - .milliseconds(500) {
            let answer = try? await helper("snapshot", ["budget": environment.limits.actionSnapshotChars],
                                           tab: tab, webView: webView, deadline: deadline - .milliseconds(300))
            yaml = answer?["yaml"] as? String
        }
        return respond(result, tab: tab, webView: webView, snapshot: yaml)
    }

    private func respond(_ result: String?, tab: BrowserTabsModel.TabID, webView: WKWebView,
                         snapshot: String?) -> AgentResult {
        let runtime = runtimes[tab]
        let counts = runtime?.console.counts ?? (errors: 0, warnings: 0)
        let hidden = webView.window == nil || !(webView.window?.occlusionState.contains(.visible) ?? false)
        let page = AgentPageSummary(url: webView.url?.absoluteString ?? controller.model.tab(tab)?.url.absoluteString ?? "",
                                    title: webView.title ?? "", httpStatus: runtime?.httpStatus,
                                    consoleErrors: counts.errors, consoleWarnings: counts.warnings,
                                    viewport: CGSize(width: webView.bounds.width / max(webView.pageZoom, 0.1),
                                                     height: webView.bounds.height / max(webView.pageZoom, 0.1)),
                                    viewportScaled: viewportWidth != .fit, hidden: hidden)
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
        case .type(let target, _, _, _): return "Typing into \(described(target, nil))"
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
        case .fillForm(let fields): return "Filling \(fields.count == 1 ? "a field" : "\(fields.count) fields")"
        case .fileUpload: return "Choosing files"
        case .resize(let width): return "Setting the page width: \(width.label)"
        }
    }

    // MARK: - Lifecycle

    /// Once per project store and app run, before any page uses it: every
    /// session of the project waits for the same clearing.
    private func prepareStore() async {
        guard case .project(let identifier) = profile else { return }
        await Self.storePreparations[identifier]?.value
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
        controller.closeAll()
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
        // A response only completes an entry an admitted request created: it
        // never needs a token, and a dropped one would leave the request
        // pending — every later wait for a quiet network would run out.
        if case .response(let id, let status, let error, let durationMs) = message {
            runtimes[tab]?.network.finished(key: "\(frameKey)#\(id)", status: status, error: error, durationMs: durationMs)
            return
        }
        guard runtimes[tab]?.limiter.admit(at: Self.clock()) == true else { return }
        switch message {
        case .console(let level, let text, let location):
            runtimes[tab]?.console.append(level: level, text: text, location: location)
        case .request(let id, let kind, let method, let url):
            runtimes[tab]?.network.started(key: "\(frameKey)#\(id)", kind: kind, method: method, url: url)
        case .response, .dropped:
            break
        }
    }

    /// The page flooded the channel (AgentMessageProxy): nothing more is
    /// recorded from it until its next document.
    fileprivate func channelCut(for webView: WKWebView) {
        guard let tab = controller.tabID(of: webView), runtimes[tab] != nil else { return }
        runtimes[tab]?.channelCut = true
        note(tab, "The page sent console and network messages faster than Loom reads them: they are no longer "
             + "recorded until it navigates.")
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
        // The dialog's own frame speaks: a data: or sandboxed iframe (an
        // opaque origin) never passes for the page under test.
        let topHost = webView.url?.host() ?? "this page"
        let host: String
        if !frame.securityOrigin.host.isEmpty {
            host = frame.securityOrigin.host
        } else if frame.isMainFrame {
            host = topHost
        } else {
            host = "A frame embedded in \(topHost)"
        }
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
        if networkAccess != .open { Self.setSideChannels(configuration.preferences, enabled: false) }
        // Popups only from what the agent clicks — its clicks carry the gesture.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Off screen, the page keeps running: the agent drives it whether the
        // panel shows it or not (rendering itself still pauses when hidden).
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = WKUserContentController()
        // The relay first: it listens before the hook can speak.
        content.addUserScript(WKUserScript(source: AgentScripts.relay, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: AgentScripts.world))
        content.addUserScript(WKUserScript(source: AgentScripts.pageHook, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: AgentScripts.helper, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: AgentScripts.world))
        // Loom's world only: no page script can post to it, or flood the
        // main thread with what it would deliver.
        if let messageProxy {
            content.add(messageProxy, contentWorld: AgentScripts.world, name: AgentScripts.messageHandlerName)
        }
        if let contentRules { content.add(contentRules) }
        configuration.userContentController = content
        let webView = WKWebView(frame: CGRect(origin: .zero, size: environment.initialViewport),
                                configuration: configuration)
        webView.customUserAgent = BrowserController.safariUserAgent
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // A set width follows the panel's: the zoom is redone on each resize.
        webView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(webViewFrameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: webView)
        applyZoom(webView)
        runtimes[tab] = TabRuntime()
        return webView
    }

    func didRelease(_ webView: WKWebView, tab: BrowserTabsModel.TabID) {
        // Released while its tab stays in the model: unloaded, not closed.
        interruptCalls(tab, .closed(unloaded: controller.model.tab(tab) != nil))
        dismissDialog(tab)
        // A reference left somewhere (a view not yet swapped) never keeps the
        // page running: it is emptied as it goes.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: webView)
        messageProxy?.forget(webView.configuration.userContentController)
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
            let url = navigationAction.request.url
            // No request before the store's leftovers are gone and the
            // local-only rules are on the view: WebKit sends nothing until
            // the policy is decided — then decided against the mode in force.
            if pendingPreparations.isEmpty {
                finishAllowing(decisionHandler, url: url, webView: webView, tab: tab, isMainFrame: isMainFrame)
            } else {
                Task { @MainActor in
                    await self.preparationsSettled()
                    self.finishAllowing(decisionHandler, url: url, webView: webView, tab: tab, isMainFrame: isMainFrame)
                }
            }
        case .cancel:
            decisionHandler(.cancel)
            if isMainFrame, let tab {
                note(tab, "Blocked a navigation to \(navigationAction.request.url?.absoluteString ?? "an empty address") — http(s) only.")
            }
        }
    }

    /// The decision, against the mode in force now: outside it, refused; in
    /// local-only mode without its rules on the views (they failed), nothing
    /// loads.
    private func finishAllowing(_ decisionHandler: @escaping (WKNavigationActionPolicy) -> Void, url: URL?,
                                webView: WKWebView, tab: BrowserTabsModel.TabID?, isMainFrame: Bool) {
        if refusedByNetworkAccess(url) {
            decisionHandler(.cancel)
            if isMainFrame, let tab {
                note(tab, "Blocked \(url?.absoluteString ?? "a page"): the agent's browser opens local sites only "
                     + "(Loom's Settings ▸ Agents).")
            }
            return
        }
        if networkAccess != .open, rulesFailure != nil || contentRules == nil {
            decisionHandler(.cancel)
            if isMainFrame, let tab {
                note(tab, "Blocked: the local-only rules could not be set up (\(rulesFailure ?? "not ready")), "
                     + "so nothing loads.")
            }
            return
        }
        // A new document of a page whose channel a flood cut: open again
        // before it starts — its relay looks for the channel at document start.
        if isMainFrame, let tab { reopenChannelIfCut(webView, tab: tab) }
        decisionHandler(.allow)
    }

    private func reopenChannelIfCut(_ webView: WKWebView, tab: BrowserTabsModel.TabID) {
        guard runtimes[tab]?.channelCut == true, let messageProxy else { return }
        webView.configuration.userContentController.add(messageProxy, contentWorld: AgentScripts.world,
                                                        name: AgentScripts.messageHandlerName)
        runtimes[tab]?.channelCut = false
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
        // A navigation that skipped the policy (a reload, history): the
        // channel a flood cut is open again for the documents after this one.
        reopenChannelIfCut(webView, tab: tab)
        // A new document: a dialog or chooser of the old one can no longer
        // be answered, and scripts running in it will never answer.
        if dialogs[tab] != nil {
            dismissDialog(tab)
            note(tab, "A dialog of the previous page was dismissed.")
        }
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
        guard let tab = controller.tabID(of: webView), runtimes[tab] != nil else { return }
        let now = Self.clock()
        runtimes[tab]?.crashTimes.removeAll { now - $0 > 60 }
        runtimes[tab]?.crashTimes.append(now)
        let reload = (runtimes[tab]?.crashTimes.count ?? 0) <= 2
        runtimes[tab]?.tracker.terminated(reloading: reload)
        interruptCalls(tab, .crashed)
        dismissDialog(tab)
        if reload {
            note(tab, "The page's process stopped; it was reloaded.")
            webView.reload()
        } else {
            note(tab, "The page's process keeps stopping; it was not reloaded — browser_navigate loads it again.")
        }
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
              !refusedByNetworkAccess(url),
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

/// A compiled rule list crossing WebKit's callback: built and read on the
/// main thread.
struct CompiledRules: @unchecked Sendable {
    let list: WKContentRuleList?
    let error: String?
}

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
    /// When the page's process stopped, the last minute: a page that keeps
    /// crashing is not reloaded forever.
    var crashTimes: [Double] = []
    /// The page flooded its channel: the handler is off until the next document.
    var channelCut = false
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

    /// A file chooser's answer: these files, or nil to cancel.
    func provide(_ files: [URL]?) {
        switch self {
        case .files(let done): done(files)
        default: dismiss()
        }
    }
}

/// The page hook's channel. Weak towards the browser: the user content
/// controller retains its handlers.
final class AgentMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AgentBrowser?
    /// Messages per web view in the current second. The relay bounds each
    /// frame; a page that multiplies its frames to flood anyway has its
    /// channel cut — WebKit decodes every message on the main thread.
    private var windows: [ObjectIdentifier: (start: TimeInterval, count: Int)] = [:]
    static let floodPerSecond = 2_000

    init(owner: AgentBrowser) {
        self.owner = owner
    }

    func forget(_ userContentController: WKUserContentController) {
        windows[ObjectIdentifier(userContentController)] = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let key = ObjectIdentifier(userContentController)
        let now = ProcessInfo.processInfo.systemUptime
        var window = windows[key] ?? (now, 0)
        if now - window.start >= 1 { window = (now, 0) }
        window.count += 1
        windows[key] = window
        if window.count > Self.floodPerSecond {
            windows[key] = nil
            userContentController.removeScriptMessageHandler(forName: AgentScripts.messageHandlerName,
                                                             contentWorld: AgentScripts.world)
            if let webView = message.webView {
                MainActor.assumeIsolated { owner?.channelCut(for: webView) }
            }
            return
        }
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

// MARK: - The engine the app sees

extension AgentBrowser: AgentBrowserEngine {
    public var engine: APIBrowserEngine { .webkit }
    public var panelContent: AgentBrowserPanelContent { .webKit(controller) }
}
