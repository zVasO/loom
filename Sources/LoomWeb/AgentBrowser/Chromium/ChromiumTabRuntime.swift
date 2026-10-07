import CoreGraphics
import Dispatch
import Foundation
import LoomChromium

// ChromiumTabRuntime — one live tab of the agent's Chromium: one page target,
// one flattened session (ADR-0016, design §3 and §6, step-0 probes).
//
// Lifecycle
//   init(browser:target:viewport:userAgent:)   nothing sent yet
//   start()           the session's sink, then the per-target init in ONE write
//                     (the panel script beside the helper), ending with
//                     Runtime.runIfWaitingForDebugger: the paused target runs.
//                     Never waits: a popup's attach calls it on the reader
//                     queue (the opener is blocked until it runs).
//   initialized()     the init's replies; a refusal is the tab's failure
//   close()           Target.closeTarget (no beforeunload), sinks off
//   forget()          sinks off, nothing sent (the browser is gone)
//
// Events (the reader queue, in wire order)
//   The session's sink does what PageSignals does not: at a main-frame commit
//   the helper's world is invalidated and asked for again; at every commit the
//   frame's world is made sure of before PageSignals adds the binding back;
//   the targets the page's own auto-attach pauses (out-of-process iframes,
//   workers) get their init or simply run. Then PageSignals: settle journal,
//   dialog ledger, binding flood cut, network filter. Its facts feed the logs,
//   the notes and `observer`.
//
// Commands (any task; never on the reader queue)
//   mark / settle             the event-driven settle (SettleMachine)
//   helper / barrier          the helper in the loom-agent world (ChromiumHelper)
//   panelCall                 the panel script there too (AgentPanelScript), for
//                             the person's input; beside the agent's queue
//   dispatch                  Input.* in one write, raced against dialogs
//   evaluate                  the agent's function in the page's world
//   capture                   Page.captureScreenshot, CSS size, capped
//   navigate / reload / goBack  http(s) and about:blank only
//   setViewport, setFiles, cancelFileChooser, isStuck, terminateExecution

/// What a tab announces itself as: a Mac's Chrome of the running major
/// version with its client hints — never "Headless" (step-0 probe: without
/// the metadata, `navigator.userAgentData.brands` is empty).
public struct ChromiumUserAgent: Sendable, Equatable {
    /// "141"; kept as text so the fixture's placeholders fit.
    public var major: String
    /// "141.0.7390.37".
    public var fullVersion: String
    public var acceptLanguage: String
    /// The client hint's `platformVersion` ("15.0.0").
    public var platformVersion: String
    /// "arm" or "x86".
    public var architecture: String

    public init(major: String, fullVersion: String, acceptLanguage: String = "en-US,en",
                platformVersion: String = ChromiumUserAgent.macOSVersion,
                architecture: String = ChromiumUserAgent.machineArchitecture) {
        self.major = major
        self.fullVersion = fullVersion
        self.acceptLanguage = acceptLanguage
        self.platformVersion = platformVersion
        self.architecture = architecture
    }

    /// From `Browser.getVersion`: "HeadlessChrome/141.0.7390.37" gives 141
    /// and its full version; a product without one gives "141.0.0.0".
    public init(version: ChromiumVersion, acceptLanguage: String = "en-US,en",
                platformVersion: String = ChromiumUserAgent.macOSVersion,
                architecture: String = ChromiumUserAgent.machineArchitecture) {
        var full = "\(version.major).0.0.0"
        if let slash = version.product.lastIndex(of: "/") {
            let tail = String(version.product[version.product.index(after: slash)...])
            let parts = tail.split(separator: ".", omittingEmptySubsequences: false)
            let numeric = parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { character in character.isASCII && character.isNumber }
            }
            if parts.count == 4 && numeric {
                full = tail
            }
        }
        self.init(major: String(version.major), fullVersion: full, acceptLanguage: acceptLanguage,
                  platformVersion: platformVersion, architecture: architecture)
    }

    /// Chrome's frozen Mac user agent: the OS part never changes, only the major.
    public var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/"
            + major + ".0.0.0 Safari/537.36"
    }

    /// `Emulation.setUserAgentOverride`'s parameters, as fixtures/init.json has them.
    public var overrideParams: [String: Any] {
        let brands: [[String: Any]] = [
            ["brand": "Chromium", "version": major],
            ["brand": "Not?A_Brand", "version": "24"],
        ]
        let fullVersionList: [[String: Any]] = [
            ["brand": "Chromium", "version": fullVersion],
            ["brand": "Not?A_Brand", "version": "24.0.0.0"],
        ]
        let metadata: [String: Any] = [
            "brands": brands,
            "fullVersionList": fullVersionList,
            "platform": "macOS",
            "platformVersion": platformVersion,
            "architecture": architecture,
            "model": "",
            "mobile": false,
            "bitness": "64",
            "wow64": false,
        ]
        let params: [String: Any] = [
            "userAgent": userAgent,
            "acceptLanguage": acceptLanguage,
            "platform": "MacIntel",
            "userAgentMetadata": metadata,
        ]
        return params
    }

    public static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static var machineArchitecture: String {
        #if arch(arm64)
        return "arm"
        #else
        return "x86"
        #endif
    }
}

/// How an input write ended.
public enum ChromiumInputOutcome: Sendable, Equatable {
    /// Chromium acked every event.
    case acked
    /// A dialog opened, or the page navigated, before every ack came: the
    /// input caused it; the settle follows it (its late acks are dropped).
    case interrupted(CDPInterruption)
}

/// `Page.navigate`'s answer.
public struct ChromiumNavigation: Sendable, Equatable {
    /// The new document's loader; nil for a same-document navigation (a
    /// hash) or a failure.
    public var loaderId: String?
    /// `net::ERR_*` when the load failed at once (ChromiumNetError words it).
    public var errorText: String?
    /// The address is a download (refused at the browser level): Chromium
    /// answers `isDownload` with `ERR_ABORTED`.
    public var isDownload: Bool

    public init(loaderId: String?, errorText: String?, isDownload: Bool) {
        self.loaderId = loaderId
        self.errorText = errorText
        self.isDownload = isDownload
    }
}

/// A screenshot as Chromium encoded it: never decoded nor re-encoded here.
public struct ChromiumScreenshot: Sendable, Equatable {
    public var data: Data
    /// The image's own size (its header), in pixels.
    public var width: Int
    public var height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// What a tab waits on from the agent or the person.
public enum ChromiumTabModal: Sendable, Equatable {
    /// A JavaScript dialog: the page's script is blocked on it.
    case dialog(PageDialog, host: String)
    /// A file chooser, intercepted: the page runs on.
    case fileChooser(PageFileChooser, host: String)
}

public final class ChromiumTabRuntime: @unchecked Sendable {

