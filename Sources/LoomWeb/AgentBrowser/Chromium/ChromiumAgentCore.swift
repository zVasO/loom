import CoreGraphics
import Dispatch
import Foundation
import LoomChromium
import LoomExtensions

// ChromiumAgentCore — one session's agent browser on Chromium (ADR-0016,
// design §3.5): its tabs, its queue of commands with their deadlines, its
// lease on the profile's Chromium. An actor: no command runs on the main
// thread, and the panel's copy of its state is published whole at every
// change (ChromiumBrowserState, applied in order on main by the facade).
//
// Queue      run(_:options:deadline:)   FIFO, as AgentBrowser.run/runNow: a
//                                       command whose turn comes too late does
//                                       not run; cancelAll fails what waits.
//            the panel's operations     the same queue, refused while the
//                                       agent holds the browser.
// Tabs       at most 10, at most 3 live (least recently used released, its
//            address and title kept); a released tab comes back at its address.
// Lease      taken at the first page command (or when the panel shows a
//            tab), let go at suspend and tearDown. Chromium stopping marks the
//            tabs released; the next command launches it again.
// Popups     ChromiumCoreRouter answers Chromium on the reader queue at once
//            (the opener is blocked until its popup runs); the core adopts
//            them at its next turn.

/// What the side panel and the facade mirror of the browser: published whole
/// at every change, applied in order on the main actor.
struct ChromiumBrowserState: Sendable, Equatable {
    var activity: AgentActivity?
    var activeDialog: AgentModalState?
    /// Which dialog the banner shows: its answer names it, so that it never
    /// lands on a later one or another tab's.
    var shownDialog: ChromiumShownDialog? = nil
    var viewportWidth: ViewportWidth
    /// The CSS size the pages lay out at.
    var viewport: CGSize
    var tabs: [BrowserTabsModel.Tab]
    var activeTab: BrowserTabsModel.TabID?
    /// The live tabs' connection and session: their screencast.
    var sources: [BrowserTabsModel.TabID: ChromiumScreencastSource]
    var isLoading: Bool
    var statusMessage: String?
}

struct ChromiumShownDialog: Sendable, Equatable {
    let tab: BrowserTabsModel.TabID
    /// The dialog's ledger id.
    let dialog: Int
}

/// What the person does from the panel. Run between the agent's commands,
/// refused while one runs or waits.
enum ChromiumUserOperation: Sendable, Equatable {
    case navigate(URL)
    case goBack
    case goForward
    case reload
    case stopLoading
    case select(BrowserTabsModel.TabID)
    case close(BrowserTabsModel.TabID)
    case newTab
    /// The panel shows the browser: the current tab comes back if released.
    case materialize
}

// MARK: - Control

/// What must change at once from any thread, without waiting for the core's
/// turn: the cancel generation and the command it stops, whether the agent
/// holds the browser, the network setting.
final class ChromiumCoreControl: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var reason = "the browser's commands were cancelled"
    private var running: Task<AgentResult, Error>?
    private var pending = 0
    private var access: AgentNetworkAccess

    init(networkAccess: AgentNetworkAccess) {
        access = networkAccess
    }

    var cancellation: (generation: Int, reason: String) {
        lock.withLock { (generation: generation, reason: reason) }
    }

    /// Pending and running commands fail at once with `newReason`.
    func cancelAll(_ newReason: String) {
        let task: Task<AgentResult, Error>? = lock.withLock {
            generation += 1
            reason = newReason
            return running
        }
        task?.cancel()
    }

    func setRunning(_ task: Task<AgentResult, Error>?) {
        lock.withLock { running = task }
    }

    /// Registers a command's worker. A `cancelAll` that came after the
    /// command read `expected` (from another thread, between the two) did
    /// not see this worker: it is cancelled here instead, never run.
    func setRunning(_ task: Task<AgentResult, Error>, generation expected: Int) {
        let current = lock.withLock { () -> Bool in
            running = task
            return generation == expected
        }
        if !current { task.cancel() }
    }

    func beginCommand() {
        lock.withLock { pending += 1 }
    }

    func endCommand() {
        lock.withLock { pending = max(0, pending - 1) }
    }

    /// An agent command runs or waits for its turn.
    var isBusy: Bool {
        lock.withLock { pending > 0 }
    }

    var networkAccess: AgentNetworkAccess {
        lock.withLock { access }
    }

    /// True when local-only mode was just turned on.
    func setNetworkAccess(_ value: AgentNetworkAccess) -> Bool {
        lock.withLock {
            let wasOpen = access == .open
            access = value
            return wasOpen && value != .open
        }
    }
}

// MARK: - Router

/// What the router tells the core at its next turn.
enum ChromiumRouterEvent {
    /// A popup one of the session's pages opened: initialized and running.
    case popup(ChromiumTabRuntime, openerTargetId: String?)
    /// A tab gone — closed by its page, or by the policy (with a note for its opener).
    case removed(targetId: String, openerTargetId: String?, note: String?)
    /// For a tab's next answer (nil: the active tab's).
    case note(targetId: String?, String)
    /// The process (this browser) is gone with every tab.
    case browserClosed(ObjectIdentifier, reason: String)
}

/// The session's `ChromiumTargetOwner`. Chromium's callbacks come on the
/// connection's reader queue, in wire order: each is applied at once and
/// never waits — a popup's opener stays blocked in `window.open` until the
/// popup runs, whatever command is pending. The core reads what happened at
/// its next turn (`drain`), poked through `onChange`.
final class ChromiumCoreRouter: ChromiumTargetOwner, @unchecked Sendable {

    static let maxTabs = 10

    private let log: @Sendable (String) -> Void

    // Guarded by `lock`.
    private let lock = NSLock()
    private var browser: ChromiumBrowser?
    private var userAgent: ChromiumUserAgent?
    private var viewport: CGSize
    private var access: AgentNetworkAccess
    private var tabCount = 0
    private var runtimes: [String: ChromiumTabRuntime] = [:]
    /// Popups not yet on an http(s) page, by target, with their opener ("" for none).
    private var popups: [String: String] = [:]
    private var inbox: [ChromiumRouterEvent] = []
    private var refreshPending = false
    private var onChange: (@Sendable () -> Void)?

    init(viewport: CGSize, access: AgentNetworkAccess, log: @escaping @Sendable (String) -> Void) {
        self.viewport = viewport
        self.access = access
        self.log = log
    }

    // MARK: Set by the core

    /// Called (once per batch of events) when the core has something to read.
    func setOnChange(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { onChange = handler }
    }

    func attach(browser newBrowser: ChromiumBrowser, userAgent agent: ChromiumUserAgent) {
        lock.withLock {
            browser = newBrowser
            userAgent = agent
        }
    }

    /// The lease is let go: what remains of its targets is the core's to close.
    func detachBrowser() {
        lock.withLock {
            browser = nil
            runtimes.removeAll()
            popups.removeAll()
        }
    }

    func update(viewport size: CGSize) {
        lock.withLock { viewport = size }
    }

    func update(access value: AgentNetworkAccess) {
        lock.withLock { access = value }
    }

    func update(tabCount count: Int) {
        lock.withLock { tabCount = count }
    }

    /// One of the core's own tabs: its crash, title, download and close are routed to it.
    func register(_ runtime: ChromiumTabRuntime) {
        lock.withLock { runtimes[runtime.targetId] = runtime }
        observe(runtime)
    }

    /// Closed by the core: its detach is no news.
    func unregister(_ targetId: String) {
        lock.withLock {
            runtimes[targetId] = nil
            popups[targetId] = nil
        }
    }

    /// What happened since the last call, oldest first.
    func drain() -> [ChromiumRouterEvent] {
        lock.withLock {
            refreshPending = false
            let events = inbox
            inbox = []
            return events
        }
    }

    // MARK: ChromiumTargetOwner (reader queue)

    func attached(target: ChromiumTarget, openerTargetId: String?, url: String) {
        lock.lock()
        guard let browser else {
            lock.unlock()
            return
        }
        var refusal: String?
        if browser.isClosed || userAgent == nil {
            refusal = "Blocked a popup: the agent's browser was not ready for it."
        } else if tabCount >= Self.maxTabs {
            refusal = "Blocked a popup: the agent's browser keeps at most \(Self.maxTabs) tabs."
        } else if !Self.admitsPopup(url: url, access: access) {
            refusal = "Blocked a popup to \(Self.shortened(url))."
        }
        guard refusal == nil, let agent = userAgent else {
            inbox.append(.note(targetId: openerTargetId, refusal ?? "Blocked a popup."))
            lock.unlock()
            // Resumed, then closed, in that order on the pipe: closed while
            // still paused, the opener's window.open — and the click that
            // called it — would never return (review probe, both binaries).
            browser.resume(target)
            browser.closeTarget(target.targetId)
            scheduleRefresh()
            return
        }
        let runtime = ChromiumTabRuntime(browser: browser, target: target, viewport: viewport, userAgent: agent,
                                         log: log)
        runtimes[target.targetId] = runtime
        popups[target.targetId] = openerTargetId ?? ""
        tabCount += 1
        lock.unlock()
        // Its init, then it runs — and the opener's window.open returns. Only
        // then does the core hear of it: a core that refused it before it
        // started would close it paused, the opener blocked for good.
        observe(runtime)
        runtime.start()
        lock.withLock { inbox.append(.popup(runtime, openerTargetId: openerTargetId)) }
        scheduleRefresh()
    }

    func targetInfoChanged(targetId: String, url: String, title: String) {
        // PageSignals turns it into a `.targetInfo` fact: policed and shown from there.
        runtime(targetId)?.noteTargetInfo(title: title, url: url)
    }

    func detached(targetId: String) {
        let runtime: ChromiumTabRuntime? = lock.withLock {
            let removed = runtimes.removeValue(forKey: targetId)
            popups[targetId] = nil
            if removed != nil {
                inbox.append(.removed(targetId: targetId, openerTargetId: nil, note: nil))
            }
            return removed
        }
        guard let runtime else { return }
        // A settle waiting on it ends now; its sinks go.
        runtime.noteDetached(reason: "closed")
        runtime.forget()
        scheduleRefresh()
    }

    func crashed(targetId: String) {
        runtime(targetId)?.noteCrashed()
        scheduleRefresh()
    }

    func downloadStarted(targetId: String, url: String) {
        runtime(targetId)?.noteDownload(url: url)
    }

    /// Any thread. Only the browser in use: a browser let go earlier says nothing to this session.
    func browserClosed(reason: String) {
        lock.lock()
        guard let current = browser, current.isClosed else {
            lock.unlock()
            return
        }
        let gone = Array(runtimes.values)
        runtimes.removeAll()
        popups.removeAll()
        browser = nil
        inbox.append(.browserClosed(ObjectIdentifier(current), reason: reason))
        lock.unlock()
        for runtime in gone {
            runtime.noteDetached(reason: reason)
            runtime.forget()
        }
        scheduleRefresh()
    }

    func target(ofFrame frameId: String) -> String? {
        let all: [(String, ChromiumTabRuntime)] = lock.withLock { runtimes.map { ($0.key, $0.value) } }
        return all.first { $0.1.ownsFrame(frameId) }?.0
    }

    // MARK: Facts

    private func runtime(_ targetId: String) -> ChromiumTabRuntime? {
        lock.withLock { runtimes[targetId] }
    }

    private func observe(_ runtime: ChromiumTabRuntime) {
        let targetId = runtime.targetId
        runtime.setObserver { [weak self] fact in
            self?.fact(fact, targetId: targetId)
        }
    }

    private func fact(_ fact: PageFact, targetId: String) {
        switch fact {
        case .committed(let url, _, _, _):
            police(url, targetId: targetId, committed: true)
        case .targetInfo(_, let url):
            police(url, targetId: targetId, committed: false)
        default:
            break
        }
        scheduleRefresh()
    }