    /// A binding payload over this is dropped unparsed. The relay posts at
    /// most 4 096 UTF-16 units, the hook's text at most 2 000 plus a 300
    /// character location: a real one is well under 8 KB in UTF-8.
    public static let maxBindingPayloadBytes = 8 << 10
    /// Notes kept for the next answer (WebKit's TabRuntime keeps as many).
    public static let eventLimit = 50
    /// A full-page capture's height cap, in CSS px (WebKit's too).
    public static let fullPageMaxHeight: CGFloat = 8_000
    /// What ends an input write or an evaluation early.
    public static let inputInterruptions: Set<CDPInterruption> = [.dialogOpened, .navigated, .crashed, .detached]
    /// What ends a navigation's reply early: a beforeunload the page parks
    /// (the commit itself is what the navigation is for).
    static let leaving: Set<CDPInterruption> = [.dialogOpened, .crashed, .detached]
    /// Init commands a target may refuse and still be driven: focus and
    /// lifecycle emulation, child auto-attach, the resume of a target that
    /// already runs.
    static let optionalInitMethods: Set<String> = [
        "Emulation.setFocusEmulationEnabled", "Page.setWebLifecycleState", "Target.setAutoAttach",
        "Runtime.runIfWaitingForDebugger",
    ]
    /// The helper, top frame only (as the WebKit engine installs it): child
    /// frames' loom-agent worlds hold the relay alone.
    public static let helperTopFrame = "if (window === window.top) {\n" + AgentScripts.helper + "\n}"

    public let browser: ChromiumBrowser
    public let target: ChromiumTarget
    public let signals: PageSignals
    public let policy: SettlePolicy
    public let userAgent: ChromiumUserAgent

    public var connection: CDPConnection { browser.connection }
    public var session: CDPSessionID { target.sessionId }
    public var targetId: String { target.targetId }

    private let calls: ChromiumHelper
    private let sessionSink: TabSessionSink
    private let reloadsAfterCrash: Bool
    private let log: @Sendable (String) -> Void

    // Guarded by `lock`.
    private let lock = NSLock()
    private var console = ConsoleLog()
    private var network = NetworkLog()
    private var limiter = AgentRateLimiter()
    private var events: [String] = []
    private var documentStatus: Int?
    /// The main document's answer, kept until its commit (it comes before).
    private var pendingDocument: (url: String, status: Int)?
    private var viewportSize: CGSize
    private var channelCut = false
    private var fileChooser: (chooser: PageFileChooser, session: CDPSessionID, host: String)?
    /// A child session's `fileChooserOpened` being forwarded: its chooser
    /// lives in that session.
    private var chooserSession: CDPSessionID?
    private var crashTimes: [ContinuousClock.Instant] = []
    /// Crashed too often to be reloaded: it stays down until the agent navigates.
    private var reloadGivenUp = false
    /// The main frame's last Document request: a failed load's address.
    private var lastDocumentRequest: String?
    private var helperTitle: (generation: Int, title: String)?
    private var visibility: (generation: Int, state: String)?
    private var children: [CDPSessionID: ChildFrameSink] = [:]
    private var childFrames: Set<String> = []
    private var initReplies: [CDPReply] = []
    private var started = false
    private var closed = false
    private var observer: (@Sendable (PageFact) -> Void)?

    /// `viewport`: the CSS size the page lays out at (device scale 1).
    /// `reloadsAfterCrash`: a renderer that dies is reloaded at once, twice
    /// a minute at most (the WebKit engine's rule).
    public init(browser: ChromiumBrowser, target: ChromiumTarget, viewport: CGSize, userAgent: ChromiumUserAgent,
                policy: SettlePolicy = SettlePolicy(), reloadsAfterCrash: Bool = true,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.browser = browser
        self.target = target
        self.policy = policy
        self.userAgent = userAgent
        self.reloadsAfterCrash = reloadsAfterCrash
        self.log = log
        self.viewportSize = ChromiumTabRuntime.normalized(viewport)
        let pageSignals = PageSignals(session: target.sessionId, mainFrameId: target.targetId,
                                      link: PageSignalsLink.connection(browser.connection, session: target.sessionId),
                                      pollWindow: policy.pollWindow)
        self.signals = pageSignals
        self.calls = ChromiumHelper(connection: browser.connection, session: target.sessionId,
                                    mainFrameId: { pageSignals.state.mainFrameId },
                                    dialogOpen: { pageSignals.state.dialog != nil })
        self.sessionSink = TabSessionSink()
        sessionSink.runtime = self
    }

    // MARK: - Lifecycle

    /// The sink, then the init burst in one write; the target runs at its
    /// end. Never waits — callable on the reader queue (a popup's attach).
    /// A second call does nothing.
    public func start() {
        let first: Bool = lock.withLock {
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard first else { return }
        signals.setFactHandler { [weak self] fact in
            self?.apply(fact)
        }
        connection.setSink(sessionSink, for: session)
        let commands = Self.startCommands(viewport: viewport, userAgent: userAgent)
        let replies = connection.post(batch: commands, session: session,
                                      options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(10)))
        lock.withLock { initReplies = replies }
    }

    /// Returns once Chromium accepted the init (40 to 100 ms: the renderer
    /// starts meanwhile). Throws `AgentError.unavailable` naming the command
    /// it refused; the optional ones are only logged.
    public func initialized() async throws {
        let replies = lock.withLock { initReplies }
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch {
                if error is CancellationError { throw error }
                if let cdp = error as? CDPError, cdp == .cancelled { throw CancellationError() }
                let reason = Self.describe(error)
                if Self.optionalInitMethods.contains(reply.method) {
                    log("chromium: \(reply.method) was refused on \(targetId): \(reason)")
                    continue
                }
                throw AgentError.unavailable("the new tab could not be set up (\(reply.method): \(reason))")
            }
        }
    }

    /// Closes the target — `Target.closeTarget` runs no beforeunload — and
    /// lets go of its events.
    public func close() {
        let neverRan: Bool = lock.withLock { !started }
        forget()
        // Still paused (never started): it runs first — a popup closed while
        // paused would leave its opener's window.open blocked for good.
        if neverRan { browser.resume(target) }
        browser.closeTarget(targetId)
    }

    /// Lets go of the session's events and its children's, sends nothing:
    /// the target is gone, or the browser is.
    public func forget() {
        let sessions: [CDPSessionID] = lock.withLock {
            closed = true
            observer = nil
            let list = Array(children.keys)
            children.removeAll()
            return list
        }
        signals.setFactHandler(nil)
        connection.setSink(nil, for: session)
        for child in sessions {
            connection.setSink(nil, for: child)
        }
    }

    /// Every fact but the binding's and the network's, after the runtime
    /// applied it, on the thread it came on (mostly the reader queue): what
    /// the panel and the core follow — commits, titles, dialogs, choosers,
    /// downloads, crashes, the detach. It must not block nor wait.
    public func setObserver(_ handler: (@Sendable (PageFact) -> Void)?) {
        let replaced: (@Sendable (PageFact) -> Void)? = lock.withLock {
            let previous = observer
            observer = handler
            return previous
        }
        withExtendedLifetime(replaced) {}
    }

    // MARK: - State

    public var url: String { signals.state.url }

    /// The title Chromium reports (`targetInfoChanged`), else the one the
    /// helper last read in this document.
    public var title: String {
        let state = signals.state
        if !state.title.isEmpty { return state.title }
        let read: String = lock.withLock {
            guard let helperTitle, helperTitle.generation == state.generation else { return "" }
            return helperTitle.title
        }
        return read
    }

    /// The main document's HTTP status; nil for about:blank or a failure.
    public var httpStatus: Int? {
        lock.withLock { documentStatus }
    }

    /// The CSS size the page lays out at.
    public var viewport: CGSize {
        lock.withLock { viewportSize }
    }

    public var isCrashed: Bool { signals.state.crashed }
    public var isDetached: Bool { signals.state.detached }
    /// Crashed, and not reloaded (it kept crashing): only a navigation brings it back.
    public var staysCrashed: Bool {
        lock.withLock { reloadGivenUp } && signals.state.crashed
    }
    /// The address the main frame last asked for (its Document request): what
    /// a failed load names, the error page having replaced the address.
    public var lastRequestedAddress: String? {
        lock.withLock { lastDocumentRequest }
    }
    /// The dialog blocking the page, if any.
    public var dialog: PageDialog? { signals.state.dialog }
    /// A JavaScript dialog holds the page's script thread: no evaluation, no
    /// input, no capture answers until it is handled. A file chooser does not.
    public var blocksPage: Bool { signals.state.dialog != nil }
    /// Helper calls and evaluations pending in the page.
    public var callsInFlight: Int { calls.callsInFlight }

    /// The dialog or chooser the tab waits on.
    public var modal: ChromiumTabModal? {
        let state = signals.state
        if let dialog = state.dialog {
            return .dialog(dialog, host: Self.dialogHost(frameOrigin: dialog.frameOrigin,
                                                         isMainFrame: dialog.isMainFrame, topURL: state.url))
        }
        let chooser: ChromiumTabModal? = lock.withLock {
            guard let fileChooser else { return nil }
            return ChromiumTabModal.fileChooser(fileChooser.chooser, host: fileChooser.host)
        }
        return chooser
    }

    /// `### Modal state`, as the answer builder takes it.
    public var modalState: AgentModalState? {
        guard let modal else { return nil }
        switch modal {
        case .dialog(let dialog, let host):
            return Self.modalState(for: dialog, host: host)
        case .fileChooser(let chooser, let host):
            return AgentModalState(kind: .fileChooser(multiple: chooser.multiple), message: "", host: host)
        }
    }

    /// `### Page`. `hidden` only when the page itself said so: headless
    /// pages render whether the panel shows them or not.
    public func pageSummary(viewportScaled: Bool) -> AgentPageSummary {
        let page = signals.state
        let pageTitle = title
        let summary: AgentPageSummary = lock.withLock {
            let counts = console.counts
            var hidden = false
            if let visibility, visibility.generation == page.generation {
                hidden = visibility.state == "hidden"
            }
            return AgentPageSummary(url: page.url, title: pageTitle, httpStatus: documentStatus,
                                    consoleErrors: counts.errors, consoleWarnings: counts.warnings,
                                    viewport: viewportSize, viewportScaled: viewportScaled, hidden: hidden)
        }
        return summary
    }

    public func renderConsole(level: ConsoleLevel, all: Bool, limit: Int) -> String {
        lock.withLock { console.render(level: level, all: all, limit: limit) }
    }

    public func renderNetwork(filter: String?, limit: Int) -> String {
        lock.withLock { network.render(filter: filter, limit: limit) }
    }

    public var consoleCounts: (errors: Int, warnings: Int) {
        lock.withLock { console.counts }
    }

    /// For the next answer's `### Events`; the oldest go past `eventLimit`.
    public func note(_ event: String) {
        lock.withLock { appendNote(event) }
    }

    /// `note`, unless the very same line already waits for the next answer:
    /// once per gap between the answers that take them.
    func noteOnce(_ event: String) {
        lock.withLock {
            guard !events.contains(event) else { return }
            appendNote(event)
        }
    }

    /// The notes since the last answer, which no longer holds them.
    public func takeEvents() -> [String] {
        let taken: [String] = lock.withLock {
            let current = events
            events.removeAll()
            return current
        }
        return taken
    }

    /// A frame of this tab, its out-of-process iframes included: where the
    /// router sends a subframe's download.
    public func ownsFrame(_ frameId: String) -> Bool {
        if signals.ownsFrame(frameId) { return true }
        return lock.withLock { childFrames.contains(frameId) }
    }

    // MARK: - From the router (ChromiumTargetOwner, reader queue)

    public func noteTargetInfo(title: String, url: String) {
        signals.noteTargetInfo(title: title, url: url)
    }

    public func noteDownload(url: String) {
        signals.noteDownload(url: url)
    }

    public func noteCrashed() {
        signals.noteCrashed()
    }

    public func noteDetached(reason: String? = nil) {
        signals.noteDetached(reason: reason)
    }

    // MARK: - Settling

    /// Taken just before an action is sent.
    public func mark() -> PageMark {
        signals.mark()
    }

    /// The event-driven settle since `mark` (design §4, SettleMachine). An
    /// action with no navigation waits for its barrier's report: run
    /// `barrier` (or a helper call `asBarrier`) after the input's acks.
    public func settle(kind: SettleMachine.Kind, from mark: PageMark,
                       deadline: ContinuousClock.Instant) async -> SettleOutcome {
        await signals.wait(kind, from: mark, policy: policy, deadline: deadline)
    }

    /// On while the agent itself leaves the page (navigate, back, reload,
    /// close): the page's "leave site?" is accepted, with a note.
    public func setAutoAcceptBeforeUnload(_ on: Bool) {
        signals.setAutoAcceptBeforeUnload(on)
    }

    /// The agent's or the person's answer to the dialog; exactly one is sent.
    public func answerDialog(accept: Bool, promptText: String? = nil,
                             dialogId: Int? = nil) -> Result<PageDialog, DialogLedger.AnswerError> {
        signals.answerDialog(accept: accept, promptText: promptText, dialogId: dialogId)
    }

    /// The agent navigates away from a page blocked on a dialog: dismissed.
    @discardableResult
    public func dismissDialog() -> PageDialog? {
        signals.dismissDialog()
    }

    // MARK: - The helper

    /// The helper's answer to `op` (ChromiumHelper.call): its fields, or
    /// the errors it lists. `asBarrier`: the call stands for the settle's
    /// barrier (`barrier`, `snapshot{afterFrame}`) — its outcome is reported
    /// to the settle, and a stale world means its document is gone.
    public func helper(_ op: String, _ args: [String: Any] = [:], deadline: ContinuousClock.Instant,
                       asBarrier: Bool = false) async throws -> CDPObject {
        let argsJSON = ChromiumHelper.json(args)
        do {
            let answer = try await calls.call(op, argsJSON: argsJSON, deadline: deadline, asBarrier: asBarrier)
            if asBarrier { signals.noteBarrier(lost: false) }
            remember(answer)
            return answer
        } catch {
            if asBarrier { signals.noteBarrier(lost: Self.isDocumentLoss(error)) }
            throw error
        }
    }

    /// The settle's barrier: one `setTimeout(0)` task in the page, then its
    /// url, title, visibility, focus (and `checkedOf`'s state). Every event an
    /// action caused synchronously is applied before its answer. nil when it
    /// gave no answer — its document went away (reported as a navigation),
    /// a dialog opened, the page is stuck; the settle covers each. Throws
    /// only `CancellationError`.
    public func barrier(checkedOf: String? = nil, deadline: ContinuousClock.Instant) async throws -> CDPObject? {
        var args: [String: Any] = [:]
        if let checkedOf { args["checkedOf"] = checkedOf }
        do {
            return try await helper("barrier", args, deadline: deadline, asBarrier: true)
        } catch {
            if error is CancellationError { throw error }
            if let cdp = error as? CDPError, cdp == .cancelled { throw CancellationError() }
            return nil
        }
    }

    // MARK: - The panel script