    /// A main frame on something else than http(s) or about:blank — a blob:,
    /// data: or file: page a script reached (Chromium commits some): a popup
    /// is closed, a tab sent back to about:blank. Chromium's own error page
    /// (a load that failed) is not one.
    private func police(_ url: String, targetId: String, committed: Bool) {
        let refused = Self.refusesMainFrame(url)
        lock.lock()
        let runtime = runtimes[targetId]
        let opener = popups[targetId]
        if !refused, committed, opener != nil, Self.isWebAddress(url) {
            // On a page of its own now: an ordinary tab.
            popups[targetId] = nil
        }
        guard refused, let runtime else {
            lock.unlock()
            return
        }
        if let opener {
            runtimes[targetId] = nil
            popups[targetId] = nil
            inbox.append(.removed(targetId: targetId, openerTargetId: opener.isEmpty ? nil : opener,
                                  note: "Blocked a popup to \(Self.shortened(url)) — http(s) only."))
            lock.unlock()
            runtime.close()
            return
        }
        lock.unlock()
        guard committed else { return }
        runtime.note("Blocked a navigation to \(Self.shortened(url)) — http(s) only.")
        runtime.post("Page.navigate", ["url": "about:blank"])
    }

    private func scheduleRefresh() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !refreshPending, let onChange else { return nil }
            refreshPending = true
            return onChange
        }
        handler?()
    }

    // MARK: Policy (pure)

    /// A main-frame address the agent's browser does not show: anything but
    /// http(s) with a host and about:blank — Chromium's error page aside.
    static func refusesMainFrame(_ url: String) -> Bool {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return false }
        let lower = address.lowercased()
        if lower.hasPrefix("chrome-error:") || lower == "about:blank" || lower.hasPrefix("about:blank#") {
            return false
        }
        return !ChromiumBrowser.isOpenable(address)
    }

    /// A popup's first address: none yet (it comes with its first load),
    /// about:blank (a page writing into it, OAuth), or an http(s) address
    /// the network setting allows.
    static func admitsPopup(url: String, access: AgentNetworkAccess) -> Bool {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty || address.lowercased() == "about:blank" { return true }
        guard ChromiumBrowser.isOpenable(address), let parsed = URL(string: address) else { return false }
        return AgentNavigationPolicy.decide(url: parsed, isMainFrame: true) == .allow
            && !AgentNetworkRules.refuses(parsed, under: access)
    }

    static func isWebAddress(_ url: String) -> Bool {
        url.lowercased() != "about:blank" && ChromiumBrowser.isOpenable(url)
    }

    static func shortened(_ url: String) -> String {
        url.count > 200 ? String(url.prefix(200)) + "…" : url
    }
}

// MARK: - The core