    /// One op of the panel script (`AgentPanelScript.callFunction`) in the
    /// helper's world of the main frame, by value: its answer — JSON null
    /// included, `{error: {code, message}}` as the script gives it — or nil:
    /// a dialog blocks the page, the document went, the page crashed, or no
    /// answer came by `timeout`. Any thread; it never waits behind the
    /// agent's commands, and is not one of the helper calls a stuck check
    /// counts. A document the injected script missed gets it once, then the
    /// op again.
    func panelCall(_ op: String, _ arg: PanelJSON = .null, timeout: Duration) async -> PanelJSON? {
        let deadline = ContinuousClock.now + timeout
        let options = CDPCallOptions(deadline: deadline, interruptible: ChromiumHelper.interruptible)
        var injected = false
        while !blocksPage, !isDetached, !isCrashed {
            guard let world = try? await calls.contextId(deadline: deadline) else { return nil }
            let arguments: [[String: Any]] = [["value": op], ["value": arg.foundationValue]]
            let params: [String: Any] = [
                "functionDeclaration": AgentPanelScript.callFunction,
                "executionContextId": world.id,
                "arguments": arguments,
                "returnByValue": true,
                "silent": true,
            ]
            guard let result = try? await connection.call("Runtime.callFunctionOn", params, session: session,
                                                           options: options),
                  result.object("exceptionDetails") == nil else { return nil }
            let value = result.object("result")?.raw["value"].flatMap { PanelJSON(foundation: $0) } ?? .null
            guard !injected, value["error"]?["code"]?.stringValue == "panelMissing" else { return value }
            injected = true
            let inject: [String: Any] = [
                "functionDeclaration": Self.panelInjectFunction,
                "executionContextId": world.id,
                "returnByValue": true,
                "silent": true,
            ]
            guard (try? await connection.call("Runtime.callFunctionOn", inject, session: session,
                                              options: options)) != nil else { return nil }
        }
        return nil
    }

    // MARK: - Input

    /// `Input.*` commands in ONE write (a click's move, press and release),
    /// awaited together. A dialog the input opens, or a navigation it
    /// commits, ends the wait: `.interrupted`, the settle follows. Throws
    /// `CDPError` for a crash, a detach, the deadline or a refusal.
    public func dispatch(batch: [(String, [String: Any])],
                         deadline: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        guard !batch.isEmpty else { return .acked }
        if blocksPage { return .interrupted(.dialogOpened) }
        calls.beginCall()
        defer { calls.endCall() }
        let replies = connection.post(batch: batch, session: session,
                                      options: CDPCallOptions(deadline: deadline,
                                                              interruptible: Self.inputInterruptions))
        for reply in replies {
            do {
                _ = try await reply.value()
            } catch let error as CDPError {
                if case .interrupted(let reason) = error, reason == .dialogOpened || reason == .navigated {
                    return .interrupted(reason)
                }
                throw error
            }
        }
        return .acked
    }

    /// Successive writes (a double click's second press, `type slowly`'s
    /// windows of keys), each sent after the previous one's acks: a dialog
    /// the first opens never receives the rest.
    public func dispatch(writes: [[(String, [String: Any])]],
                         deadline: ContinuousClock.Instant) async throws -> ChromiumInputOutcome {
        for write in writes {
            let outcome = try await dispatch(batch: write, deadline: deadline)
            if outcome != .acked { return outcome }
        }
        return .acked
    }

    // MARK: - Evaluation

    /// The agent's function in the PAGE's world (`Runtime.evaluate`, no
    /// context: the main frame's own), with the element the helper stamped
    /// with `nonce`, if any — `AgentScripts.evaluateBody` in an async arrow.
    /// Answers the serializer's JSON text. At `deadline` the script is
    /// stopped (`Runtime.terminateExecution`): a loop never outlives its
    /// command. A dialog it opens ends the wait (`CDPError.interrupted`).
    public func evaluate(_ function: String, nonce: String = "",
                         deadline: ContinuousClock.Instant) async throws -> String {
        if blocksPage { throw CDPError.interrupted(.dialogOpened) }
        calls.beginCall()
        defer { calls.endCall() }
        let params: [String: Any] = [
            "expression": Self.evaluateExpression(function: function, nonce: nonce),
            "awaitPromise": true,
            "returnByValue": true,
            // As Playwright's evaluate: a popup or a fullscreen request in
            // the function is allowed, as from a click.
            "userGesture": true,
        ]
        let result: CDPObject
        do {
            result = try await connection.call("Runtime.evaluate", params, session: session,
                                               options: CDPCallOptions(deadline: deadline,
                                                                       interruptible: Self.inputInterruptions))
        } catch let error as CDPError {
            switch error {
            case .timeout:
                post("Runtime.terminateExecution")
                throw AgentError.timeout("the function did not finish in time; Loom stopped it")
            case .protocolError(_, _, let message):
                if message.contains("Execution was terminated") {
                    throw AgentError.failed("the function was stopped before it finished")
                }
                if ChromiumHelper.isDocumentGone(message) { throw CDPError.interrupted(.navigated) }
                throw error
            case .interrupted, .disconnected, .cancelled:
                throw error
            }
        }
        if let exception = result.object("exceptionDetails") {
            throw AgentError.invalid("JavaScript error: " + ChromiumHelper.describe(exception))
        }
        return result.object("result")?.string("value") ?? "undefined"
    }

    /// `(async () => { const nonce = "…"; <evaluateBody> })()`.
    public static func evaluateExpression(function: String, nonce: String) -> String {
        "(async () => {\nconst nonce = " + jsString(nonce) + ";\n" + AgentScripts.evaluateBody(function: function)
            + "\n})()"
    }

    // MARK: - Screenshots

    /// `Page.captureScreenshot` at CSS size, the longest edge at most
    /// `maxEdge` (`clip.scale`, device scale 1): Chromium encodes at the
    /// size asked, so nothing is decoded here.
    /// - `clip` nil, not `fullPage`: the viewport as it shows;
    /// - `clip`, not `fullPage`: that box, in DOCUMENT coordinates (a
    ///   top-viewport rect plus scrollX/scrollY — step-0 probe);
    /// - `fullPage`: `clip` is the page's box from its top, its height cut at
    ///   `fullPageMaxHeight`, captured past the viewport in one call. The
    ///   scroll position is kept; the page sees a resize event meanwhile.
    public func capture(clip: CGRect?, format: ImageFormat, fullPage: Bool, maxEdge: CGFloat,
                        deadline: ContinuousClock.Instant) async throws -> ChromiumScreenshot {
        if blocksPage { throw CDPError.interrupted(.dialogOpened) }
        var params: [String: Any] = ["format": format == .png ? "png" : "jpeg"]
        if format == .jpeg { params["quality"] = 80 }
        var region = clip
        if fullPage {
            guard let page = clip else { throw AgentError.invalid("a full-page capture needs the page's size") }
            region = CGRect(x: 0, y: 0, width: page.width, height: min(page.height, Self.fullPageMaxHeight))
            params["captureBeyondViewport"] = true
        } else if clip == nil {
            let size = viewport
            if max(size.width, size.height) > maxEdge {
                // Scaled down: the clip needs where the viewport is in the page.
                let metrics = try await call("Page.getLayoutMetrics", deadline: deadline,
                                             interruptible: [.dialogOpened, .crashed, .detached])
                let visual = metrics.object("cssVisualViewport")
                region = CGRect(x: visual?.double("pageX") ?? 0, y: visual?.double("pageY") ?? 0,
                                width: visual?.double("clientWidth") ?? Double(size.width),
                                height: visual?.double("clientHeight") ?? Double(size.height))
            }
            params["optimizeForSpeed"] = true
        }
        var expected = viewport
        if let region {
            guard region.width >= 1, region.height >= 1, region.width.isFinite, region.height.isFinite else {
                throw AgentError.invalid("nothing to capture: the area is empty")
            }
            let scale = min(1, Double(maxEdge) / Double(max(region.width, region.height)))
            let box: [String: Any] = [
                "x": Double(region.minX), "y": Double(region.minY),
                "width": Double(region.width), "height": Double(region.height), "scale": scale,
            ]
            params["clip"] = box
            expected = CGSize(width: region.width * CGFloat(scale), height: region.height * CGFloat(scale))
        }
        let result = try await call("Page.captureScreenshot", params, deadline: deadline,
                                    interruptible: [.dialogOpened, .crashed, .detached])
        guard let base64 = result.string("data"), let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw AgentError.failed("the screenshot failed: Chromium sent no image")
        }
        let size = ImageSize.of(data)
        return ChromiumScreenshot(data: data, width: size?.width ?? Self.side(expected.width),
                                  height: size?.height ?? Self.side(expected.height))
    }

    // MARK: - Viewport

    /// The CSS size the page lays out at (device scale 1, `browser_resize`,
    /// the panel's width). ResizeObserver and media queries follow at once.
    public func setViewport(cssSize: CGSize, deadline: ContinuousClock.Instant) async throws {
        let size = Self.normalized(cssSize)
        lock.withLock { viewportSize = size }
        _ = try await call("Emulation.setDeviceMetricsOverride", Self.deviceMetrics(size), deadline: deadline,
                           interruptible: [.crashed, .detached])
    }

    // MARK: - Navigation

    /// `Page.navigate`, for http(s) and about:blank only: Chromium itself
    /// would commit file:, data: and chrome:, and RUN a javascript: address
    /// in the current page (step-0 probe). Set `setAutoAcceptBeforeUnload`
    /// first when the agent is the one leaving; otherwise the page's "leave
    /// site?" parks and ends the wait (`CDPError.interrupted(.dialogOpened)`).
    public func navigate(to url: String, deadline: ContinuousClock.Instant) async throws -> ChromiumNavigation {
        try Self.refuseUnopenable(url)
        let params: [String: Any] = ["url": url, "transitionType": "typed"]
        let result = try await call("Page.navigate", params, deadline: deadline, interruptible: Self.leaving)
        return ChromiumNavigation(loaderId: result.string("loaderId"), errorText: result.string("errorText"),
                                  isDownload: result.bool("isDownload") ?? false)
    }

    /// The committed document again: an address the policy already let in.
    public func reload(deadline: ContinuousClock.Instant) async throws {
        _ = try await call("Page.reload", deadline: deadline, interruptible: Self.leaving)
    }

    /// The previous history entry. false: there is none. The entry must be
    /// an address the agent's browser opens (a blob: page is not).
    public func goBack(deadline: ContinuousClock.Instant) async throws -> Bool {
        let history = try await call("Page.getNavigationHistory", deadline: deadline,
                                     interruptible: [.crashed, .detached])
        guard let index = history.int("currentIndex"), let entries = history.objects("entries"),
              index > 0, index - 1 < entries.count else { return false }
        let entry = entries[index - 1]
        guard let entryId = entry.int("id") else { return false }
        // A tab's first entry is the about:blank its target was created on
        // (review probe: it stays in the history): no page to go back to, as
        // the WebKit engine says.
        if index == 1, (entry.string("url") ?? "").lowercased() == "about:blank" { return false }
        try Self.refuseUnopenable(entry.string("url") ?? "")
        _ = try await call("Page.navigateToHistoryEntry", ["entryId": entryId], deadline: deadline,
                           interruptible: Self.leaving)
        return true
    }

    // MARK: - File choosers

    /// The open chooser's input gets these files (`DOM.setFileInputFiles` on
    /// the session it opened in; `AgentUploadPolicy` is the caller's, before).
    public func setFiles(_ paths: [String], deadline: ContinuousClock.Instant) async throws {
        let open: (chooser: PageFileChooser, session: CDPSessionID, host: String)? = lock.withLock { fileChooser }
        guard let open else { throw AgentError.invalid("no file chooser is open") }
        guard let node = open.chooser.backendNodeId else {
            throw AgentError.failed("Chromium did not say which input opened the file chooser")
        }
        let params: [String: Any] = ["files": paths, "backendNodeId": node]
        _ = try await connection.call("DOM.setFileInputFiles", params, session: open.session,
                                      options: CDPCallOptions(deadline: deadline,
                                                              interruptible: [.dialogOpened, .crashed, .detached]))
        lock.withLock { fileChooser = nil }
    }

    /// No file: the input gets the `cancel` event a person's Cancel fires,
    /// as WebKit sends it. Best effort; the chooser is closed either way.
    @discardableResult
    public func cancelFileChooser(deadline: ContinuousClock.Instant) async -> Bool {
        let open: (chooser: PageFileChooser, session: CDPSessionID, host: String)? = lock.withLock {
            let current = fileChooser
            fileChooser = nil
            return current
        }
        guard let open, let node = open.chooser.backendNodeId else { return false }
        let options = CDPCallOptions(deadline: deadline, interruptible: [.dialogOpened, .crashed, .detached])
        do {
            let resolved = try await connection.call("DOM.resolveNode", ["backendNodeId": node],
                                                     session: open.session, options: options)
            guard let objectId = resolved.object("object")?.string("objectId") else { return false }
            let params: [String: Any] = [
                "objectId": objectId,
                "functionDeclaration": "function() { this.dispatchEvent(new Event(\"cancel\", { bubbles: true })); }",
                "silent": true,
            ]
            _ = try await connection.call("Runtime.callFunctionOn", params, session: open.session, options: options)
            connection.post("Runtime.releaseObject", ["objectId": objectId], session: open.session,
                            options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Stuck pages

    /// The page's main thread does not answer a trivial evaluation within
    /// `limit` (step-0 probe: always so when a script spins). A page blocked
    /// on a dialog is not stuck; with `requireCallInFlight`, nor is one with
    /// nothing of ours pending (an awaited promise yields).
    public func isStuck(limit: Duration = .milliseconds(500), requireCallInFlight: Bool = false) async -> Bool {
        if blocksPage { return false }
        if requireCallInFlight && callsInFlight == 0 { return false }
        let params: [String: Any] = ["expression": "1", "returnByValue": true]
        do {
            _ = try await connection.call("Runtime.evaluate", params, session: session,
                                          options: CDPCallOptions(deadline: ContinuousClock.now + limit,
                                                                  interruptible: [.dialogOpened]))
            return false
        } catch let error as CDPError {
            if case .timeout = error { return true }
            return false
        } catch {
            return false
        }
    }

    /// `Runtime.terminateExecution`: the spinning script stops (1.4 to 3.2 ms),
    /// the calls queued behind it answer; harmless on an idle page.
    public func terminateExecution(limit: Duration = .seconds(1)) async {
        _ = try? await connection.call("Runtime.terminateExecution", [:], session: session,
                                       options: CDPCallOptions(deadline: ContinuousClock.now + limit))
    }

    /// Stops a stuck script, then checks again: true when the page answers.
    public func unstick() async -> Bool {
        await terminateExecution()
        return !(await isStuck())
    }

    // MARK: - Any command

    /// Any command on the tab's session.
    public func call(_ method: String, _ params: [String: Any] = [:], deadline: ContinuousClock.Instant,
                     interruptible: Set<CDPInterruption> = []) async throws -> CDPObject {
        try await connection.call(method, params, session: session,
                                  options: CDPCallOptions(deadline: deadline, interruptible: interruptible))
    }

    /// Fire-and-forget on the tab's session (5 s before its reply is dropped).
    @discardableResult
    public func post(_ method: String, _ params: [String: Any] = [:]) -> CDPReply {
        connection.post(method, params, session: session,
                        options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(5)))
    }

    // MARK: - Events (reader queue)

    /// The session's events: the helper's world and the child targets here,
    /// the rest by PageSignals.
    fileprivate func sessionEvent(method: String, params: CDPObject, session eventSession: CDPSessionID?) {
        switch method {
        case "Page.frameNavigated":
            if let frame = params.object("frame"), let frameId = frame.string("id") {
                if frame.string("parentId") == nil {
                    calls.documentChanged(frameId: frameId)
                } else {
                    calls.subframeChanged(frameId: frameId)
                }
            }
        case "Target.attachedToTarget":
            childAttached(params)
            return
        case "Target.detachedFromTarget":
            childDetached(params)
            return
        case "Network.requestWillBeSent":
            if params.string("type") == "Document", let frameId = params.string("frameId"),
               frameId == signals.state.mainFrameId, let address = params.object("request")?.string("url") {
                lock.withLock { lastDocumentRequest = String(address.prefix(2_048)) }
            }
        default:
            break
        }
        signals.handle(method: method, params: params, session: eventSession)
    }

    /// A child target the page's own auto-attach paused. An out-of-process
    /// iframe gets the relay, the hook, the binding, the network and file
    /// choosers (its events reach PageSignals through its sink); anything
    /// else — a worker, a service worker — just runs: left paused, it never
    /// would (CDP harness, lib/init.mjs).
    fileprivate func childAttached(_ params: CDPObject) {
        guard let info = params.object("targetInfo"), let rawSession = params.string("sessionId") else { return }
        let child = CDPSessionID(rawSession)
        let options = CDPCallOptions(deadline: ContinuousClock.now + .seconds(10))
        guard info.string("type") == "iframe" else {
            connection.post("Runtime.runIfWaitingForDebugger", [:], session: child, options: options)
            return
        }
        let sink = ChildFrameSink(runtime: self, session: child)
        let accepted: Bool = lock.withLock {
            guard !closed else { return false }
            children[child] = sink
            if let childTarget = info.string("targetId"), childFrames.count < 1_000 {
                childFrames.insert(childTarget)
            }
            return true
        }
        if accepted {
            connection.setSink(sink, for: child)
            _ = connection.post(batch: Self.childFrameInitCommands(), session: child, options: options)
        } else {
            connection.post("Runtime.runIfWaitingForDebugger", [:], session: child, options: options)
        }
    }

    fileprivate func childDetached(_ params: CDPObject) {
        guard let rawSession = params.string("sessionId") else { return }
        let child = CDPSessionID(rawSession)
        let removed: ChildFrameSink? = lock.withLock { children.removeValue(forKey: child) }
        if removed != nil {
            connection.setSink(nil, for: child)
        }
    }

    /// An out-of-process iframe's events: its frames' worlds and bindings
    /// here; its binding calls, XHR/fetch and file chooser to PageSignals
    /// (a subframe's Document request is not a load of the page: ignored there).
    fileprivate func childEvent(method: String, params: CDPObject, session child: CDPSessionID) {
        switch method {
        case "Page.frameNavigated":
            guard let frameId = params.object("frame")?.string("id") else { return }
            let cut: Bool = lock.withLock {
                if childFrames.count < 1_000 {
                    childFrames.insert(frameId)
                }
                return channelCut
            }
            if !cut {
                _ = connection.post(batch: Self.frameNavigatedCommands(frameId: frameId), session: child,
                                    options: CDPCallOptions(deadline: ContinuousClock.now + .seconds(10)))
            }
        case "Page.frameAttached":
            guard let frameId = params.string("frameId") else { return }
            lock.withLock {
                guard childFrames.count < 1_000 else { return }
                childFrames.insert(frameId)
            }
        case "Target.attachedToTarget":
            childAttached(params)
        case "Target.detachedFromTarget":
            childDetached(params)
        case "Page.fileChooserOpened":
            lock.withLock { chooserSession = child }
            signals.handle(method: method, params: params, session: child)
            lock.withLock { chooserSession = nil }
        case "Runtime.bindingCalled", "Network.requestWillBeSent", "Network.responseReceived",
             "Network.loadingFinished", "Network.loadingFailed":
            signals.handle(method: method, params: params, session: child)
        default:
            break
        }
    }

    // MARK: - Facts (reader queue, or the caller's thread for note…)

    private func apply(_ fact: PageFact) {
        switch fact {
        case .binding(let payload, _):
            guard let message = Self.hookMessage(fromPayload: payload) else { return }
            let now = Self.uptime()
            lock.withLock {
                guard !closed, limiter.admit(at: now) else { return }
                if case .console(let level, let text, let location) = message {
                    console.append(level: level, text: text, location: location)
                }
                // Requests come from the Network domain; the relay sends none.
            }
            return
        case .network(let networkFact):
            lock.withLock { record(networkFact) }
            return
        default:
            break
        }

        // Read before the lock: PageSignals' own lock, never taken under ours.
        let state = signals.state
        var chooserOrigin: String?
        if case .fileChooser(let chooser) = fact, let frameId = chooser.frameId {
            chooserOrigin = signals.frameOrigin(frameId)
        }
        var reload = false
        lock.lock()
        switch fact {
        case .binding, .network:
            break
        case .bindingCut:
            channelCut = true
            appendNote("The page sent console and network messages faster than Loom reads them: they are no "
                       + "longer recorded until it navigates.")
        case .committed(let committedURL, _, _, _):
            console.navigationCommitted()
            network.navigationCommitted()
            documentStatus = nil
            if let document = pendingDocument, Self.sameAddress(document.url, committedURL) {
                documentStatus = document.status
                network.document(url: document.url, status: document.status)
            }
            pendingDocument = nil
            channelCut = false
            fileChooser = nil
            reloadGivenUp = false
        case .sameDocument, .lifecycle, .targetInfo, .dialogClosed:
            break
        case .dialogOpened(let dialog):
            let host = Self.dialogHost(frameOrigin: dialog.frameOrigin, isMainFrame: dialog.isMainFrame,
                                       topURL: state.url)
            appendNote("\(host) opened a dialog.")
        case .dialogAutoAnswered(_, _, let reason):
            if reason == .agentLeaving {
                appendNote("The page asked to confirm leaving; Loom left anyway.")
            }
        case .dialogDismissed(_, let reason):
            if reason == .documentChanged {
                appendNote("A dialog of the previous page was dismissed.")
            }
        case .fileChooser(let chooser):
            let isMain = chooser.frameId.map { $0 == state.mainFrameId }
            let host = Self.dialogHost(frameOrigin: chooserOrigin, isMainFrame: isMain, topURL: state.url)
            fileChooser = (chooser, chooserSession ?? session, host)
            appendNote("\(host) opened a dialog.")
        case .download(_, let downloadURL, _):
            appendNote("A download was ignored: \(downloadURL)")
        case .crashed:
            fileChooser = nil
            let now = ContinuousClock.now
            crashTimes.removeAll { $0.duration(to: now) > .seconds(60) }
            crashTimes.append(now)
            if !reloadsAfterCrash || closed {
                appendNote("The page's process stopped.")
            } else if crashTimes.count <= 2 {
                reload = true
                appendNote("The page's process stopped; it was reloaded.")
            } else {
                reloadGivenUp = true
                appendNote("The page's process keeps stopping; it was not reloaded — browser_navigate loads it again.")
            }
        case .detached:
            fileChooser = nil
        }
        let notify = closed ? nil : observer
        lock.unlock()
        if reload {
            post("Page.reload")
        }
        notify?(fact)
    }

    /// Under the lock.
    private func record(_ fact: PageNetworkFact) {
        switch fact {
        case .started(let requestId, let kind, let method, let requestURL):
            network.started(key: requestId, kind: NetworkLog.Kind(rawValue: kind.rawValue) ?? .fetch,
                            method: method, url: requestURL)
        case .ended(let requestId, let status, let errorText, let canceled, let durationMs):
            let error: String? = errorText.map { canceled ? "canceled" : $0 }
            network.finished(key: requestId, status: status, error: error, durationMs: durationMs)
        case .document(let documentURL, let status):
            // Its commit follows: the log and the status move to the new
            // document then (a download or a 204 never commits).
            pendingDocument = (documentURL, status)
        }
    }

    /// Under the lock.
    private func appendNote(_ event: String) {
        events.append(event)
        if events.count > Self.eventLimit {
            events.removeFirst(events.count - Self.eventLimit)
        }
    }

    /// What a helper answer says of the page beyond the op: its title and
    /// visibility (barrier, pageInfo, snapshot{afterFrame}).
    private func remember(_ answer: CDPObject) {
        let pageTitle = answer.string("title")
        let state = answer.string("visibility")
        guard pageTitle != nil || state != nil else { return }
        let generation = signals.state.generation
        lock.withLock {
            if let pageTitle { helperTitle = (generation, pageTitle) }
            if let state { visibility = (generation, state) }
        }
    }

    // MARK: - Pure parts

    /// The per-target init (design §3.1 as the step-0 probes amended it):
    /// exactly fixtures/init.json's `target`, in one write. No
    /// `Runtime.enable`: the binding is re-added at every commit instead.
    /// The child auto-attach has no filter: a target paused and left
    /// unattached never starts (workers would hang).
    public static func initCommands(viewport: CGSize, userAgent: ChromiumUserAgent,
                                    relay: String = AgentScripts.relay, pageHook: String = AgentScripts.pageHook,
                                    helperTopFrame: String = ChromiumTabRuntime.helperTopFrame) -> [(String, [String: Any])] {
        let empty: [String: Any] = [:]
        let enabled: [String: Any] = ["enabled": true]
        let relayScript: [String: Any] = ["source": relay, "worldName": ChromiumHelper.worldName,
                                          "runImmediately": true]
        let hookScript: [String: Any] = ["source": pageHook, "runImmediately": true]
        let helperScript: [String: Any] = ["source": helperTopFrame, "worldName": ChromiumHelper.worldName,
                                           "runImmediately": true]
        let lifecycle: [String: Any] = ["state": "active"]
        var commands: [(String, [String: Any])] = []
        commands.append(("Page.enable", empty))
        commands.append(("Page.setLifecycleEventsEnabled", enabled))
        commands.append(("Network.enable", networkEnableParams))
        commands.append(("Page.addScriptToEvaluateOnNewDocument", relayScript))
        commands.append(("Page.addScriptToEvaluateOnNewDocument", hookScript))
        commands.append(("Page.addScriptToEvaluateOnNewDocument", helperScript))
        commands.append(("Runtime.addBinding", PageSignals.addBindingParams))
        commands.append(("Page.setInterceptFileChooserDialog", enabled))
        commands.append(("Emulation.setDeviceMetricsOverride", deviceMetrics(normalized(viewport))))
        commands.append(("Emulation.setFocusEmulationEnabled", enabled))
        commands.append(("Emulation.setUserAgentOverride", userAgent.overrideParams))
        commands.append(("Page.setWebLifecycleState", lifecycle))
        commands.append(("Target.setAutoAttach", autoAttachParams))
        commands.append(("Runtime.runIfWaitingForDebugger", empty))
        return commands
    }

    /// The panel script (AgentPanelScript: what the person's input in the
    /// panel asks of the page), top frame only behind the helper's own guard.
    static let panelTopFrame = "if (window === window.top) {\n" + AgentPanelScript.source + "\n}"

    /// The panel script as a function body, for a document the injected
    /// script missed (its own guard keeps it to one install).
    static let panelInjectFunction = "function() {\n" + AgentPanelScript.source + "\n}"

    /// The panel script for every document of the tab, in the helper's
    /// world (`runImmediately`: the current one too).
    static var panelScriptCommand: (String, [String: Any]) {
        let params: [String: Any] = ["source": panelTopFrame, "worldName": ChromiumHelper.worldName,
                                     "runImmediately": true]
        return ("Page.addScriptToEvaluateOnNewDocument", params)
    }

    /// What `start` sends: the CDP harness's init (`initCommands`, exactly
    /// fixtures/init.json), with the panel script right after the helper —
    /// before the target runs, so its first document has it. The harness
    /// installs the panel script on its own (panel-input.test.mjs).
    static func startCommands(viewport: CGSize, userAgent: ChromiumUserAgent) -> [(String, [String: Any])] {
        var commands = initCommands(viewport: viewport, userAgent: userAgent)
        let helper = commands.lastIndex { $0.0 == "Page.addScriptToEvaluateOnNewDocument" } ?? (commands.count - 1)
        commands.insert(panelScriptCommand, at: helper + 1)
        return commands
    }

    /// An out-of-process iframe's init: the relay (every frame of it), the
    /// hook, the binding, XHR/fetch, file choosers, its own children; then it
    /// runs. No helper: it serves the top frame only.
    public static func childFrameInitCommands(relay: String = AgentScripts.relay,
                                              pageHook: String = AgentScripts.pageHook) -> [(String, [String: Any])] {
        let empty: [String: Any] = [:]
        let enabled: [String: Any] = ["enabled": true]
        let relayScript: [String: Any] = ["source": relay, "worldName": ChromiumHelper.worldName,
                                          "runImmediately": true]
        let hookScript: [String: Any] = ["source": pageHook, "runImmediately": true]
        var commands: [(String, [String: Any])] = []
        commands.append(("Page.enable", empty))
        commands.append(("Network.enable", networkEnableParams))
        commands.append(("Page.addScriptToEvaluateOnNewDocument", relayScript))
        commands.append(("Page.addScriptToEvaluateOnNewDocument", hookScript))
        commands.append(("Runtime.addBinding", PageSignals.addBindingParams))
        commands.append(("Page.setInterceptFileChooserDialog", enabled))
        commands.append(("Target.setAutoAttach", autoAttachParams))
        commands.append(("Runtime.runIfWaitingForDebugger", empty))
        return commands
    }

    /// What every `Page.frameNavigated` brings, in this order: the frame's
    /// world made sure of, then the binding into it (it reaches only the
    /// contexts that exist when it is added). fixtures/init.json's
    /// `onFrameNavigated`. On the tab's own session the sink sends the first
    /// and PageSignals the second.
    public static func frameNavigatedCommands(frameId: String) -> [(String, [String: Any])] {
        [("Page.createIsolatedWorld", ChromiumHelper.createWorldParams(frameId: frameId)),
         ("Runtime.addBinding", PageSignals.addBindingParams)]
    }

    /// No response bodies are kept: Loom reads statuses, never bodies.
    static var networkEnableParams: [String: Any] {
        ["maxTotalBufferSize": 0, "maxResourceBufferSize": 0, "maxPostDataSize": 0]
    }

    static var autoAttachParams: [String: Any] {
        ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true]
    }

    /// `Emulation.setDeviceMetricsOverride` at device scale 1: CSS pixels are
    /// image pixels, `devicePixelRatio` never moves under a test.
    public static func deviceMetrics(_ size: CGSize) -> [String: Any] {
        let width = side(size.width)
        let height = side(size.height)
        return ["width": width, "height": height, "deviceScaleFactor": 1, "mobile": false,
                "screenWidth": width, "screenHeight": height]
    }

    /// The stuck probe, as fixtures/init.json has it.
    public static var stuckProbeCommand: (String, [String: Any]) {
        ("Runtime.evaluate", ["expression": "1", "returnByValue": true])
    }

    /// A binding payload worth parsing: at most `maxBindingPayloadBytes`
    /// of UTF-8.
    public static func admitsBindingPayload(_ payload: String) -> Bool {
        payload.utf8.count <= maxBindingPayloadBytes
    }

    /// A binding payload as the relay posts it — `JSON.stringify` of one
    /// hook message — validated by `AgentHookMessage.parse`; nil for
    /// anything else, an oversized payload unparsed.
    public static func hookMessage(fromPayload payload: String) -> AgentHookMessage? {
        guard admitsBindingPayload(payload),
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return nil }
        return AgentHookMessage.parse(object)
    }

    /// Who speaks in a dialog's banner (the WebKit engine's rule): its
    /// frame's host; the page's own for the main frame; "A frame embedded in
    /// <host>" for an opaque or unknown origin — a data: or sandboxed iframe
    /// never passes for the page under test.
    public static func dialogHost(frameOrigin: String?, isMainFrame: Bool?, topURL: String) -> String {
        let topHost = URL(string: topURL)?.host() ?? ""
        let shownTop = topHost.isEmpty ? "this page" : topHost
        if let frameOrigin, let host = URL(string: frameOrigin)?.host(), !host.isEmpty {
            return host
        }
        if isMainFrame != false {
            return shownTop
        }
        return "A frame embedded in \(shownTop)"
    }

    /// `### Modal state` for a dialog. A beforeunload is shown as the
    /// confirm it is until the answer builder has a kind of its own for it.
    public static func modalState(for dialog: PageDialog, host: String) -> AgentModalState {
        switch dialog.kind {
        case .alert:
            return AgentModalState(kind: .alert, message: dialog.message, host: host)
        case .confirm, .beforeunload:
            return AgentModalState(kind: .confirm, message: dialog.message, host: host)
        case .prompt:
            return AgentModalState(kind: .prompt(defaultText: dialog.defaultPrompt), message: dialog.message,
                                   host: host)
        }
    }

    /// The agent's words for a failure on the page (AgentBrowser's
    /// `error(for:)`): an `AgentError` passes as it is, a cancellation stays
    /// one.
    public static func agentError(_ error: Error) -> Error {
        if error is AgentError || error is CancellationError { return error }
        guard let cdp = error as? CDPError else { return AgentError.failed(String(describing: error)) }
        switch cdp {
        case .interrupted(.dialogOpened):
            return AgentError.conflict("a dialog is open: answer it with browser_handle_dialog")
        case .interrupted(.navigated):
            return AgentError.failed("the page navigated away during the command")
        case .interrupted(.crashed):
            return AgentError.unavailable("the page's process stopped during the command")
        case .interrupted(.detached):
            return AgentError.unavailable("the tab was closed during the command")
        case .timeout:
            return AgentError.timeout("the page did not answer in time")
        case .disconnected(let reason):
            return AgentError.unavailable("the agent's browser stopped during the command (\(reason))")
        case .cancelled:
            return CancellationError()
        case .protocolError(let method, _, let message):
            return AgentError.failed("Chromium refused \(method): \(message)")
        }
    }

    /// A document gone under a call: the barrier's "lost".
    static func isDocumentLoss(_ error: Error) -> Bool {
        guard let cdp = error as? CDPError, case .interrupted(let reason) = cdp else { return false }
        return reason == .navigated
    }

    static func refuseUnopenable(_ address: String) throws {
        guard ChromiumBrowser.isOpenable(address) else {
            let scheme = URL(string: address)?.scheme.map { $0 + ":" } ?? "this address"
            throw AgentError.invalid("the agent's browser opens http(s) addresses only, not \(scheme)")
        }
    }

    static func describe(_ error: Error) -> String {
        if let agent = error as? AgentError { return agent.message }
        guard let cdp = error as? CDPError else { return String(describing: error) }
        switch cdp {
        case .protocolError(_, _, let message): return message
        case .timeout: return "no answer in time"
        case .interrupted(let reason): return "interrupted (\(reason))"
        case .disconnected(let reason): return reason
        case .cancelled: return "cancelled"
        }
    }

    /// Same page, its fragment aside: a response and the commit it led to.
    static func sameAddress(_ left: String, _ right: String) -> Bool {
        func base(_ address: String) -> Substring {
            guard let hash = address.firstIndex(of: "#") else { return Substring(address) }
            return address[..<hash]
        }
        return base(left) == base(right)
    }

    static func normalized(_ size: CGSize) -> CGSize {
        CGSize(width: side(size.width), height: side(size.height))
    }

    /// A viewport side in whole CSS px, 1 to 16 384.
    static func side(_ value: CGFloat) -> Int {
        let raw = Double(value)
        guard raw.isFinite else { return 800 }
        return Int(min(max(raw, 1), 16_384).rounded())
    }

    /// A JavaScript string literal (JSON's, which JS reads alike).
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) else {
            return "\"\""
        }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Seconds on the monotonic clock, for the rate limiter.
    static func uptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// The tab session's sink. Weak towards the runtime: the connection holds
/// its sinks, the runtime is the core's.
private final class TabSessionSink: CDPEventSink, @unchecked Sendable {
    weak var runtime: ChromiumTabRuntime?

    func handle(method: String, params: CDPObject, session: CDPSessionID?) {
        runtime?.sessionEvent(method: method, params: params, session: session)
    }
}

/// An out-of-process iframe's sink (its own flattened session).
private final class ChildFrameSink: CDPEventSink, @unchecked Sendable {
    private weak var runtime: ChromiumTabRuntime?
    private let session: CDPSessionID

    init(runtime: ChromiumTabRuntime, session: CDPSessionID) {
        self.runtime = runtime
        self.session = session
    }

    func handle(method: String, params: CDPObject, session eventSession: CDPSessionID?) {
        runtime?.childEvent(method: method, params: params, session: eventSession ?? session)
    }
}