actor ChromiumAgentCore {

    /// Tabs with a page of their own; the others keep their address and title.
    static let maxLiveTabs = 3
    static let maxTabs = ChromiumCoreRouter.maxTabs

    static let enterKey = KeySpec(key: "Enter", code: "Enter", keyCode: 13)
    static let deleteKey = KeySpec(key: "Delete", code: "Delete", keyCode: 46)

    private struct Tab {
        let id: BrowserTabsModel.TabID
        var url: String
        var title: String
        var runtime: ChromiumTabRuntime?
        /// For the tab's next answer while it has no page.
        var notes: [String] = []
        /// A command timed out on it: its script may never yield.
        var suspectStuck = false
        /// Released to keep 3 live: said when it comes back.
        var wasUnloaded = false
        /// The tab whose page opened this one (window.open with its opener):
        /// the two share a process, and a dialog in either holds both.
        var opener: BrowserTabsModel.TabID?
    }

    /// How an action ended: its settle, what the page said after it (the
    /// barrier's or the snapshot's facts: focus, checked), the snapshot.
    private struct Settled {
        var outcome: SettleOutcome
        var facts: CDPObject?
        var yaml: String?
    }

    private enum Work: Sendable {
        case user(ChromiumUserOperation)
        case applyViewport
    }

    let profile: AgentBrowserProfile.Kind
    nonisolated let control: ChromiumCoreControl
    nonisolated let router: ChromiumCoreRouter

    private let pool: ChromiumPool
    private let environment: AgentBrowser.Environment
    private let updates: AsyncStream<ChromiumBrowserState>.Continuation
    private let log: @Sendable (String) -> Void

    private var lease: ChromiumLease?
    /// The network mode the lease's Chromium was asked for: another one in
    /// force means its pages must not serve the next command.
    private var leaseMode: ChromiumNetworkMode?
    private var acquiring: Task<ChromiumLease, Error>?
    private var acquiringMode: ChromiumNetworkMode?
    /// Bumped whenever the lease is let go: an acquisition that ends after
    /// that is released at once.
    private var leaseEpoch = 0
    private var tabs: [Tab] = []
    /// From least to most recently used.
    private var usage: [BrowserTabsModel.TabID] = []
    private var activeTab: BrowserTabsModel.TabID?
    private var queueTail: Task<Void, Never>?
    /// The running command's options: commands run one at a time.
    private var currentOptions = AgentCommandOptions()
    private var activity: AgentActivity?
    private var viewportWidth: ViewportWidth
    /// The panel's page area in points, once it was shown.
    private var panelSize: CGSize?
    private var viewportQueued = false
    private var screenshotSequence = 0
    private var launching = false
    private var launchFailure: String?
    private var transient: (text: String, token: Int)?
    private var transientToken = 0
    private var tornDown = false
    /// The session ended (`suspend`) and no agent command came since: only
    /// the panel holds its pages.
    private var suspended = false

    init(profile: AgentBrowserProfile.Kind, environment: AgentBrowser.Environment, pool: ChromiumPool,
         updates: AsyncStream<ChromiumBrowserState>.Continuation,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.profile = profile
        self.environment = environment
        self.pool = pool
        self.updates = updates
        self.log = log
        self.viewportWidth = environment.viewportWidth
        self.control = ChromiumCoreControl(networkAccess: environment.networkAccess)
        self.router = ChromiumCoreRouter(
            viewport: ChromiumAgentCore.cssViewport(width: environment.viewportWidth, panel: nil,
                                                    initial: environment.initialViewport),
            access: environment.networkAccess, log: log)
    }

    private var key: ChromiumProfileKey {
        switch profile {
        case .project(let identifier): return .project(identifier)
        case .private: return .privateShared
        }
    }

    // MARK: - From any thread

    /// Pending and running commands fail at once (the tools were turned off,
    /// the session ended).
    nonisolated func cancelAll(_ reason: String) {
        control.cancelAll(reason)
    }

    /// Chromium takes its network at launch: the pool stops the processes on
    /// the old setting (their pages reload at the next command). Here, the
    /// refusals' words and the popups' policy; turned on, what waits goes.
    nonisolated func setNetworkAccess(_ access: AgentNetworkAccess) {
        let turnedOn = control.setNetworkAccess(access)
        router.update(access: access)
        if turnedOn {
            control.cancelAll("Local sites only was turned on: the pages were loaded again under it.")
        }
    }

    // MARK: - Commands

    /// Runs `command` after the ones before it, within `deadline`.
    func run(_ command: AgentCommand, options: AgentCommandOptions,
             deadline: ContinuousClock.Instant) async throws -> AgentResult {
        if tornDown { throw AgentError.unavailable("the browser was closed") }
        let previous = queueTail
        let generation = control.cancellation.generation
        control.beginCommand()
        let job = Task<AgentResult, Error> {
            defer { self.control.endCommand() }
            _ = await previous?.value
            return try await self.begin(command, options: options, deadline: deadline, generation: generation)
        }
        queueTail = Task { _ = try? await job.value }
        // The caller's wait is bounded even while the job queues or overruns:
        // the app answers before the client gives up (APIProtocol.clientTimeout).
        let answer = OneShot<AgentResult>()
        let forward = Task {
            do {
                let value = try await job.value
                answer.resolve(.success(value))
            } catch {
                answer.resolve(.failure(error))
            }
        }
        let backstop = Task {
            do { try await Task.sleep(until: deadline + .seconds(2), clock: .continuous) } catch { return }
            answer.resolve(.failure(AgentError.timeout(
                "another browser command was still running when this one's time ran out")))
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

    private func begin(_ command: AgentCommand, options: AgentCommandOptions, deadline: ContinuousClock.Instant,
                       generation: Int) async throws -> AgentResult {
        let cancellation = control.cancellation
        guard generation == cancellation.generation, !Task.isCancelled else {
            throw AgentError.unavailable(cancellation.reason)
        }
        if tornDown { throw AgentError.unavailable("the browser was closed") }
        // Its turn came too late: it never acts on the page only to report a timeout.
        guard ContinuousClock.now < deadline - .seconds(1) else {
            throw AgentError.timeout("another browser command was still running when this one's time ran out; it did not run")
        }
        return try await runNow(command, options: options, deadline: deadline, generation: generation)
    }

    private func runNow(_ command: AgentCommand, options: AgentCommandOptions, deadline: ContinuousClock.Instant,
                        generation: Int) async throws -> AgentResult {
        suspended = false
        currentOptions = options
        activity = AgentActivity(summary: Self.summary(of: command), isRunning: true, at: Date())
        emitState()
        let worker = Task<AgentResult, Error> {
            try await self.execute(command, deadline: deadline)
        }
        control.setRunning(worker, generation: generation)
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            worker.cancel()
        }
        defer {
            timer.cancel()
            control.setRunning(nil)
            currentOptions = AgentCommandOptions()
            activity = activity.map { AgentActivity(summary: $0.summary, isRunning: false, at: Date()) }
            drainRouter()
            emitState()
        }
        do {
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            let mapped = commandError(error, deadline: deadline, generation: generation)
            if let agent = mapped as? AgentError, case .timeout = agent {
                // Another tab's dialog held the page: that is what to say.
                if let id = activeTab, let other = dialogElsewhere(than: id, relatedOnly: false) {
                    throw dialogHolds(at: other)
                }
                markSuspect()
            }
            throw mapped
        }
    }

    private func commandError(_ error: Error, deadline: ContinuousClock.Instant, generation: Int) -> Error {
        var cancelled = error is CancellationError
        if let cdp = error as? CDPError, cdp == .cancelled { cancelled = true }
        if cancelled {
            if ContinuousClock.now >= deadline { return AgentError.timeout("the command did not finish in time") }
            let cancellation = control.cancellation
            if generation != cancellation.generation { return AgentError.unavailable(cancellation.reason) }
            return AgentError.unavailable("the command was cancelled")
        }
        if let agent = error as? AgentError { return agent }
        if error is CDPError { return ChromiumTabRuntime.agentError(error) }
        if let poolError = error as? ChromiumPoolError { return AgentError.unavailable(poolError.description) }
        if let browserError = error as? ChromiumBrowserError { return AgentError.unavailable(browserError.description) }
        return AgentError.failed(String(describing: error))
    }

    private func execute(_ command: AgentCommand, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        try Task.checkCancellation()
        if tornDown { throw AgentError.unavailable("the browser was closed") }
        switch command {
        case .navigate(let url):
            let (id, runtime, outcome) = try await openPage(url, deadline: deadline)
            // Still loading: the address asked for, the old page's may still show.
            let shown = runtime.url.isEmpty || outcome == .stillLoading ? url.absoluteString : runtime.url
            return await respondWithSnapshot("Navigated to \(shown)", id: id, runtime: runtime, deadline: deadline)
        case .navigateBack:
            return try await navigateBack(deadline: deadline)
        case .snapshot(let target, let depth):
            return try await snapshot(target: target, depth: depth, deadline: deadline)
        case .click(let target, let doubleClick, let button, let modifiers):
            return try await click(target, doubleClick: doubleClick, button: button, modifiers: modifiers,
                                   deadline: deadline)
        case .type(let target, let text, let submit, let slowly):
            return try await typeText(text, into: target, submit: submit, slowly: slowly, deadline: deadline)
        case .selectOption(let target, let values):
            return try await selectOption(values, in: target, deadline: deadline)
        case .hover(let target):
            return try await hover(target, deadline: deadline)
        case .pressKey(let key):
            return try await pressKey(key, deadline: deadline)
        case .waitFor(let time, let text, let textGone, let timeout):
            return try await waitFor(time: time, text: text, textGone: textGone, timeout: timeout, deadline: deadline)
        case .screenshot(let target, let format, let fullPage):
            return try await screenshot(target: target, format: format, fullPage: fullPage, deadline: deadline)
        case .console(let level, let all):
            let (id, runtime) = try await currentTab(deadline: deadline, recoverCrash: false, pageCalls: false)
            let text = runtime.renderConsole(level: level, all: all, limit: environment.limits.consoleChars)
            return respond(text, id: id, runtime: runtime, snapshot: nil)
        case .network(let filter):
            let (id, runtime) = try await currentTab(deadline: deadline, recoverCrash: false, pageCalls: false)
            let text = runtime.renderNetwork(filter: filter, limit: environment.limits.networkChars)
            return respond(text, id: id, runtime: runtime, snapshot: nil)
        case .evaluate(let function, let target):
            return try await evaluate(function, target: target, deadline: deadline)
        case .handleDialog(let accept, let promptText):
            return try await handleDialog(accept: accept, promptText: promptText, deadline: deadline)
        case .tabs(let action):
            return try await tabsCommand(action, deadline: deadline)
        case .close:
            closeAll(releasing: false)
            return AgentResult(text: "### Result\nClosed every tab of the agent's browser. Its profile (cookies, storage) is kept.")
        case .fillForm(let fields):
            return try await fillForm(fields, deadline: deadline)
        case .fileUpload(let paths):
            return try await fileUpload(paths, deadline: deadline)
        case .resize(let width):
            return try await resize(to: width, deadline: deadline)
        case .runCode(let code):
            return try await runCode(code, deadline: deadline, host: ChromiumRunHost(options: currentOptions, environment: environment, page: { try await (self.activeTab == nil ? self.newTab(url: nil, deadline: $0) : self.currentTab(deadline: $0)).1 }, respond: { result, page, yaml in self.respond(result, id: self.tabs.first(where: { $0.runtime === page })?.id ?? BrowserTabsModel.TabID(rawValue: UUID()), runtime: page, snapshot: yaml) }, activity: { self.activity = AgentActivity(summary: $0, isRunning: true, at: Date()); self.emitState() }, resize: { self.viewportWidth = $0; await self.applyViewport() }))
        }
    }

    // MARK: - Navigation

    /// The active tab at `url` — a new tab when there is none — loaded. A
    /// released or broken tab comes back at the new address: the old page is
    /// never fetched.
    private func openPage(_ url: URL, deadline: ContinuousClock.Instant) async throws
        -> (BrowserTabsModel.TabID, ChromiumTabRuntime, SettleOutcome) {
        try refuseOutsideNetworkAccess(url)
        try Self.refuseScheme(url)
        drainRouter()
        let address = url.absoluteString
        let id: BrowserTabsModel.TabID
        let runtime: ChromiumTabRuntime
        if let active = activeTab, let index = position(of: active) {
            id = active
            if let live = tabs[index].runtime, !live.isDetached, !live.isCrashed {
                if !live.blocksPage, let other = dialogElsewhere(than: id, relatedOnly: true) {
                    throw dialogHolds(at: other)
                }
                if live.dialog != nil {
                    // Leaving the page answers its dialog, as a browser does.
                    live.dismissDialog()
                    live.note("The page's dialog was dismissed by the navigation.")
                }
                runtime = try await responsive(id, live, replaceAt: "about:blank",
                                               note: "The previous page was stuck in a script: it was replaced by a fresh one.",
                                               force: true, deadline: deadline)
            } else {
                discardRuntime(at: index)
                tabs[index].url = "about:blank"
                runtime = try await restore(id, deadline: deadline)
            }
        } else {
            guard tabs.count < Self.maxTabs else { throw Self.tooManyTabs }
            runtime = try await makeRuntime(deadline: deadline)
            id = adopt(runtime)
        }
        if let index = position(of: id) { tabs[index].url = address }
        let outcome = try await load(address, in: runtime, cap: .seconds(30), deadline: deadline)
        return (id, runtime, outcome)
    }

    /// `Page.navigate` (http(s) and about:blank only), then its load. The
    /// agent is the one leaving: a "leave site?" is accepted. Throws what the
    /// agent must hear: a failed load, a download, a dead page.
    @discardableResult
    private func load(_ address: String, in runtime: ChromiumTabRuntime, cap: Duration,
                      deadline: ContinuousClock.Instant) async throws -> SettleOutcome {
        runtime.setAutoAcceptBeforeUnload(true)
        defer { runtime.setAutoAcceptBeforeUnload(false) }
        let end = min(deadline - .seconds(1), ContinuousClock.now + cap)
        let mark = runtime.mark()
        let navigation: ChromiumNavigation
        do {
            navigation = try await runtime.navigate(to: address, deadline: end)
        } catch CDPError.interrupted(.dialogOpened) {
            // The page parked a dialog meanwhile: the answer shows it.
            return .modal
        } catch CDPError.timeout {
            // Page.navigate answers at the commit (review probe): a server
            // slower than the cap is still loading, as the WebKit engine says.
            if let note = SettleOutcome.stillLoading.note { runtime.note(note) }
            return .stillLoading
        }
        let url = URL(string: address)
        if navigation.isDownload {
            throw AgentError.failed("the address is a download; downloads are refused (\(address))")
        }
        if let errorText = navigation.errorText,
           let message = Self.loadFailure(errorText: errorText, url: url, localOnly: isLocalOnly) {
            throw AgentError.failed(message)
        }
        let outcome = await runtime.settle(kind: .navigation(loaderId: navigation.loaderId), from: mark, deadline: end)
        try Task.checkCancellation()
        switch outcome {
        case .failed(let errorText):
            throw AgentError.failed(Self.loadFailure(errorText: errorText, url: url, localOnly: isLocalOnly)
                                    ?? "could not load \(address)")
        case .crashed:
            throw AgentError.unavailable("the page's process stopped during the command")
        case .detached:
            throw AgentError.unavailable("the tab was closed during the command")
        case .stillLoading:
            if let note = outcome.note { runtime.note(note) }
        case .quiet, .loaded, .modal:
            break
        }
        return outcome
    }

    private func navigateBack(deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        // The page's thread is blocked on its dialog: the load would wait too.
        try Self.refuseWhileDialog(runtime)
        // Its failure is the answer, not a note for the next one.
        let settled = try await goBack(runtime, deadline: deadline, notesFailure: false)
        if case .failed(let errorText) = settled.outcome {
            let address = runtime.lastRequestedAddress.flatMap { URL(string: $0) } ?? URL(string: runtime.url)
            throw AgentError.failed(Self.loadFailure(errorText: errorText, url: address,
                                                     localOnly: isLocalOnly) ?? "the previous page could not be loaded")
        }
        let shown = runtime.url.isEmpty ? "the previous page" : runtime.url
        return respond("Went back to \(shown)", id: id, runtime: runtime, snapshot: settled.yaml)
    }

    /// The previous history entry, its load followed as an action's: the
    /// reply comes before the navigation shows, the barrier sees it start.
    private func goBack(_ runtime: ChromiumTabRuntime, deadline: ContinuousClock.Instant,
                        notesFailure: Bool = true) async throws -> Settled {
        runtime.setAutoAcceptBeforeUnload(true)
        defer { runtime.setAutoAcceptBeforeUnload(false) }
        let mark = runtime.mark()
        let went: Bool
        do {
            went = try await runtime.goBack(deadline: deadline - .seconds(1))
        } catch CDPError.interrupted(.dialogOpened) {
            went = true
        }
        guard went else { throw AgentError.invalid("there is nothing to go back to") }
        return try await settleAction(runtime, mark: mark, deadline: deadline, notesFailure: notesFailure)
    }

    // MARK: - Reading

    private func snapshot(target: String?, depth: Int?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        // Reading is fine beside a file chooser; a JS dialog holds the page.
        if runtime.blocksPage { try Self.refuseWhileDialog(runtime) }
        var args: [String: Any] = ["budget": environment.limits.snapshotChars]
        if let target { args["target"] = target }
        if let depth { args["depth"] = depth }
        let answer = try await runtime.helper("snapshot", args, deadline: deadline - .milliseconds(300))
        return respond(nil, id: id, runtime: runtime, snapshot: answer.string("yaml"))
    }

    private func waitFor(time: Double?, text: String?, textGone: String?, timeout: Double,
                         deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        if let time, time > 0 { try await Task.sleep(for: .milliseconds(Int(time * 1000))) }
        var result = time.map { "Waited \($0) s" } ?? ""
        if text != nil || textGone != nil {
            let limit = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
            var args: [String: Any] = [:]
            if let text { args["text"] = text }
            if let textGone { args["textGone"] = textGone }
            waiting: while true {
                try Self.refuseWhileDialog(runtime)
                // In the page: checked again a frame after each change, up to 2 s a call.
                let left = Self.milliseconds(ContinuousClock.now.duration(to: limit))
                args["maxMs"] = max(0, min(2_000, left))
                do {
                    let callEnd = min(deadline - .seconds(1), ContinuousClock.now + .milliseconds(max(0, min(2_000, left)) + 2_000))
                    let answer = try await runtime.helper("waitText", args, deadline: callEnd)
                    if answer.bool("found") == true { break waiting }
                } catch CDPError.interrupted(.navigated) {
                    // A new page: ask it again, once it has a document.
                    try await Task.sleep(for: .milliseconds(50))
                } catch CDPError.timeout {
                    // The page is busy (loading): ask again.
                }
                if ContinuousClock.now >= limit {
                    throw AgentError.timeout(text.map { "\"\($0)\" did not appear" }
                                             ?? "\"\(textGone ?? "")\" did not go away")
                }
            }
            result = text.map { "\"\($0)\" appeared" } ?? "\"\(textGone ?? "")\" went away"
        }
        return await respondWithSnapshot(result, id: id, runtime: runtime, deadline: deadline)
    }

    private func screenshot(target: AgentTarget?, format: ImageFormat, fullPage: Bool,
                            deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        // A JS dialog blocks the page, and its drawing with it; a file chooser does not.
        if runtime.blocksPage { try Self.refuseWhileDialog(runtime) }
        let maxEdge = environment.limits.imageMaxEdge
        let shot: ChromiumScreenshot
        var what = "the visible page"
        if fullPage {
            let info = try await runtime.helper("pageInfo", [:], deadline: deadline)
            let width = info.double("width") ?? 0
            let height = info.double("height") ?? 0
            let scrollHeight = info.double("scrollHeight") ?? 0
            guard width > 0, height > 0 else { throw AgentError.failed("the page has no size to capture") }
            let total = max(scrollHeight, height)
            // One capture past the viewport: Chromium keeps the scroll where
            // it was (the page sees a resize meanwhile).
            shot = try await runtime.capture(clip: CGRect(x: 0, y: 0, width: width, height: total), format: format,
                                             fullPage: true, maxEdge: maxEdge, deadline: deadline - .milliseconds(300))
            let cap = Double(ChromiumTabRuntime.fullPageMaxHeight)
            let cut = total > cap ? " (cut at \(Int(cap)) of \(Int(total)) CSS pixels)" : ""
            what = "the whole page, \(Int(width))×\(Int(min(total, cap))) CSS pixels\(cut)"
        } else if let target {
            let answer = try await runtime.helper("documentRect", ["target": target.target], deadline: deadline)
            guard let box = answer.object("rect"), let x = box.double("x"), let y = box.double("y"),
                  let width = box.double("width"), let height = box.double("height"), width > 0, height > 0 else {
                throw AgentError.invalid("\(target.target) has no visible box to capture")
            }
            var clip = CGRect(x: x, y: y, width: width, height: height)
            if let view = answer.object("viewport"), let viewWidth = view.double("width"),
               let viewHeight = view.double("height") {
                // Document coordinates, both: the part of the element on screen.
                clip = clip.intersection(CGRect(x: view.double("x") ?? 0, y: view.double("y") ?? 0,
                                                width: viewWidth, height: viewHeight))
            }
            guard !clip.isNull, clip.width >= 1, clip.height >= 1 else {
                throw AgentError.invalid("\(target.target) is outside the visible page")
            }
            what = answer.string("description") ?? target.target
            shot = try await runtime.capture(clip: clip, format: format, fullPage: false, maxEdge: maxEdge,
                                             deadline: deadline - .milliseconds(300))
        } else {
            shot = try await runtime.capture(clip: nil, format: format, fullPage: false, maxEdge: maxEdge,
                                             deadline: deadline - .milliseconds(300))
        }
        if screenshotSequence == 0 {
            // A resumed session's folder holds a previous run's files: the
            // numbering goes on after them, never under (they would be pruned).
            screenshotSequence = AgentScreenshot.lastSequence(in: environment.screenshotsDirectory)
        }
        screenshotSequence += 1
        let url = try AgentScreenshot.write(shot.data, in: environment.screenshotsDirectory,
                                            sequence: screenshotSequence, format: format)
        var result = respond("Screenshot of \(what), \(shot.width)×\(shot.height), saved to \(url.path)."
                             + " Use browser_snapshot to act on the page.",
                             id: id, runtime: runtime, snapshot: nil)
        result.image = AgentImage(url: url, mimeType: format.mimeType, width: shot.width, height: shot.height)
        return result
    }

    // MARK: - Acting

    private func click(_ target: AgentTarget, doubleClick: Bool, button: MouseButton, modifiers: [String],
                       deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let ready = try await prepare(target, action: "click", runtime: runtime, deadline: deadline)
        let point = try Self.point(of: ready, target: target)
        let flags = Self.modifiers(modifiers)
        let pressed = Self.button(button)
        let mark = runtime.mark()
        if doubleClick {
            // The second press only after the first one's acks: a dialog the
            // first opens never gets a ghost second click.
            _ = try await runtime.dispatch(writes: CDPInput.clicks(x: point.x, y: point.y, button: pressed, clickCount: 2,
                                                                   modifiers: flags),
                                           deadline: deadline - .seconds(1))
        } else {
            _ = try await runtime.dispatch(batch: CDPInput.click(x: point.x, y: point.y, button: pressed, modifiers: flags),
                                           deadline: deadline - .seconds(1))
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        let described = Self.described(target, ready.string("description"))
        return respond("\(doubleClick ? "Double-clicked" : "Clicked") \(described)", id: id, runtime: runtime,
                       snapshot: settled.yaml)
    }

    private func hover(_ target: AgentTarget, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let ready = try await prepare(target, action: "hover", runtime: runtime, deadline: deadline)
        let point = try Self.point(of: ready, target: target)
        let mark = runtime.mark()
        // The pointer stays there: :hover holds until the next move.
        _ = try await runtime.dispatch(batch: [CDPInput.mouseMoved(x: point.x, y: point.y)],
                                       deadline: deadline - .seconds(1))
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        return respond("Hovered \(Self.described(target, ready.string("description")))", id: id, runtime: runtime,
                       snapshot: settled.yaml)
    }

    private func typeText(_ text: String, into target: AgentTarget, submit: Bool, slowly: Bool,
                      deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        // Focused, its text selected: what is typed replaces it.
        let ready = try await prepare(target, action: "type", runtime: runtime, deadline: deadline, focus: true)
        let described = Self.described(target, ready.string("description"))
        let mark = runtime.mark()
        var how = ""
        if slowly {
            // Each character a key press, for handlers that watch keys
            // (autocomplete): 8 keys a write, each after the previous acks.
            var writes: [[(String, [String: Any])]] = [Self.deleteKey.cdpPress()]
            writes.append(contentsOf: KeySpec.cdpTypingWrites(text))
            if submit { writes.append(Self.enterKey.cdpPress()) }
            let outcome = try await runtime.dispatch(writes: writes, deadline: deadline - .seconds(1))
            how = outcome == .acked ? " one key at a time" : " (stopped: the page opened a dialog or navigated)"
        } else {
            _ = try await fill(text, ready: ready, target: target, submit: submit, runtime: runtime, deadline: deadline)
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        return respond("Typed into \(described)\(how)", id: id, runtime: runtime, snapshot: settled.yaml)
    }

    /// Text into a field `prepare` focused and selected: `Input.insertText`
    /// (trusted beforeinput and input, as an IME commits) for a text field;
    /// the helper's `type` for a picker's value (date, color, range, number).
    /// No synthetic `change`: a native one fires on Enter or blur.
    private func fill(_ text: String, ready: CDPObject, target: AgentTarget, submit: Bool,
                      runtime: ChromiumTabRuntime, deadline: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        if ready.string("fill") == "insertText" {
            var batch: [(String, [String: Any])] = text.isEmpty ? Self.deleteKey.cdpPress() : [CDPInput.insertText(text)]
            if submit { batch.append(contentsOf: Self.enterKey.cdpPress()) }
            return try await runtime.dispatch(batch: batch, deadline: deadline - .seconds(1))
        }
        do {
            _ = try await runtime.helper("type", ["target": target.target, "text": text, "submit": false],
                                         deadline: deadline)
        } catch CDPError.interrupted(.dialogOpened) {
            return .interrupted(.dialogOpened)
        } catch CDPError.interrupted(.navigated) {
            return .interrupted(.navigated)
        }
        guard submit else { return .acked }
        return try await runtime.dispatch(batch: Self.enterKey.cdpPress(), deadline: deadline - .seconds(1))
    }

    private func selectOption(_ values: [String], in target: AgentTarget,
                              deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let ready = try await prepare(target, action: "select", runtime: runtime, deadline: deadline)
        let mark = runtime.mark()
        // A native <select>'s popup cannot be driven headless: the helper sets it.
        do {
            _ = try await runtime.helper("selectOption", ["target": target.target, "values": values], deadline: deadline)
        } catch CDPError.interrupted(.dialogOpened) {
            // The change opened a dialog: the page now waits on it.
        } catch CDPError.interrupted(.navigated) {
            // The change navigated: the load is followed below.
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        let described = Self.described(target, ready.string("description"))
        return respond("Selected \(values.joined(separator: ", ")) in \(described)", id: id, runtime: runtime,
                       snapshot: settled.yaml)
    }

    private func pressKey(_ key: KeySpec, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let mark = runtime.mark()
        _ = try await runtime.dispatch(batch: key.cdpPress(), deadline: deadline - .seconds(1))
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        let focused = settled.facts?.string("focused") ?? ""
        return respond("Pressed \(Self.keyName(key))" + (focused.isEmpty ? "" : " — focus: \(focused)"),
                       id: id, runtime: runtime, snapshot: settled.yaml)
    }

    private func evaluate(_ function: String, target: AgentTarget?,
                          deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        var nonce = ""
        if let target {
            let stamped = try await runtime.helper("stamp", ["target": target.target], deadline: deadline)
            nonce = stamped.string("nonce") ?? ""
        }
        let output: String
        do {
            // At its deadline the script is stopped (Runtime.terminateExecution).
            output = try await runtime.evaluate(function, nonce: nonce, deadline: deadline - .milliseconds(500))
        } catch CDPError.interrupted(.dialogOpened) {
            return respond("The function opened a dialog; it is still waiting on it.", id: id, runtime: runtime,
                           snapshot: nil)
        }
        let limit = environment.limits.evaluateChars
        let head = output.prefix(limit)   // never a walk over a huge answer
        let shown = head.endIndex == output.endIndex ? output : String(head) + "\n… (cut at \(limit) characters)"
        return respond("```json\n\(shown)\n```", id: id, runtime: runtime, snapshot: nil)
    }

    private func handleDialog(accept: Bool, promptText: String?,
                              deadline: ContinuousClock.Instant) async throws -> AgentResult {
        drainRouter()
        guard let id = activeTab, let index = position(of: id), let runtime = tabs[index].runtime,
              !runtime.isDetached, let modal = runtime.modal else {
            if let other = tabs.firstIndex(where: { $0.id != activeTab && $0.runtime?.modal != nil }) {
                throw AgentError.invalid("no dialog is open on this tab; tab \(other) has one — browser_tabs select \(other), then answer it")
            }
            throw AgentError.invalid("no dialog is open")
        }
        let mark = runtime.mark()
        let what: String
        switch modal {
        case .fileChooser:
            await runtime.cancelFileChooser(deadline: deadline - .seconds(1))
            what = "Cancelled the file chooser"
        case .dialog(let dialog, _):
            switch runtime.answerDialog(accept: accept, promptText: promptText, dialogId: dialog.id) {
            case .success(let answered):
                what = (accept ? "Accepted" : "Dismissed") + " the dialog \(AgentModalState.quoted(answered.message))"
            case .failure:
                throw AgentError.invalid("no dialog is open")
            }
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        return respond(what, id: id, runtime: runtime, snapshot: settled.yaml)
    }

    /// Several fields in order, each when it is ready; the first failure
    /// stops the form and says which fields were filled.
    private func fillForm(_ fields: [FormField], deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let mark = runtime.mark()
        var filled: [String] = []
        form: for field in fields {
            var outcome: ChromiumInputOutcome = .acked
            do {
                outcome = try await fillField(field, runtime: runtime, deadline: deadline)
            } catch let error as CDPError {
                if case .interrupted(let reason) = error, reason == .dialogOpened || reason == .navigated {
                    outcome = .interrupted(reason)
                } else {
                    throw prefixed(ChromiumTabRuntime.agentError(error), field: field, filled: filled)
                }
            } catch let error as AgentError {
                throw prefixed(error, field: field, filled: filled)
            }
            filled.append(field.name)
            switch outcome {
            case .acked:
                continue
            case .interrupted(let reason):
                if filled.count < fields.count {
                    runtime.note(reason == .dialogOpened
                                 ? "\(field.name) opened a dialog: the fields after it were left."
                                 : "\(field.name) left the page: the fields after it were left.")
                }
                break form
            }
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        return respond("Filled \(filled.joined(separator: ", "))", id: id, runtime: runtime, snapshot: settled.yaml)
    }

    private func prefixed(_ error: Error, field: FormField, filled: [String]) -> Error {
        guard let agent = error as? AgentError else { return error }
        let done = filled.isEmpty ? "no field was filled" : "filled before it: " + filled.joined(separator: ", ")
        return agent.prefixed("\(field.name): ", suffix: " (\(done))")
    }

    private func fillField(_ field: FormField, runtime: ChromiumTabRuntime,
                           deadline: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        let target = field.target
        switch field.kind {
        case .textbox:
            let ready = try await prepare(target, action: "type", runtime: runtime, deadline: deadline, focus: true)
            return try await fill(field.value, ready: ready, target: target, submit: false, runtime: runtime,
                                  deadline: deadline)
        case .combobox:
            _ = try await prepare(target, action: "select", runtime: runtime, deadline: deadline)
            _ = try await runtime.helper("selectOption", ["target": target.target, "values": [field.value]],
                                         deadline: deadline)
            return .acked
        case .slider:
            _ = try await prepare(target, action: "click", runtime: runtime, deadline: deadline)
            _ = try await runtime.helper("setValue", ["target": target.target, "value": field.value], deadline: deadline)
            return .acked
        case .checkbox, .radio:
            let wanted = field.value == "true"
            // A trusted click only when it differs; read back after the page's turn.
            let before = try await runtime.barrier(checkedOf: target.target, deadline: deadline - .seconds(1))
            if let checked = before?.bool("checked"), checked == wanted { return .acked }
            let ready = try await prepare(target, action: "click", runtime: runtime, deadline: deadline)
            let point = try Self.point(of: ready, target: target)
            let outcome = try await runtime.dispatch(batch: CDPInput.click(x: point.x, y: point.y),
                                                     deadline: deadline - .seconds(1))
            guard outcome == .acked else { return outcome }
            let after = try await runtime.barrier(checkedOf: target.target, deadline: deadline - .seconds(1))
            if let checked = after?.bool("checked"), checked != wanted {
                throw AgentError.failed(field.kind == .radio && !wanted
                    ? "a radio is unchecked by choosing another of its group"
                    : "it stayed \(checked ? "checked" : "unchecked") — the page undid the click")
            }
            return .acked
        }
    }

    /// Answers the file chooser the page opened, with files the policy
    /// allows — checked before Chromium is told anything — or none, which
    /// cancels it.
    private func fileUpload(_ paths: [String]?, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        let (id, runtime) = try await currentTab(deadline: deadline)
        guard let modal = runtime.modal else {
            throw AgentError.invalid("no file chooser is open: click the file input first, then call browser_file_upload")
        }
        guard case .fileChooser(let chooser, _) = modal else {
            throw AgentError.conflict("the page waits on a dialog, not a file chooser: answer it with browser_handle_dialog")
        }
        var files: [URL] = []
        if let paths, !paths.isEmpty {
            let policy = AgentUploadPolicy(roots: environment.uploadRoots)
            switch policy.validate(paths, allowsMultiple: chooser.multiple) {
            case .success(let accepted): files = accepted
            case .failure(let refusal):
                throw AgentError.invalid(AgentUploadPolicy.message(for: refusal, roots: policy.roots))
            }
        }
        let mark = runtime.mark()
        let what: String
        if files.isEmpty {
            await runtime.cancelFileChooser(deadline: deadline - .seconds(1))
            what = "Cancelled the file chooser"
        } else {
            try await runtime.setFiles(files.map { $0.path }, deadline: deadline - .seconds(1))
            what = "Chose " + files.map { $0.lastPathComponent }.joined(separator: ", ")
        }
        let settled = try await settleAction(runtime, mark: mark, deadline: deadline)
        return respond(what, id: id, runtime: runtime, snapshot: settled.yaml)
    }

    private func resize(to width: ViewportWidth, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        viewportWidth = width
        await applyViewport()
        let what: String
        switch width {
        case .fit: what = "The page fits the panel again"
        case .css(let pixels): what = "The page is \(pixels) CSS pixels wide, scaled into the panel"
        }
        guard activeTab != nil else {
            return AgentResult(text: "### Result\n\(what); it applies to the next page.")
        }
        let (id, runtime) = try await currentTab(deadline: deadline)
        if currentOptions.snapshot == .none, !runtime.blocksPage {
            // The page's turn: its resize handlers ran (the snapshot waits a frame itself).
            _ = try await runtime.barrier(deadline: deadline - .seconds(1))
        }
        return await respondWithSnapshot(what, id: id, runtime: runtime, deadline: deadline)
    }

    // MARK: - Tabs

    private func tabsCommand(_ action: TabsAction, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        drainRouter()
        switch action {
        case .list:
            return AgentResult(text: "### Open tabs\n" + tabLines())
        case .new(let url):
            let (id, runtime) = try await newTab(url: url, deadline: deadline)
            return await respondWithSnapshot("Opened a new tab", id: id, runtime: runtime, deadline: deadline)
        case .select(let index):
            guard tabs.indices.contains(index) else {
                throw AgentError.invalid("no tab \(index): there are \(tabs.count)")
            }
            activate(tabs[index].id)
            var (id, runtime) = try await currentTab(deadline: deadline, pageCalls: false)
            // A call blocked on the tab's own dialog waits, it is not stuck;
            // a page merely busy loading is not either (only a call of ours
            // waiting in it, or a command that timed out on it, says so).
            if runtime.dialog == nil {
                runtime = try await responsive(id, runtime, replaceAt: runtime.url,
                                               note: "The page was stuck in a script: it was replaced by a fresh one.",
                                               force: false, deadline: deadline)
            }
            id = tabs.first(where: { $0.runtime === runtime })?.id ?? id
            await waitForLoad(runtime, limit: .seconds(10), deadline: deadline)
            return await respondWithSnapshot("Selected tab \(index)", id: id, runtime: runtime, deadline: deadline)
        case .close(let index):
            let closing = index ?? tabs.firstIndex(where: { $0.id == activeTab }) ?? -1
            guard tabs.indices.contains(closing) else { throw AgentError.invalid("no tab to close") }
            closeTab(tabs[closing].id)
            return AgentResult(text: "### Result\nClosed tab \(closing)\n\n### Open tabs\n" + tabLines())
        }
    }

    private func newTab(url: URL?, deadline: ContinuousClock.Instant) async throws
        -> (BrowserTabsModel.TabID, ChromiumTabRuntime) {
        guard tabs.count < Self.maxTabs else { throw Self.tooManyTabs }
        if let url {
            try refuseOutsideNetworkAccess(url)
            try Self.refuseScheme(url)
        }
        let runtime = try await makeRuntime(deadline: deadline)
        let id = adopt(runtime)
        if let url, url.absoluteString.lowercased() != "about:blank" {
            if let index = position(of: id) { tabs[index].url = url.absoluteString }
            // As browser_navigate: the tab stays, the failure is the answer.
            try await load(url.absoluteString, in: runtime, cap: .seconds(30), deadline: deadline)
        }
        return (id, runtime)
    }

    /// A load under way (a tab just selected): waited for, within `limit`.
    private func waitForLoad(_ runtime: ChromiumTabRuntime, limit: Duration, deadline: ContinuousClock.Instant) async {
        let mark = runtime.mark()
        let state = runtime.signals.state
        guard let loaderId = state.loaderId, !state.reached.contains("load"), !state.crashed else { return }
        let outcome = await runtime.settle(kind: .navigation(loaderId: loaderId), from: mark,
                                           deadline: min(deadline - .seconds(1), ContinuousClock.now + limit))
        if let note = outcome.note { runtime.note(note) }
    }

    private func tabLines() -> String {
        let lines = tabSummaries().map { tab in
            "- \(tab.index): " + (tab.isCurrent ? "(current) " : "") + "[\(tab.title)] (\(tab.url))"
        }
        return lines.isEmpty ? "No tab is open." : lines.joined(separator: "\n")
    }

    private func tabSummaries() -> [AgentTabSummary] {
        tabs.enumerated().map { index, tab in
            AgentTabSummary(index: index, title: displayTitle(tab), url: displayURL(tab),
                            isCurrent: tab.id == activeTab, hasDialog: tab.runtime?.modal != nil)
        }
    }

    // MARK: - Waiting

    /// After an action's acks: the barrier — or the snapshot standing for it,
    /// one `setTimeout(0)` and one frame in the page — then the settle (the
    /// load the action caused, the requests it made). The snapshot taken as
    /// the barrier is kept only when nothing at all happened since the mark;
    /// otherwise a fresh one is taken once the page settled.
    private func settleAction(_ runtime: ChromiumTabRuntime, mark: PageMark, deadline: ContinuousClock.Instant,
                              notesFailure: Bool = true) async throws -> Settled {
        let end = deadline - .seconds(1)
        let callEnd = min(end, ContinuousClock.now + .seconds(5))
        let wantsSnapshot = currentOptions.snapshot == .full
        var early: CDPObject?
        var facts: CDPObject?
        if wantsSnapshot, !runtime.blocksPage {
            do {
                early = try await runtime.helper("snapshot", ["budget": environment.limits.actionSnapshotChars,
                                                              "afterFrame": true],
                                                 deadline: callEnd, asBarrier: true)
            } catch {
                // Its outcome went to the settle (a navigation, a dialog, a busy page).
                try Self.rethrowCancellation(error)
            }
        } else {
            facts = try await runtime.barrier(deadline: callEnd)
        }
        let outcome = await runtime.settle(kind: .action, from: mark, deadline: end)
        try Task.checkCancellation()
        switch outcome {
        case .failed(let errorText):
            guard notesFailure else { break }
            // The WebKit engine's words: what failed, said as for browser_navigate.
            let address = runtime.lastRequestedAddress.flatMap { URL(string: $0) }
            let message = Self.loadFailure(errorText: errorText, url: address, localOnly: isLocalOnly) ?? errorText
            runtime.note("The page load it started failed: \(message)")
        case .stillLoading:
            if let note = outcome.note { runtime.note(note) }
        case .quiet, .loaded, .modal, .crashed, .detached:
            break
        }
        var yaml: String?
        if wantsSnapshot, !runtime.blocksPage, !runtime.isDetached {
            let unchanged = runtime.signals.events(since: mark).allSatisfy { $0.event == .barrierDone }
            if let early, unchanged {
                yaml = early.string("yaml")
                facts = early
            } else if let fresh = await snapshot(of: runtime, deadline: deadline) {
                yaml = fresh.string("yaml")
                facts = fresh
            }
        }
        return Settled(outcome: outcome, facts: facts ?? early, yaml: yaml)
    }

    /// Single-shot readiness checks (the helper's `prepare{trusted}`): for a
    /// pointer, the box unchanged over one frame and nothing over its centre;
    /// called again at once on `retry`, within 5 s. Answers the point to press.
    private func prepare(_ target: AgentTarget, action: String, runtime: ChromiumTabRuntime,
                         deadline: ContinuousClock.Instant, focus: Bool = false) async throws -> CDPObject {
        let limit = min(deadline - .seconds(1), ContinuousClock.now + .seconds(5))
        let pointer = action == "click" || action == "hover"
        var args: [String: Any] = ["target": target.target, "action": action, "trusted": true]
        if focus {
            args["focus"] = true
            args["selectAll"] = true
        }
        var reason = "it is not ready"
        while true {
            let answer = try await runtime.helper("prepare", args, deadline: deadline)
            if answer.string("status") == "ready" { return answer }
            reason = answer.string("reason") ?? reason
            if ContinuousClock.now >= limit {
                throw AgentError.timeout("\(Self.described(target, nil)) is not ready to \(action): \(reason)")
            }
            // A pointer's check already took a frame; the others are paced here.
            try await Task.sleep(for: .milliseconds(pointer ? 16 : 50))
        }
    }

    // MARK: - Answers

    /// The current tab's page — brought back, and loaded, if it was released,
    /// crashed or replaced.
    /// `recoverCrash` false: a crashed page is answered as it is — its
    /// console and requests are what says why it stopped.
    private func currentTab(deadline: ContinuousClock.Instant, recoverCrash: Bool = true,
                            pageCalls: Bool = true) async throws -> (BrowserTabsModel.TabID, ChromiumTabRuntime) {
        drainRouter()
        guard let id = activeTab, let index = position(of: id) else {
            throw AgentError.unavailable("No page is open yet — start with browser_navigate")
        }
        guard let runtime = tabs[index].runtime, !runtime.isDetached else {
            discardRuntime(at: index)
            let restored = try await restore(id, deadline: deadline)
            return (id, restored)
        }
        if runtime.isCrashed, !recoverCrash {
            return (id, runtime)
        }
        if runtime.isCrashed {
            let recovered = try await recoverCrashed(id, runtime, deadline: deadline)
            return (id, recovered)
        }
        if pageCalls, !runtime.blocksPage, let other = dialogElsewhere(than: id, relatedOnly: true) {
            throw dialogHolds(at: other)
        }
        if tabs[index].suspectStuck {
            let live = try await responsive(id, runtime, replaceAt: runtime.url,
                                            note: "The page was stuck in a script: it was replaced by a fresh one.",
                                            force: false, deadline: deadline)
            return (id, live)
        }
        return (id, runtime)
    }

    private func snapshot(of runtime: ChromiumTabRuntime, deadline: ContinuousClock.Instant) async -> CDPObject? {
        guard currentOptions.snapshot == .full, !runtime.blocksPage,
              ContinuousClock.now < deadline - .milliseconds(500) else { return nil }
        return try? await runtime.helper("snapshot", ["budget": environment.limits.actionSnapshotChars, "afterFrame": true],
                                         deadline: deadline - .milliseconds(300))
    }

    private func respondWithSnapshot(_ result: String, id: BrowserTabsModel.TabID, runtime: ChromiumTabRuntime,
                                     deadline: ContinuousClock.Instant) async -> AgentResult {
        let answer = await snapshot(of: runtime, deadline: deadline)
        return respond(result, id: id, runtime: runtime, snapshot: answer?.string("yaml"))
    }

    /// The answer: `### Result`, `### Page` (never "hidden": headless pages
    /// render whether the panel shows them or not), the tabs, the dialog,
    /// the snapshot, the notes since the last answer.
    private func respond(_ result: String?, id: BrowserTabsModel.TabID, runtime: ChromiumTabRuntime,
                         snapshot: String?) -> AgentResult {
        drainRouter()
        var events: [String] = []
        if let index = position(of: id) {
            events = tabs[index].notes
            tabs[index].notes = []
        }
        events.append(contentsOf: runtime.takeEvents())
        var page: AgentPageSummary?
        var modal: AgentModalState?
        if runtime.isDetached, position(of: id) == nil {
            events.append("The page closed its tab.")
        } else {
            var summary = runtime.pageSummary(viewportScaled: viewportWidth != .fit)
            summary.hidden = false
            if summary.url.isEmpty, let index = position(of: id) { summary.url = tabs[index].url }
            page = summary
            modal = runtime.modalState
        }
        let text = AgentResponseBuilder.render(result: result, page: page, tabs: tabSummaries(), modal: modal,
                                               snapshot: snapshot, events: events, limits: environment.limits)
        emitState()
        return AgentResult(text: text)
    }

    // MARK: - Tabs and their pages

    private func position(of id: BrowserTabsModel.TabID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    private func touch(_ id: BrowserTabsModel.TabID) {
        usage.removeAll { $0 == id }
        usage.append(id)
    }

    private func activate(_ id: BrowserTabsModel.TabID) {
        guard position(of: id) != nil else { return }
        activeTab = id
        touch(id)
        emitState()
    }

    /// A new tab of the session, active, around a live page.
    private func adopt(_ runtime: ChromiumTabRuntime) -> BrowserTabsModel.TabID {
        let id = BrowserTabsModel.TabID(rawValue: UUID())
        let address = runtime.url.isEmpty ? "about:blank" : runtime.url
        tabs.append(Tab(id: id, url: address, title: runtime.title, runtime: runtime))
        activeTab = id
        touch(id)
        enforceLiveLimit(keeping: [id])
        router.update(tabCount: tabs.count)
        emitState()
        return id
    }

    /// A target of the session's browser, attached, initialized and running
    /// (40 to 100 ms: the renderer starts meanwhile).
    private func makeRuntime(deadline: ContinuousClock.Instant) async throws -> ChromiumTabRuntime {
        var attempt = 0
        while true {
            attempt += 1
            let lease = try await ensureLease()
            let epoch = leaseEpoch
            let browser = lease.browser
            let left = max(Duration.seconds(1), min(Duration.seconds(10), ContinuousClock.now.duration(to: deadline - .seconds(1))))
            do {
                let target = try await browser.createTarget(url: "about:blank", browserContextId: lease.browserContextId,
                                                            owner: router, timeout: left)
                let runtime = ChromiumTabRuntime(browser: browser, target: target, viewport: currentViewport(),
                                                 userAgent: Self.userAgent(for: browser), log: log)
                router.register(runtime)
                runtime.start()
                do {
                    try await runtime.initialized()
                } catch {
                    router.unregister(runtime.targetId)
                    runtime.close()
                    throw error
                }
                // The session closed or let its pages go meanwhile (a panel's
                // tab under way when it ended): the page goes too, never held
                // without a lease.
                if tornDown || leaseEpoch != epoch {
                    router.unregister(runtime.targetId)
                    runtime.close()
                    throw AgentError.unavailable("the browser was closed")
                }
                if self.lease !== lease {
                    // Its Chromium stopped meanwhile: a tab on the next one.
                    router.unregister(runtime.targetId)
                    runtime.close()
                    if attempt < 2 { continue }
                    throw AgentError.unavailable("the agent's browser stopped while the tab opened")
                }
                return runtime
            } catch {
                try Self.rethrowCancellation(error)
                // The browser went meanwhile: once more, on a new one.
                if browser.isClosed, attempt < 2 {
                    browserGone(ObjectIdentifier(browser), reason: browser.closeReason ?? "Chromium stopped")
                    continue
                }
                if error is AgentError { throw error }
                throw AgentError.unavailable("the tab could not open: \(Self.message(of: error))")
            }
        }
    }

    /// The tab's page again, at its address (about:blank when it has none
    /// the policy opens): released, crashed or replaced.
    private func restore(_ id: BrowserTabsModel.TabID, deadline: ContinuousClock.Instant) async throws -> ChromiumTabRuntime {
        let runtime = try await makeRuntime(deadline: deadline)
        guard let index = position(of: id) else {
            router.unregister(runtime.targetId)
            runtime.close()
            throw AgentError.unavailable("the tab was closed during the command")
        }
        if tabs[index].runtime != nil { discardRuntime(at: index) }
        tabs[index].runtime = runtime
        for note in tabs[index].notes { runtime.note(note) }
        tabs[index].notes = []
        if tabs[index].wasUnloaded {
            tabs[index].wasUnloaded = false
            runtime.note("The tab had been unloaded (at most \(Self.maxLiveTabs) stay loaded): it was loaded again.")
        }
        touch(id)
        enforceLiveLimit(keeping: [id])
        emitState()
        let address = tabs[index].url
        if address.lowercased() != "about:blank", ChromiumBrowser.isOpenable(address) {
            do {
                try await load(address, in: runtime, cap: .seconds(10), deadline: deadline)
            } catch let error as AgentError {
                runtime.note("The page could not be loaded again: \(error.message)")
            }
        }
        return runtime
    }

    /// The page's process stopped. The runtime reloads it itself (twice a
    /// minute at most): its commit clears the crash. Otherwise a new target
    /// at the same address.
    private func recoverCrashed(_ id: BrowserTabsModel.TabID, _ runtime: ChromiumTabRuntime,
                                deadline: ContinuousClock.Instant) async throws -> ChromiumTabRuntime {
        // It kept crashing: a fresh target at each command would defeat the
        // cap (and drop its logs). As the note said, a navigation brings it back.
        if runtime.staysCrashed {
            throw AgentError.unavailable("the page's process keeps stopping — browser_navigate loads it again")
        }
        let until = min(deadline - .seconds(1), ContinuousClock.now + .milliseconds(1_500))
        while runtime.isCrashed, !runtime.isDetached, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(50))
        }
        if !runtime.isCrashed, !runtime.isDetached { return runtime }
        return try await replace(id, at: runtime.url,
                                 note: "The page's process had stopped: the page was opened again in a new one.",
                                 deadline: deadline)
    }

    /// A page whose script never yields — a command timed out on it, or a
    /// call of ours still waits in it: stopped (Runtime.terminateExecution),
    /// else replaced by a fresh target at `address`. `force`: checked even
    /// when nothing points to it (navigate, tabs select).
    private func responsive(_ id: BrowserTabsModel.TabID, _ runtime: ChromiumTabRuntime, replaceAt address: String,
                            note: String, force: Bool, deadline: ContinuousClock.Instant) async throws -> ChromiumTabRuntime {
        guard let index = position(of: id) else { return runtime }
        let suspect = tabs[index].suspectStuck || runtime.callsInFlight > 0 || force
        tabs[index].suspectStuck = false
        // Held by another tab's dialog, it is not stuck in a script: never replaced for it.
        guard suspect, !runtime.blocksPage, dialogElsewhere(than: id, relatedOnly: false) == nil,
              await runtime.isStuck() else { return runtime }
        if await runtime.unstick() {
            runtime.note("The page was stuck in a script: Loom stopped the script.")
            return runtime
        }
        return try await replace(id, at: address, note: note, deadline: deadline)
    }

    private func replace(_ id: BrowserTabsModel.TabID, at address: String, note: String?,
                         deadline: ContinuousClock.Instant) async throws -> ChromiumTabRuntime {
        guard let index = position(of: id) else { throw AgentError.unavailable("the tab was closed during the command") }
        discardRuntime(at: index)
        tabs[index].url = address.isEmpty ? "about:blank" : address
        if let note { tabs[index].notes.append(note) }
        return try await restore(id, deadline: deadline)
    }

    /// The tab's page goes (its target closed, no beforeunload); its address,
    /// title and notes stay with the tab.
    private func discardRuntime(at index: Int) {
        guard let runtime = tabs[index].runtime else { return }
        remember(index)
        tabs[index].notes.append(contentsOf: runtime.takeEvents())
        router.unregister(runtime.targetId)
        runtime.close()
        tabs[index].runtime = nil
    }

    /// The live page's address and title, kept for when it has none.
    private func remember(_ index: Int) {
        guard let runtime = tabs[index].runtime else { return }
        let address = runtime.url
        if !address.isEmpty, !address.lowercased().hasPrefix("chrome-error:") { tabs[index].url = address }
        let title = runtime.title
        if !title.isEmpty { tabs[index].title = title }
    }

    /// At most `maxLiveTabs` pages: the least recently used goes first —
    /// never the active tab, nor one in `kept`.
    private func enforceLiveLimit(keeping kept: Set<BrowserTabsModel.TabID>) {
        let live = Set(tabs.filter { $0.runtime != nil }.map { $0.id })
        var protected = kept
        if let activeTab { protected.insert(activeTab) }
        for victim in Self.releaseCandidates(usage: usage, live: live, keeping: protected, limit: Self.maxLiveTabs) {
            guard let index = position(of: victim) else { continue }
            discardRuntime(at: index)
            tabs[index].wasUnloaded = true
        }
    }

    private func closeTab(_ id: BrowserTabsModel.TabID) {
        guard let index = position(of: id) else { return }
        if let runtime = tabs[index].runtime {
            router.unregister(runtime.targetId)
            runtime.close()
        }
        tabs.remove(at: index)
        usage.removeAll { $0 == id }
        if activeTab == id { activeTab = usage.last ?? tabs.last?.id }
        router.update(tabCount: tabs.count)
        if tabs.isEmpty, !keepsLeaseWithoutTabs { releaseLease() }
        emitState()
    }

    /// `releasing` false (browser_close): a private session keeps its
    /// context — its cookies and storage, as the answer says, and as the
    /// WebKit engine's in-memory store does — until the session ends.
    private func closeAll(releasing: Bool = true) {
        for tab in tabs {
            guard let runtime = tab.runtime else { continue }
            router.unregister(runtime.targetId)
            runtime.close()
        }
        tabs.removeAll()
        usage.removeAll()
        activeTab = nil
        router.update(tabCount: 0)
        if releasing || !keepsLeaseWithoutTabs { releaseLease() }
        emitState()
    }

    /// A private session's browser context is its whole profile: letting the
    /// lease go would dispose of it, signing the agent out mid-session.
    private var keepsLeaseWithoutTabs: Bool {
        if case .private = profile { return true }
        return false
    }

    private func markSuspect() {
        guard let id = activeTab, let index = position(of: id) else { return }
        tabs[index].suspectStuck = true
    }

    /// Another tab waiting on a JavaScript dialog. A dialog holds its
    /// page's script thread, and with it every page of the same process:
    /// those linked to `id` by window.open, either way (`relatedOnly`), and
    /// possibly others.
    private func dialogElsewhere(than id: BrowserTabsModel.TabID, relatedOnly: Bool) -> Int? {
        var linked: Set<BrowserTabsModel.TabID> = [id]
        var grew = relatedOnly
        while grew {
            grew = false
            for tab in tabs where !linked.contains(tab.id) {
                let opened = tab.opener.map { linked.contains($0) } ?? false
                let opener = tabs.contains { linked.contains($0.id) && $0.opener == tab.id }
                if opened || opener {
                    linked.insert(tab.id)
                    grew = true
                }
            }
        }
        return tabs.indices.first { index in
            tabs[index].id != id && tabs[index].runtime?.blocksPage == true
                && (!relatedOnly || linked.contains(tabs[index].id))
        }
    }

    private func dialogHolds(at index: Int) -> AgentError {
        let kind = tabs[index].runtime?.dialog?.kind.rawValue ?? "dialog"
        return AgentError.conflict("tab \(index) has a JavaScript \(kind) open; pages sharing its process are held until "
                                   + "it is answered: browser_tabs select \(index), then browser_handle_dialog")
    }

    // MARK: - The lease

    /// The profile's Chromium, launched if need be (shared by the commands
    /// and the panel that want it at once).
    private func ensureLease() async throws -> ChromiumLease {
        for _ in 0..<3 {
            let mode = Self.networkMode(control.networkAccess)
            if let lease {
                if !lease.browser.isClosed, leaseMode == mode { return lease }
                // Stopped — or launched under another network setting: Chromium
                // takes its network at launch, and the old process lives on
                // while it shuts down. No command may run there meanwhile
                // (local sites only would fail open).
                let reason = lease.browser.isClosed
                    ? (lease.browser.closeReason ?? "Chromium stopped")
                    : "the network setting changed"
                browserGone(ObjectIdentifier(lease.browser), reason: reason)
            }
            if tornDown { throw AgentError.unavailable("the browser was closed") }
            let epoch = leaseEpoch
            let task: Task<ChromiumLease, Error>
            if let acquiring, acquiringMode == mode {
                task = acquiring
            } else {
                let pool = self.pool
                let key = self.key
                task = Task {
                    // The pool on the setting in force first: the app's own
                    // change may still be on its way to it.
                    await pool.setNetworkMode(mode)
                    return try await pool.acquire(key)
                }
                acquiring = task
                acquiringMode = mode
                launching = true
                launchFailure = nil
                emitState()
            }
            let acquired: ChromiumLease
            do {
                acquired = try await task.value
            } catch {
                if acquiring == task {
                    acquiring = nil
                    acquiringMode = nil
                    launching = false
                }
                let message = Self.message(of: error)
                launchFailure = message
                emitState()
                throw AgentError.unavailable(message)
            }
            if acquiring == task {
                acquiring = nil
                acquiringMode = nil
                launching = false
            }
            if let current = lease {
                if current !== acquired { Self.release(acquired, to: pool) }
                if leaseMode == mode, !current.browser.isClosed { return current }
                continue
            }
            if tornDown {
                Self.release(acquired, to: pool)
                throw AgentError.unavailable("the browser was closed")
            }
            if leaseEpoch != epoch {
                // The session ended (or let its pages go) meanwhile: no hold on
                // Chromium outlives it.
                Self.release(acquired, to: pool)
                emitState()
                throw CancellationError()
            }
            if Self.networkMode(control.networkAccess) != mode {
                // The setting changed again during the launch.
                Self.release(acquired, to: pool)
                continue
            }
            lease = acquired
            leaseMode = mode
            launchFailure = nil
            router.attach(browser: acquired.browser, userAgent: Self.userAgent(for: acquired.browser))
            acquired.browser.addOwner(router)
            emitState()
            return acquired
        }
        throw AgentError.unavailable("the agent's browser could not start: the network setting kept changing")
    }

    private func releaseLease() {
        leaseEpoch += 1
        guard let lease else { return }
        self.lease = nil
        leaseMode = nil
        lease.browser.removeOwner(router)
        router.detachBrowser()
        Self.release(lease, to: pool)
    }

    private static func release(_ lease: ChromiumLease, to pool: ChromiumPool) {
        Task { await pool.release(lease) }
    }

    /// Chromium stopped (a crash, the network setting, Clear data): every
    /// page went with it. The tabs stay, each comes back at its address.
    private func browserGone(_ browserID: ObjectIdentifier, reason: String) {
        guard let lease, ObjectIdentifier(lease.browser) == browserID else { return }
        // Still running (a network setting change): its pages are closed, not
        // merely forgotten.
        let running = !lease.browser.isClosed
        for index in tabs.indices {
            guard let runtime = tabs[index].runtime else { continue }
            remember(index)
            tabs[index].notes.append(contentsOf: runtime.takeEvents())
            if running {
                router.unregister(runtime.targetId)
                runtime.close()
            } else {
                runtime.forget()
            }
            tabs[index].runtime = nil
            tabs[index].notes.append("The agent's browser stopped (\(reason)): the page loads again at the next command.")
        }
        self.lease = nil
        leaseMode = nil
        lease.browser.removeOwner(router)
        router.detachBrowser()
        Self.release(lease, to: pool)
        emitState()
    }

    // MARK: - The router's news

    /// Popups adopted, closed tabs removed, notes placed, a stopped browser
    /// taken into account — then the panel's copy.
    func refresh() {
        drainRouter()
        emitState()
    }

    private func drainRouter() {
        for event in router.drain() {
            switch event {
            case .popup(let runtime, let opener):
                adoptPopup(runtime, opener: opener)
            case .removed(let targetId, let opener, let note):
                removeTab(targetId: targetId)
                if let note { place(note, on: opener) }
            case .note(let targetId, let text):
                place(text, on: targetId)
            case .browserClosed(let browserID, let reason):
                browserGone(browserID, reason: reason)
            }
        }
        for index in tabs.indices { remember(index) }
    }

    /// The page opened a tab: listed, in the background — as Playwright MCP
    /// keeps the current tab — with a note on both. A popup still on
    /// about:blank (a page writing into it, a refused address) never takes
    /// the agent's next command away from the page it works on.
    private func adoptPopup(_ runtime: ChromiumTabRuntime, opener: String?) {
        guard !tornDown, lease != nil, tabs.count < Self.maxTabs else {
            router.unregister(runtime.targetId)
            runtime.close()
            place("Blocked a popup: the agent's browser keeps at most \(Self.maxTabs) tabs.", on: opener)
            return
        }
        let address = runtime.url.isEmpty ? "about:blank" : runtime.url
        let id = BrowserTabsModel.TabID(rawValue: UUID())
        tabs.append(Tab(id: id, url: address, title: runtime.title, runtime: runtime))
        let index = tabs.count - 1
        if activeTab == nil { activeTab = id }
        touch(id)
        var kept: Set<BrowserTabsModel.TabID> = [id]
        if let opener, let source = tabs.firstIndex(where: { $0.runtime?.targetId == opener }) {
            tabs[index].opener = tabs[source].id
            runtime.note("Opened by tab \(source) (\(address)).")
            tabs[source].runtime?.note("The page opened a new tab, tab \(index): \(address) — "
                                       + "browser_tabs select \(index) to use it.")
            kept.insert(tabs[source].id)
        } else {
            runtime.note("Opened by a page of the agent's browser (\(address)).")
        }
        enforceLiveLimit(keeping: kept)
        router.update(tabCount: tabs.count)
    }

    private func removeTab(targetId: String) {
        guard let index = tabs.firstIndex(where: { $0.runtime?.targetId == targetId }) else { return }
        let id = tabs[index].id
        tabs.remove(at: index)
        usage.removeAll { $0 == id }
        if activeTab == id { activeTab = usage.last ?? tabs.last?.id }
        router.update(tabCount: tabs.count)
    }

    /// A note for the tab of `targetId`'s next answer, else the active tab's.
    private func place(_ note: String, on targetId: String?) {
        if let targetId, let runtime = tabs.first(where: { $0.runtime?.targetId == targetId })?.runtime {
            runtime.note(note)
            return
        }
        guard let id = activeTab, let index = position(of: id) else { return }
        if let runtime = tabs[index].runtime {
            runtime.note(note)
        } else {
            tabs[index].notes.append(note)
        }
    }

    // MARK: - The panel

    /// The person's operation, between the agent's commands — none while the
    /// agent holds the browser (its :hover and focus are the page's state).
    func perform(_ operation: ChromiumUserOperation) async {
        guard !tornDown else { return }
        if control.isBusy, operation != .materialize {
            flash("claude is using the browser: try again once it is done.")
            return
        }
        await enqueue(.user(operation))
    }

    /// The panel's page area (points) and whether it is on screen: Fit's
    /// size, and a set width's height. Applied between commands.
    func panelChanged(pageArea: CGSize, onScreen: Bool) async {
        guard onScreen, pageArea.width >= 1, pageArea.height >= 1 else { return }
        let changed = panelSize.map { abs($0.width - pageArea.width) >= 1 || abs($0.height - pageArea.height) >= 1 } ?? true
        panelSize = pageArea
        guard changed else { return }
        router.update(viewport: currentViewport())
        emitState()
        await scheduleViewport()
    }

    /// The panel's width menu: every live page, between commands.
    func setViewportWidth(_ width: ViewportWidth) async {
        viewportWidth = width
        router.update(viewport: currentViewport())
        emitState()
        await scheduleViewport()
    }

    /// The banner's answer: the dialog it shows, or the file chooser cancelled.
    func answerDialogFromPanel(accept: Bool, text: String?, shown: ChromiumShownDialog?) async {
        drainRouter()
        guard let id = activeTab, let index = position(of: id), let runtime = tabs[index].runtime,
              let modal = runtime.modal else { return }
        switch modal {
        case .dialog(let dialog, _):
            // Only the one the banner showed: the agent may have answered it,
            // or switched tabs, while the person read it.
            guard let shown, shown.tab == id else {
                emitState()
                return
            }
            _ = runtime.answerDialog(accept: accept, promptText: text, dialogId: shown.dialog)
        case .fileChooser:
            await runtime.cancelFileChooser(deadline: ContinuousClock.now + .seconds(5))
        }
        emitState()
    }

    // MARK: - The panel's input (panel design §2–§3)
    //
    // Added for the interactive panel, and only this: the panel script's
    // queries, and the line the agent reads when the person used the page.
    // The person's Input.* go from the page view's pump straight to the
    // tab's session — never through this queue.

    /// What the agent's next answer on a tab says when the person clicked or
    /// typed in its page from the panel.
    static let userInputNote = "The user used this page in the panel (clicks or typing) — take a snapshot "
        + "before relying on earlier refs."

    /// One op of the panel script (AgentPanelScript) on the active tab — the
    /// one the pump believes current — run beside the command queue, never
    /// in it. nil when refused: an agent command runs or waits, a dialog
    /// blocks the page, the tab is another or has no live page; or when no
    /// answer came within `timeout`.
    func panelQuery(_ op: String, _ arg: PanelJSON, tab: BrowserTabsModel.TabID,
                    timeout: Duration) async -> PanelJSON? {
        guard !tornDown, !control.isBusy, activeTab == tab, let index = position(of: tab),
              let runtime = tabs[index].runtime, !runtime.isDetached, !runtime.isCrashed,
              !runtime.blocksPage else { return nil }
        return await runtime.panelCall(op, arg, timeout: timeout)
    }

    /// The person clicked or typed in the tab's page: ONE line in its next
    /// answer's `### Events`, however much they did before that answer.
    func noteUserInput(tab: BrowserTabsModel.TabID) {
        guard !tornDown, let index = position(of: tab) else { return }
        if let runtime = tabs[index].runtime, !runtime.isDetached {
            runtime.noteOnce(Self.userInputNote)
        } else if !tabs[index].notes.contains(Self.userInputNote) {
            tabs[index].notes.append(Self.userInputNote)
        }
    }

    /// A message the panel shows for 4 s.
    func flash(_ text: String) {
        transientToken += 1
        let token = transientToken
        transient = (text, token)
        emitState()
        Task {
            try? await Task.sleep(for: .seconds(4))
            await self.clearFlash(token)
        }
    }

    private func clearFlash(_ token: Int) {
        guard transient?.token == token else { return }
        transient = nil
        emitState()
    }

    private func scheduleViewport() async {
        guard !viewportQueued else { return }
        viewportQueued = true
        await enqueue(.applyViewport)
    }

    /// Internal work, in the commands' queue: never between a command's
    /// `prepare` and its click.
    private func enqueue(_ work: Work) async {
        let previous = queueTail
        let job = Task<Void, Never> {
            _ = await previous?.value
            await self.perform(work: work)
        }
        queueTail = Task { await job.value }
        await job.value
    }

    private func perform(work: Work) async {
        switch work {
        case .applyViewport:
            viewportQueued = false
            await applyViewport()
        case .user(let operation):
            guard !tornDown else { return }
            currentOptions = AgentCommandOptions(snapshot: .none)
            defer { currentOptions = AgentCommandOptions() }
            await runUser(operation)
        }
    }

    private func runUser(_ operation: ChromiumUserOperation) async {
        let deadline = ContinuousClock.now + .seconds(30)
        do {
            switch operation {
            case .navigate(let url):
                _ = try await openPage(url, deadline: deadline)
            case .goBack:
                let (_, runtime) = try await currentTab(deadline: deadline)
                try Self.refuseWhileDialog(runtime)
                _ = try await goBack(runtime, deadline: deadline)
            case .goForward:
                try await goForward(deadline: deadline)
            case .reload:
                let (_, runtime) = try await currentTab(deadline: deadline)
                runtime.setAutoAcceptBeforeUnload(true)
                defer { runtime.setAutoAcceptBeforeUnload(false) }
                let mark = runtime.mark()
                try await runtime.reload(deadline: deadline - .seconds(1))
                _ = try await settleAction(runtime, mark: mark, deadline: ContinuousClock.now + .seconds(6))
            case .stopLoading:
                let (_, runtime) = try await currentTab(deadline: deadline)
                _ = try? await runtime.call("Page.stopLoading", deadline: deadline)
            case .select(let id):
                activate(id)
                _ = try await currentTab(deadline: deadline)
            case .close(let id):
                closeTab(id)
            case .newTab:
                _ = try await newTab(url: nil, deadline: deadline)
            case .materialize:
                if activeTab != nil { _ = try await currentTab(deadline: deadline) }
            }
        } catch {
            if !(error is CancellationError) { flash(Self.message(of: error)) }
        }
        drainRouter()
        emitState()
    }

    private func goForward(deadline: ContinuousClock.Instant) async throws {
        let (_, runtime) = try await currentTab(deadline: deadline)
        try Self.refuseWhileDialog(runtime)
        let history = try await runtime.call("Page.getNavigationHistory", deadline: deadline,
                                             interruptible: [.crashed, .detached])
        guard let index = history.int("currentIndex"), let entries = history.objects("entries"),
              index + 1 < entries.count, let entryId = entries[index + 1].int("id"),
              ChromiumBrowser.isOpenable(entries[index + 1].string("url") ?? "") else { return }
        runtime.setAutoAcceptBeforeUnload(true)
        defer { runtime.setAutoAcceptBeforeUnload(false) }
        let mark = runtime.mark()
        _ = try await runtime.call("Page.navigateToHistoryEntry", ["entryId": entryId], deadline: deadline,
                                   interruptible: [.dialogOpened, .crashed, .detached])
        _ = try await settleAction(runtime, mark: mark, deadline: ContinuousClock.now + .seconds(6))
    }

    // MARK: - Viewport

    /// Every live page at the size in force; popups to come too.
    private func applyViewport() async {
        let size = currentViewport()
        router.update(viewport: size)
        for tab in tabs {
            guard let runtime = tab.runtime, !runtime.isDetached, !runtime.isCrashed, runtime.viewport != size else {
                continue
            }
            try? await runtime.setViewport(cssSize: size, deadline: ContinuousClock.now + .seconds(2))
        }
        emitState()
    }

    private func currentViewport() -> CGSize {
        Self.cssViewport(width: viewportWidth, panel: panelSize, initial: environment.initialViewport)
    }

    // MARK: - Lifecycle

    /// The session ended: the pages and the lease go, the tabs stay to look at.
    func suspend() {
        suspended = true
        for index in tabs.indices { discardRuntime(at: index) }
        // browser_run_code's offline runner goes with the browser it lives in.
        ChromiumRunner.dispose(for: control)
        releaseLease()
        emitState()
    }

    /// The panel left the screen. A session that ended keeps no page: what
    /// the panel brought back to show goes again, and the hold on Chromium
    /// with it (the pool's idle grace starts).
    func panelLeft() {
        guard suspended, !tornDown else { return }
        suspend()
    }

    /// The session is gone for good.
    func tearDown() {
        guard !tornDown else { return }
        ChromiumRunner.dispose(for: control)
        closeAll()
        tornDown = true
        activity = activity.map { AgentActivity(summary: $0.summary, isRunning: false, at: $0.at) }
        emitState()
        updates.finish()
    }

    /// Signs out of everything (Settings): a project's process stops and its
    /// profile is emptied — its tabs load again, signed out, at the next
    /// command; a private session's context goes with its lease.
    func clearData() async {
        ChromiumRunner.dispose(for: control)
        switch profile {
        case .project(let identifier):
            try? await pool.clearProfile(identifier)
        case .private:
            for index in tabs.indices { discardRuntime(at: index) }
            releaseLease()
        }
        drainRouter()
        emitState()
    }

    // MARK: - The panel's copy

    private func emitState() {
        var list: [BrowserTabsModel.Tab] = []
        var sources: [BrowserTabsModel.TabID: ChromiumScreencastSource] = [:]
        for tab in tabs {
            list.append(BrowserTabsModel.Tab(id: tab.id, url: URL(string: displayURL(tab)) ?? Self.blank,
                                             title: displayTitle(tab)))
            if let runtime = tab.runtime, !runtime.isDetached, !runtime.isCrashed {
                sources[tab.id] = ChromiumScreencastSource(connection: runtime.connection, session: runtime.session)
            }
        }
        let active = activeTab.flatMap { id in tabs.first { $0.id == id } }
        let runtime = active?.runtime
        var loading = false
        if let runtime, !runtime.isCrashed, !runtime.isDetached {
            let state = runtime.signals.state
            loading = state.loaderId != nil && !state.reached.contains("load")
        }
        var status: String?
        if launching {
            status = "Starting Chromium…"
        } else if let launchFailure, lease == nil {
            status = launchFailure
        } else if let runtime, runtime.isCrashed {
            status = "This page crashed."
        } else if active != nil, runtime == nil {
            status = "This tab is unloaded: it loads again when claude or this panel uses it."
        }
        if let transient { status = transient.text }
        var state = ChromiumBrowserState(activity: activity, activeDialog: runtime?.modalState,
                                         viewportWidth: viewportWidth, viewport: currentViewport(), tabs: list,
                                         activeTab: activeTab, sources: sources, isLoading: loading,
                                         statusMessage: status)
        if let active = activeTab, let dialog = runtime?.dialog {
            state.shownDialog = ChromiumShownDialog(tab: active, dialog: dialog.id)
        }
        updates.yield(state)
    }

    private func displayURL(_ tab: Tab) -> String {
        if let address = tab.runtime?.url, !address.isEmpty, !address.lowercased().hasPrefix("chrome-error:") {
            return address
        }
        return tab.url
    }

    private func displayTitle(_ tab: Tab) -> String {
        if let title = tab.runtime?.title, !title.isEmpty { return title }
        if !tab.title.isEmpty { return tab.title }
        let address = displayURL(tab)
        return URL(string: address)?.host() ?? address
    }

    // MARK: - Policies

    private var isLocalOnly: Bool {
        control.networkAccess != .open
    }

    /// Before Chromium is asked anything for `url`: refused outright when
    /// the mode forbids it (the fence would only drop the connection).
    private func refuseOutsideNetworkAccess(_ url: URL) throws {
        if AgentNetworkRules.refuses(url, under: control.networkAccess) {
            throw AgentError.invalid("\(url.host() ?? url.absoluteString) is outside local sites only "
                                     + "(Loom's Settings ▸ Agents lists the hosts it lets through)")
        }
    }

    /// Chromium itself would commit file:, data: and chrome://, and RUN a
    /// javascript: address in the current page (step-0 probe): http(s) and
    /// about:blank only, before any Page.navigate or target.
    static func refuseScheme(_ url: URL) throws {
        guard AgentNavigationPolicy.decide(url: url, isMainFrame: true) == .allow,
              ChromiumBrowser.isOpenable(url.absoluteString) else {
            throw AgentError.invalid("the agent's browser opens http(s) addresses only, not \(url.scheme ?? "this"):")
        }
    }

    static func refuseWhileDialog(_ runtime: ChromiumTabRuntime) throws {
        guard let modal = runtime.modal else { return }
        switch modal {
        case .fileChooser:
            throw AgentError.conflict("a file chooser is open: answer it with browser_file_upload (no paths cancels it)")
        case .dialog:
            throw AgentError.conflict("a dialog is open: answer it with browser_handle_dialog first")
        }
    }

    static let tooManyTabs = AgentError.invalid(
        "the agent's browser keeps at most \(maxTabs) tabs: close one with browser_tabs close")

    // MARK: - Pure parts

    static let blank = URL(string: "about:blank")!

    /// The flags' network for an access setting, as the app's pool takes it
    /// (AgentChromiumBinary.networkMode).
    static func networkMode(_ access: AgentNetworkAccess) -> ChromiumNetworkMode {
        switch access {
        case .open: return .open
        case .localOnly(let hosts): return .localOnly(allowedHosts: hosts.map { $0.description })
        }
    }

    /// The CSS size pages lay out at: Fit is the panel's page area (or the
    /// size a never-shown panel will most likely have); a set width keeps the
    /// panel's aspect, so the scaled picture fills its width.
    static func cssViewport(width: ViewportWidth, panel: CGSize?, initial: CGSize) -> CGSize {
        var area = initial
        if let panel, panel.width >= 1, panel.height >= 1 { area = panel }
        var cssWidth: Int?
        if case .css(let pixels) = width { cssWidth = pixels }
        let size = ScreencastGeometry.emulatedViewport(cssWidth: cssWidth, pageArea: area)
        return CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    /// The live tabs to release so at most `limit` stay, least recently used
    /// first, never one of `keeping`.
    static func releaseCandidates(usage: [BrowserTabsModel.TabID], live: Set<BrowserTabsModel.TabID>,
                                  keeping: Set<BrowserTabsModel.TabID>, limit: Int) -> [BrowserTabsModel.TabID] {
        let ordered = usage.filter { live.contains($0) } + Array(live.subtracting(usage))
        var count = ordered.count
        var victims: [BrowserTabsModel.TabID] = []
        for id in ordered where count > limit && !keeping.contains(id) {
            victims.append(id)
            count -= 1
        }
        return victims
    }

    /// A failed load in the agent's words (ChromiumNetError, the WebKit
    /// engine's wording); nil for a load cancelled or superseded (a 204).
    static func loadFailure(errorText: String, url: URL?, localOnly: Bool) -> String? {
        if errorText.hasSuffix("ERR_INVALID_AUTH_CREDENTIALS") {
            let place = url?.host() ?? url?.absoluteString ?? "the page"
            return "\(place) asks for a sign-in (HTTP authentication), which the agent's browser does not answer"
        }
        return ChromiumNetError.message(errorText: errorText, url: url, localOnly: localOnly)
    }

    static func modifiers(_ names: [String]) -> CDPModifiers {
        var flags: CDPModifiers = []
        for name in names {
            switch name.lowercased() {
            case "alt": flags.insert(.alt)
            case "control": flags.insert(.control)
            // Playwright's portable spelling: ⌘ on macOS.
            case "meta", "controlormeta": flags.insert(.meta)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    static func button(_ button: MouseButton) -> CDPMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }

    /// Where `prepare` says to press, in the top viewport's CSS pixels.
    static func point(of answer: CDPObject, target: AgentTarget) throws -> (x: Double, y: Double) {
        guard let point = answer.object("point"), let x = point.double("x"), let y = point.double("y") else {
            throw AgentError.failed("the page did not say where \(described(target, answer.string("description"))) is")
        }
        return (x, y)
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

    /// What the panel's pill says the agent does (AgentBrowser's words).
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
        case .runCode: return "Running code"
        }
    }

    /// A tab's user agent: the browser's major, a Mac's Chrome, the system's languages.
    static func userAgent(for browser: ChromiumBrowser) -> ChromiumUserAgent {
        ChromiumUserAgent(version: browser.version, acceptLanguage: acceptLanguage(Locale.preferredLanguages))
    }

    /// "fr-FR,fr,en-US,en" from the system's preferred languages (three at most).
    static func acceptLanguage(_ preferred: [String]) -> String {
        var parts: [String] = []
        for language in preferred.prefix(3) {
            let tag = language.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            if !parts.contains(tag) { parts.append(tag) }
            if let base = tag.split(separator: "-").first.map(String.init), base != tag, !parts.contains(base) {
                parts.append(base)
            }
        }
        return parts.isEmpty ? "en-US,en" : parts.joined(separator: ",")
    }

    static func message(of error: Error) -> String {
        if let agent = error as? AgentError { return agent.message }
        if let described = error as? CustomStringConvertible, !(error is CDPError) { return described.description }
        if let agent = ChromiumTabRuntime.agentError(error) as? AgentError { return agent.message }
        return String(describing: error)
    }

    static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError { throw error }
        if let cdp = error as? CDPError, cdp == .cancelled { throw CancellationError() }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
