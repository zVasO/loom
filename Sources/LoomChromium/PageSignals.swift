import Dispatch
import Foundation

/// What a page's session asks of the connection, as closures: the tests
/// record them, the engine points them at its `CDPConnection`.
public struct PageSignalsLink: Sendable {
    /// Fire-and-forget: a dialog's answer, the binding re-added. Called on
    /// the reader queue, so it never waits for the reply.
    public var post: @Sendable (_ method: String, _ params: [String: Any]) -> Void
    /// Fails the session's pending calls that accept `reason`.
    public var interrupt: @Sendable (_ reason: CDPInterruption) -> Void
    /// Fails every pending call of the session.
    public var failAll: @Sendable (_ error: CDPError) -> Void

    public init(post: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> Void,
                interrupt: @escaping @Sendable (_ reason: CDPInterruption) -> Void,
                failAll: @escaping @Sendable (_ error: CDPError) -> Void) {
        self.post = post
        self.interrupt = interrupt
        self.failAll = failAll
    }

    /// The session's own commands. The connection is held weakly: it holds
    /// the sink that holds this link.
    public static func connection(_ connection: CDPConnection, session: CDPSessionID) -> PageSignalsLink {
        PageSignalsLink(
            post: { [weak connection] method, params in
                _ = connection?.post(method, params, session: session)
            },
            interrupt: { [weak connection] reason in
                connection?.interrupt(session: session, reason)
            },
            failAll: { [weak connection] error in
                connection?.failAll(session: session, error)
            })
    }

    /// Goes nowhere: a page whose events are only read.
    public static let unlinked = PageSignalsLink(post: { _, _ in }, interrupt: { _ in }, failAll: { _ in })
}

public enum PageRequestKind: String, Sendable, Equatable {
    // The raw values are NetworkLog.Kind's.
    case xhr, fetch
}

/// The network facts the owner's NetworkLog records: XHR and fetch of any
/// frame, and the main document's answer. Other request types are dropped
/// on the reader queue, unparsed beyond their `type`.
public enum PageNetworkFact: Sendable, Equatable {
    case started(requestId: String, kind: PageRequestKind, method: String, url: String)
    /// `status` from its response when one came; `errorText` when it failed
    /// (`canceled`: aborted by the page or a navigation).
    case ended(requestId: String, status: Int?, errorText: String?, canceled: Bool, durationMs: Int?)
    case document(url: String, status: Int)
}

public struct PageFileChooser: Sendable, Equatable {
    /// `DOM.setFileInputFiles` sets the files on this input.
    public var backendNodeId: Int?
    public var frameId: String?
    /// "selectSingle" or "selectMultiple".
    public var mode: String

    public var multiple: Bool { mode == "selectMultiple" }

    public init(backendNodeId: Int?, frameId: String?, mode: String) {
        self.backendNodeId = backendNodeId
        self.frameId = frameId
        self.mode = mode
    }
}

/// What a page's events tell its owner, delivered in wire order. Only
/// strings and numbers: no LoomWeb type is known here.
public enum PageFact: Sendable, Equatable {
    /// A payload the in-page relay posted to `__loomHookBinding`, at most
    /// `PageSignals.maxBindingPayloadBytes`; still untrusted: the owner
    /// parses and rate-limits it.
    case binding(payload: String, executionContextId: Int?)
    /// The page flooded the binding: it is removed until the next main-frame
    /// commit.
    case bindingCut
    case network(PageNetworkFact)
    /// A new main-frame document. `generation` counts them.
    case committed(url: String, loaderId: String, generation: Int, securityOrigin: String?)
    case sameDocument(url: String)
    case lifecycle(name: String, loaderId: String)
    /// A dialog waits for an answer: the page is blocked on it.
    case dialogOpened(PageDialog)
    /// Loom answered it at once (a dialog loop, the agent leaving the page).
    case dialogAutoAnswered(PageDialog, accepted: Bool, reason: DialogLedger.AutoReason)
    /// Closed by something other than an answer from Loom.
    case dialogClosed(PageDialog)
    case dialogDismissed(PageDialog, reason: DialogLedger.DismissReason)
    case fileChooser(PageFileChooser)
    /// Refused (downloads are denied at the browser level): for the note.
    case download(guid: String?, url: String, suggestedFilename: String)
    case targetInfo(title: String, url: String)
    case crashed
    case detached(reason: String?)
}

/// Where the page stands now.
public struct PageSignalsState: Sendable, Equatable {
    public var mainFrameId: String
    public var url: String
    public var title: String
    /// The current document's loader; nil before the first commit.
    public var loaderId: String?
    /// Main-frame commits so far.
    public var generation: Int
    /// Lifecycle milestones the current document reached ("DOMContentLoaded", "load").
    public var reached: Set<String>
    public var dialog: PageDialog?
    public var crashed: Bool
    public var detached: Bool
    /// XHR and fetch not answered yet.
    public var requestsInFlight: Int
}

/// One per target session (ADR-0016, design §4 and §6): the sink of its
/// DevTools events. On the CDP reader queue, in wire order, it turns them
/// into `SettleEvent`s it keeps, applies them to the settles waiting, keeps
/// the dialog ledger, and hands the facts to its owner — all before any
/// later reply resumes, so a verdict read after a reply has seen every event
/// Chromium sent before it.
///
/// Never `Runtime.enable`: the console comes through the binding, which
/// Chromium installs only in the contexts that exist when it is added — so
/// it is added again on every `Page.frameNavigated`, main frame and
/// subframes (the relay queues its posts until it appears).
public final class PageSignals: CDPEventSink, @unchecked Sendable {

    public static let bindingName = "__loomHookBinding"
    public static let worldName = "loom-agent"
    /// Over this many binding calls in a second, the binding is removed
    /// until the next main-frame commit (AgentMessageProxy's figure).
    public static let bindingFloodPerSecond = 2_000
    /// The relay caps a message at 4 096 characters; with its envelope, a
    /// payload over this was not written by it.
    public static let maxBindingPayloadBytes = 16 << 10

    /// `Runtime.addBinding` as sent at init and after every commit.
    public static var addBindingParams: [String: Any] {
        ["name": bindingName, "executionContextName": worldName]
    }

    private struct Entry {
        let sequence: Int
        let at: ContinuousClock.Instant
        let event: SettleEvent
    }

    private struct TrackedRequest {
        let kind: PageRequestKind
        let key: String
        let startedAt: ContinuousClock.Instant
        var status: Int?
    }

    private struct Waiter {
        var machine: SettleMachine
        let continuation: CheckedContinuation<SettleOutcome, Never>
        let deadline: ContinuousClock.Instant
        var timerAt: ContinuousClock.Instant?
        var timer: DispatchWorkItem?
    }

    /// Side effects gathered under the lock, carried out past it, in this
    /// order: commands to Chromium, call failures, facts, resumed waits.
    private struct Effects {
        var posts: [(String, [String: Any])] = []
        var failure: CDPError?
        var interrupts: [CDPInterruption] = []
        var facts: [PageFact] = []
        var resumes: [(CheckedContinuation<SettleOutcome, Never>, SettleOutcome)] = []
    }

    public let session: CDPSessionID
    private let link: PageSignalsLink
    private let pollWindow: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let timerQueue: DispatchQueue

    // Guarded by `lock`.
    private let lock = NSLock()
    private var factHandler: (@Sendable (PageFact) -> Void)?
    private var mainFrameId: String
    private var journal: [Entry] = []
    private var sequence = 0
    private var generation = 0
    private var url = ""
    private var title = ""
    private var loaderId: String?
    private var reached: Set<String> = []
    private var crashed = false
    private var detached = false
    private var ledger = DialogLedger()
    /// XHR and fetch not answered yet.
    private var requests: [String: TrackedRequest] = [:]
    /// Answered, their body not finished: requestId → key, oldest first.
    private var answeredRequests: [(id: String, key: String)] = []
    private var recentEnded: [(key: String, at: ContinuousClock.Instant)] = []
    /// The main frame's Document requests in flight: requestId → loaderId.
    private var mainDocuments: [String: String] = [:]
    private var frameOrigins: [String: String] = [:]
    private var knownFrames: Set<String> = []
    private var bindingCut = false
    private var bindingWindowStart: ContinuousClock.Instant?
    private var bindingCount = 0
    private var downloads: [(guid: String?, url: String, at: ContinuousClock.Instant)] = []
    private var waiters: [Int: Waiter] = [:]
    private var lastWaiterId = 0
    private var cancelledWaits: Set<Int> = []

    static let journalLimit = 8_192
    static let requestLimit = 2_000

    /// `mainFrameId`: the page target's id — Chromium names a page's main
    /// frame after its target. A parentless commit with another id corrects it.
    public init(session: CDPSessionID, mainFrameId: String, link: PageSignalsLink,
                pollWindow: Duration = SettlePolicy().pollWindow,
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.session = session
        self.mainFrameId = mainFrameId
        self.link = link
        self.pollWindow = pollWindow
        self.clock = clock
        self.timerQueue = DispatchQueue(label: "app.loom.cdp.settle.\(session.rawValue)")
        knownFrames.insert(mainFrameId)
    }

    /// Facts go to `handler` in wire order: on the reader queue for the
    /// page's events, on the caller's thread for the `note…` calls. It must
    /// not block, nor wait for a reply (it may post).
    public func setFactHandler(_ handler: (@Sendable (PageFact) -> Void)?) {
        lock.lock()
        let replaced = factHandler
        factHandler = handler
        lock.unlock()
        withExtendedLifetime(replaced) {}
    }

    public var state: PageSignalsState {
        lock.lock()
        defer { lock.unlock() }
        return PageSignalsState(mainFrameId: mainFrameId, url: url, title: title, loaderId: loaderId,
                                generation: generation, reached: reached, dialog: ledger.open,
                                crashed: crashed, detached: detached, requestsInFlight: requests.count)
    }

    /// A frame of this page's session (main, child, or one seen navigating):
    /// where the router sends a frame's download.
    public func ownsFrame(_ frameId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return knownFrames.contains(frameId)
    }

    /// The `securityOrigin` a frame last committed with; nil when unknown.
    public func frameOrigin(_ frameId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return frameOrigins[frameId]
    }

    // MARK: - Settling

    /// Taken just before an action is sent: the settle looks at what follows.
    public func mark() -> PageMark {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        pruneRecentEnded(now)
        var keys = Set(requests.values.map { $0.key })
        for ended in recentEnded {
            keys.insert(ended.key)
        }
        return PageMark(sequence: sequence, generation: generation, pollKeys: keys, at: now)
    }

    /// Waits until the settle of `kind` since `mark` is done, or `deadline`
    /// (then: what it is at that point, "still loading" for a load under
    /// way). Every event since the mark counts, including those applied
    /// before this call. Resumed from the reader queue when an event
    /// decides it, or from a timer when time does. A cancelled task gets its
    /// answer at once. A dialog still open, or a detach, ends it at once; a
    /// crash before the mark does not (the core may be reloading the page).
    public func wait(_ kind: SettleMachine.Kind, from mark: PageMark, policy: SettlePolicy = SettlePolicy(),
                     deadline: ContinuousClock.Instant) async -> SettleOutcome {
        lock.lock()
        lastWaiterId += 1
        let id = lastWaiterId
        lock.unlock()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SettleOutcome, Never>) in
                self.begin(id, kind: kind, mark: mark, policy: policy, deadline: deadline,
                           continuation: continuation)
            }
        } onCancel: {
            self.cancelWait(id)
        }
    }

    /// The settle events applied since `mark`, with when: what a wait from
    /// that mark replays (diagnostics; `SettleMachine.replay`).
    public func events(since mark: PageMark) -> [(at: ContinuousClock.Instant, event: SettleEvent)] {
        lock.lock()
        defer { lock.unlock() }
        return journal.filter { $0.sequence > mark.sequence }.map { (at: $0.at, event: $0.event) }
    }

    /// The core's barrier answered (`lost`: its document went away under
    /// it). The settle of an action with no navigation waits for this.
    public func noteBarrier(lost: Bool) {
        let now = clock()
        var effects = Effects()
        lock.lock()
        record(lost ? .barrierLost : .barrierDone, at: now, &effects)
        lock.unlock()
        perform(effects)
    }

    // MARK: - Dialogs

    /// While on, a beforeunload dialog is accepted at once: the agent itself
    /// navigates, goes back or reloads. Off again once its settle is over.
    public func setAutoAcceptBeforeUnload(_ on: Bool) {
        lock.lock()
        ledger.autoAcceptBeforeUnload = on
        lock.unlock()
    }

    /// The agent's or the person's answer to the open dialog — sent once;
    /// a second answer fails with `.alreadyHandled`. `dialogId` nil: the one
    /// open, whichever it is.
    public func answerDialog(accept: Bool, promptText: String? = nil,
                             dialogId: Int? = nil) -> Result<PageDialog, DialogLedger.AnswerError> {
        lock.lock()
        let result = ledger.answer(accept: accept, promptText: promptText, dialogId: dialogId)
        lock.unlock()
        switch result {
        case .success(let answered):
            link.post(DialogLedger.Reply.method, answered.reply.params)
            return .success(answered.dialog)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The agent navigates away from a page blocked on a dialog: dismissed,
    /// as a browser does. Returns it, for the note; nil when none was open.
    @discardableResult
    public func dismissDialog() -> PageDialog? {
        lock.lock()
        let dismissed = ledger.dismiss(.navigation)
        lock.unlock()
        guard let dismissed else { return nil }
        if let reply = dismissed.reply {
            link.post(DialogLedger.Reply.method, reply.params)
        }
        return dismissed.dialog
    }

    // MARK: - From the browser session (the router)

    /// `Target.targetInfoChanged` for this target.
    public func noteTargetInfo(title newTitle: String, url newURL: String) {
        var effects = Effects()
        lock.lock()
        if newTitle != title || newURL != url {
            title = newTitle
            if !newURL.isEmpty { url = newURL }
            effects.facts.append(.targetInfo(title: newTitle, url: newURL))
        }
        lock.unlock()
        perform(effects)
    }

    /// `Browser.downloadWillBegin` for a frame of this page, as the router
    /// reports it. `Page.downloadWillBegin` is read too: one fact per
    /// download (same guid, or same URL within 5 s).
    public func noteDownload(url downloadURL: String, suggestedFilename: String = "", guid: String? = nil) {
        let now = clock()
        var effects = Effects()
        lock.lock()
        download(guid: guid, url: downloadURL, suggestedFilename: suggestedFilename, at: now, &effects)
        lock.unlock()
        perform(effects)
    }

    /// `Target.targetCrashed` for this target (also `Inspector.targetCrashed`).
    public func noteCrashed() {
        let now = clock()
        var effects = Effects()
        lock.lock()
        crash(at: now, &effects)
        lock.unlock()
        perform(effects)
    }

    /// `Target.detachedFromTarget` or `targetDestroyed` (also `Inspector.detached`).
    public func noteDetached(reason: String? = nil) {
        let now = clock()
        var effects = Effects()
        lock.lock()
        detach(reason: reason, at: now, &effects)
        lock.unlock()
        perform(effects)
    }

    // MARK: - Events (reader queue)

    public func handle(method: String, params: CDPObject, session: CDPSessionID?) {
        let now = clock()
        var effects = Effects()
        lock.lock()
        translate(method, params, at: now, &effects)
        lock.unlock()
        perform(effects)
    }

    private func translate(_ method: String, _ params: CDPObject, at now: ContinuousClock.Instant,
                           _ effects: inout Effects) {
        switch method {
        case "Page.frameRequestedNavigation":
            // newTab/newWindow is a popup (the router's), download a download.
            guard isMain(params.string("frameId")),
                  (params.string("disposition") ?? "currentTab") == "currentTab" else { return }
            record(.navRequested, at: now, &effects)

        case "Page.frameStartedNavigating":
            guard isMain(params.string("frameId")) else { return }
            switch params.string("navigationType") ?? "differentDocument" {
            case "sameDocument", "historySameDocument":
                return   // navigatedWithinDocument follows
            default:
                record(.navStarted(loaderId: params.string("loaderId")), at: now, &effects)
            }

        case "Page.frameStartedLoading":
            // Also for pushState and hash changes: navigatedWithinDocument
            // then ends it.
            guard isMain(params.string("frameId")) else { return }
            record(.navStarted(loaderId: nil), at: now, &effects)

        case "Page.navigatedWithinDocument":
            guard isMain(params.string("frameId")) else { return }
            if let newURL = params.string("url") { url = newURL }
            record(.sameDocument, at: now, &effects)
            effects.facts.append(.sameDocument(url: url))

        case "Page.frameNavigated":
            frameNavigated(params, at: now, &effects)

        case "Page.frameAttached":
            if let frameId = params.string("frameId"), knownFrames.count < 1_000 {
                knownFrames.insert(frameId)
            }

        case "Page.frameDetached":
            // A frame swapped into another process lives on elsewhere.
            if let frameId = params.string("frameId"), params.string("reason") != "swap",
               frameId != mainFrameId {
                knownFrames.remove(frameId)
                frameOrigins.removeValue(forKey: frameId)
            }

        case "Page.lifecycleEvent":
            guard isMain(params.string("frameId")), let name = params.string("name"),
                  name == "load" || name == "DOMContentLoaded",
                  let lifecycleLoader = params.string("loaderId") else { return }
            if lifecycleLoader == loaderId { reached.insert(name) }
            record(.lifecycle(name: name, loaderId: lifecycleLoader), at: now, &effects)
            effects.facts.append(.lifecycle(name: name, loaderId: lifecycleLoader))

        case "Page.frameStoppedLoading":
            guard isMain(params.string("frameId")) else { return }
            record(.navStopped(loaderId: nil), at: now, &effects)

        case "Page.javascriptDialogOpening":
            dialogOpening(params, at: now, &effects)

        case "Page.javascriptDialogClosed":
            if let dialog = ledger.closed() {
                effects.facts.append(.dialogClosed(dialog))
            }

        case "Page.fileChooserOpened":
            // It blocks nothing: the page runs on, but the action is over.
            let chooser = PageFileChooser(backendNodeId: params.int("backendNodeId"),
                                          frameId: params.string("frameId"),
                                          mode: params.string("mode") ?? "selectSingle")
            record(.modal, at: now, &effects)
            effects.facts.append(.fileChooser(chooser))

        case "Page.downloadWillBegin":
            download(guid: params.string("guid"), url: params.string("url") ?? "",
                     suggestedFilename: params.string("suggestedFilename") ?? "", at: now, &effects)

        case "Network.requestWillBeSent":
            requestWillBeSent(params, at: now, &effects)

        case "Network.responseReceived":
            guard let requestId = params.string("requestId"), let response = params.object("response") else { return }
            let status = response.int("status")
            if var tracked = requests.removeValue(forKey: requestId) {
                // The answer ends it, for the log (as the WebKit hook reports
                // a fetch once its promise resolves) and for the settle: an
                // unread body never finishes loading.
                tracked.status = status
                answeredRequests.append((id: requestId, key: tracked.key))
                if answeredRequests.count > 512 { answeredRequests.removeFirst(answeredRequests.count - 512) }
                ended(requestId, tracked, errorText: nil, canceled: false, answered: true, at: now, &effects)
            } else if mainDocuments[requestId] != nil, let status {
                effects.facts.append(.network(.document(url: response.string("url") ?? url, status: status)))
            }

        case "Network.loadingFinished":
            guard let requestId = params.string("requestId") else { return }
            if let tracked = requests.removeValue(forKey: requestId) {
                ended(requestId, tracked, errorText: nil, canceled: false, answered: false, at: now, &effects)
            } else if takeAnswered(requestId) {
                record(.requestEnded(id: requestId), at: now, &effects)
            } else {
                mainDocuments.removeValue(forKey: requestId)
            }

        case "Network.loadingFailed":
            guard let requestId = params.string("requestId") else { return }
            let errorText = params.string("errorText") ?? ""
            let canceled = params.bool("canceled") ?? false
            if let tracked = requests.removeValue(forKey: requestId) {
                ended(requestId, tracked, errorText: errorText, canceled: canceled, answered: false, at: now, &effects)
            } else if takeAnswered(requestId) {
                // Its body broke off after the answer the log already has.
                record(.requestEnded(id: requestId), at: now, &effects)
            } else if let documentLoader = mainDocuments.removeValue(forKey: requestId) {
                // ERR_ABORTED: a download, a 204, a superseded load — a stop,
                // not a failure.
                if canceled || errorText.hasSuffix("ERR_ABORTED") {
                    record(.navStopped(loaderId: documentLoader), at: now, &effects)
                } else {
                    record(.docFailed(loaderId: documentLoader, errorText: errorText), at: now, &effects)
                }
            }

        case "Runtime.bindingCalled":
            bindingCalled(params, at: now, &effects)

        case "Inspector.targetCrashed":
            crash(at: now, &effects)

        case "Inspector.detached":
            detach(reason: params.string("reason"), at: now, &effects)

        case "Target.targetInfoChanged":
            if let info = params.object("targetInfo") {
                let newTitle = info.string("title") ?? title
                let newURL = info.string("url") ?? url
                if newTitle != title || newURL != url {
                    title = newTitle
                    if !newURL.isEmpty { url = newURL }
                    effects.facts.append(.targetInfo(title: newTitle, url: newURL))
                }
            }

        default:
            break
        }
    }

    private func isMain(_ frameId: String?) -> Bool {
        frameId != nil && frameId == mainFrameId
    }

    private func frameNavigated(_ params: CDPObject, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        guard let frame = params.object("frame"), let frameId = frame.string("id") else { return }
        let origin = frame.string("securityOrigin")
        if knownFrames.count < 1_000 || knownFrames.contains(frameId) {
            knownFrames.insert(frameId)
            frameOrigins[frameId] = origin
        }
        let isMainFrame = frame.string("parentId") == nil
        guard isMainFrame else {
            // A child document: the binding reaches its loom-agent world
            // only if added again now.
            if !bindingCut {
                effects.posts.append(("Runtime.addBinding", Self.addBindingParams))
            }
            return
        }

        if frameId != mainFrameId {
            knownFrames.remove(mainFrameId)
            mainFrameId = frameId
            knownFrames.insert(frameId)
        }
        let newLoader = frame.string("loaderId") ?? ""
        generation += 1
        loaderId = newLoader
        url = (frame.string("url") ?? "") + (frame.string("urlFragment") ?? "")
        reached = []
        crashed = false
        mainDocuments = mainDocuments.filter { $0.value == newLoader }
        // The old document's requests end with it (Chromium cancels them,
        // or never says): the new one starts with none.
        requests.removeAll()
        answeredRequests.removeAll()

        bindingCut = false
        bindingWindowStart = nil
        bindingCount = 0
        effects.posts.append(("Runtime.addBinding", Self.addBindingParams))

        if let dialog = ledger.documentCommitted() {
            effects.facts.append(.dialogDismissed(dialog, reason: .documentChanged))
        }
        record(.committed(loaderId: newLoader), at: now, &effects)
        if params.string("type") == "BackForwardCacheRestore" {
            // A restored page fires no load: it is loaded.
            reached = ["DOMContentLoaded", "load"]
            record(.lifecycle(name: "load", loaderId: newLoader), at: now, &effects)
        }
        // Helper calls into the old document's world will never answer.
        effects.interrupts.append(.navigated)
        effects.facts.append(.committed(url: url, loaderId: newLoader, generation: generation,
                                        securityOrigin: origin))
    }

    private func dialogOpening(_ params: CDPObject, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        let frameId = params.string("frameId")
        let origin = frameId.flatMap { frameOrigins[$0] }
        let mainFrame = frameId.map { $0 == mainFrameId }
        let (superseded, decision) = ledger.opening(type: params.string("type") ?? "alert",
                                                    message: params.string("message") ?? "",
                                                    defaultPrompt: params.string("defaultPrompt"),
                                                    url: params.string("url") ?? "", frameId: frameId,
                                                    frameOrigin: origin, isMainFrame: mainFrame)
        if let superseded {
            effects.facts.append(.dialogDismissed(superseded, reason: .superseded))
        }
        switch decision {
        case .park(let dialog):
            record(.modal, at: now, &effects)
            // Input and helper calls wait behind the dialog: they give up now.
            effects.interrupts.append(.dialogOpened)
            effects.facts.append(.dialogOpened(dialog))
        case .answer(let dialog, let reply, let reason):
            effects.posts.append((DialogLedger.Reply.method, reply.params))
            effects.facts.append(.dialogAutoAnswered(dialog, accepted: reply.accept, reason: reason))
        }
    }

    private func requestWillBeSent(_ params: CDPObject, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        guard let requestId = params.string("requestId") else { return }
        switch params.string("type") ?? "" {
        case "Document":
            // A subframe's document is not a load of this page.
            guard isMain(params.string("frameId")) else { return }
            let documentLoader = params.string("loaderId") ?? requestId
            if mainDocuments[requestId] == nil, mainDocuments.count >= 64 { mainDocuments.removeAll() }
            mainDocuments[requestId] = documentLoader
            record(.navStarted(loaderId: documentLoader), at: now, &effects)

        case "XHR", "Fetch":
            let request = params.object("request")
            let requestURL = request?.string("url") ?? ""
            if var tracked = requests[requestId] {
                // A redirect: the same request goes on; its last answer counts.
                tracked.status = nil
                requests[requestId] = tracked
                return
            }
            if requests.count >= Self.requestLimit {
                // A page that never lets its requests end: the oldest go.
                if let oldest = requests.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                    requests.removeValue(forKey: oldest)
                }
            }
            let kind: PageRequestKind = params.string("type") == "XHR" ? .xhr : .fetch
            let method = request?.string("method") ?? "GET"
            let key = Self.requestKey(method: method, url: requestURL)
            requests[requestId] = TrackedRequest(kind: kind, key: key, startedAt: now, status: nil)
            record(.requestStarted(id: requestId, key: key), at: now, &effects)
            effects.facts.append(.network(.started(requestId: requestId, kind: kind, method: method, url: requestURL)))

        default:
            return   // images, scripts, sockets, beacons: not ours to wait for
        }
    }

    /// `answered`: its response came (the body may still be loading);
    /// otherwise it finished or failed without one.
    private func ended(_ requestId: String, _ tracked: TrackedRequest, errorText: String?, canceled: Bool,
                       answered: Bool, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        recentEnded.append((key: tracked.key, at: now))
        if recentEnded.count > 512 { recentEnded.removeFirst(recentEnded.count - 512) }
        record(answered ? .requestAnswered(id: requestId) : .requestEnded(id: requestId), at: now, &effects)
        effects.facts.append(.network(.ended(requestId: requestId, status: errorText == nil ? tracked.status : nil,
                                             errorText: errorText, canceled: canceled,
                                             durationMs: Self.milliseconds(from: tracked.startedAt, to: now))))
    }

    private func takeAnswered(_ requestId: String) -> Bool {
        guard let index = answeredRequests.lastIndex(where: { $0.id == requestId }) else { return false }
        answeredRequests.remove(at: index)
        return true
    }

    private func bindingCalled(_ params: CDPObject, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        guard params.string("name") == Self.bindingName, !bindingCut,
              let payload = params.string("payload") else { return }
        if let windowStart = bindingWindowStart, windowStart.duration(to: now) < .seconds(1) {
            bindingCount += 1
        } else {
            bindingWindowStart = now
            bindingCount = 1
        }
        if bindingCount > Self.bindingFloodPerSecond {
            bindingCut = true
            let remove: [String: Any] = ["name": Self.bindingName]
            effects.posts.append(("Runtime.removeBinding", remove))
            effects.facts.append(.bindingCut)
            return
        }
        guard payload.utf8.count <= Self.maxBindingPayloadBytes else { return }
        effects.facts.append(.binding(payload: payload, executionContextId: params.int("executionContextId")))
    }

    private func download(guid: String?, url downloadURL: String, suggestedFilename: String,
                          at now: ContinuousClock.Instant, _ effects: inout Effects) {
        let seen = downloads.contains { earlier in
            if let guid, let earlierGuid = earlier.guid, guid == earlierGuid { return true }
            return earlier.url == downloadURL && earlier.at.duration(to: now) < .seconds(5)
        }
        guard !seen else { return }
        downloads.append((guid: guid, url: downloadURL, at: now))
        if downloads.count > 32 { downloads.removeFirst(downloads.count - 32) }
        effects.facts.append(.download(guid: guid, url: downloadURL, suggestedFilename: suggestedFilename))
    }

    private func crash(at now: ContinuousClock.Instant, _ effects: inout Effects) {
        guard !crashed, !detached else { return }
        crashed = true
        requests.removeAll()
        answeredRequests.removeAll()
        mainDocuments.removeAll()
        record(.crashed, at: now, &effects)
        effects.failure = .interrupted(.crashed)
        if let dismissed = ledger.dismiss(.crash) {
            effects.facts.append(.dialogDismissed(dismissed.dialog, reason: .crash))
        }
        effects.facts.append(.crashed)
    }

    private func detach(reason: String?, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        guard !detached else { return }
        detached = true
        requests.removeAll()
        answeredRequests.removeAll()
        mainDocuments.removeAll()
        record(.detached, at: now, &effects)
        effects.failure = .interrupted(.detached)
        if let dismissed = ledger.dismiss(.detach) {
            effects.facts.append(.dialogDismissed(dismissed.dialog, reason: .detach))
        }
        effects.facts.append(.detached(reason: reason))
    }

    // MARK: - Journal and waiters (under the lock)

    private func record(_ event: SettleEvent, at now: ContinuousClock.Instant, _ effects: inout Effects) {
        sequence += 1
        journal.append(Entry(sequence: sequence, at: now, event: event))
        if journal.count > Self.journalLimit {
            // A mark older than what is left replays what is left.
            journal.removeFirst(journal.count - Self.journalLimit / 2)
        }
        for id in waiters.keys.sorted() {
            guard var waiter = waiters[id] else { continue }
            waiter.machine.apply(event, at: now)
            if let outcome = conclusion(&waiter, id: id, at: now) {
                waiters.removeValue(forKey: id)
                waiter.timer?.cancel()
                effects.resumes.append((waiter.continuation, outcome))
            } else {
                waiters[id] = waiter
            }
        }
    }

    private func begin(_ id: Int, kind: SettleMachine.Kind, mark: PageMark, policy: SettlePolicy,
                       deadline: ContinuousClock.Instant,
                       continuation: CheckedContinuation<SettleOutcome, Never>) {
        let now = clock()
        lock.lock()
        var machine = SettleMachine(mark: mark, policy: policy, kind: kind, start: now)
        for entry in journal where entry.sequence > mark.sequence {
            machine.apply(entry.event, at: entry.at)
        }
        var immediate: SettleOutcome?
        if cancelledWaits.remove(id) != nil {
            immediate = machine.finalOutcome(at: now)
        } else if detached {
            immediate = .detached
        } else if ledger.open != nil {
            immediate = .modal
        } else {
            var waiter = Waiter(machine: machine, continuation: continuation, deadline: deadline,
                                timerAt: nil, timer: nil)
            if let outcome = conclusion(&waiter, id: id, at: now) {
                immediate = outcome
            } else {
                waiters[id] = waiter
            }
        }
        lock.unlock()
        if let immediate {
            continuation.resume(returning: immediate)
        }
    }

    private func cancelWait(_ id: Int) {
        let now = clock()
        lock.lock()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.timer?.cancel()
            let outcome = waiter.machine.finalOutcome(at: now)
            lock.unlock()
            waiter.continuation.resume(returning: outcome)
            return
        }
        // Cancelled before its wait began (or just after it ended): the
        // begin, if still to come, answers at once.
        cancelledWaits.insert(id)
        if cancelledWaits.count > 256, let oldest = cancelledWaits.min() {
            cancelledWaits.remove(oldest)
        }
        lock.unlock()
    }

    /// The outcome when the wait is over; nil while it goes on, with its
    /// timer set for the next instant the verdict may change.
    private func conclusion(_ waiter: inout Waiter, id: Int, at now: ContinuousClock.Instant) -> SettleOutcome? {
        switch waiter.machine.verdict(at: now) {
        case .done(let outcome):
            return outcome
        case .waitUntil(let until):
            let deadline = waiter.deadline
            if now >= deadline { return waiter.machine.finalOutcome(at: now) }
            let target = until.map { min($0, deadline) } ?? deadline
            if waiter.timerAt != target {
                waiter.timer?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.timerFired(id) }
                timerQueue.asyncAfter(deadline: Self.dispatchTime(target), execute: item)
                waiter.timer = item
                waiter.timerAt = target
            }
            return nil
        }
    }

    private func timerFired(_ id: Int) {
        let now = clock()
        lock.lock()
        guard var waiter = waiters[id] else {
            lock.unlock()
            return
        }
        waiter.timer = nil
        waiter.timerAt = nil
        if let outcome = conclusion(&waiter, id: id, at: now) {
            waiters.removeValue(forKey: id)
            lock.unlock()
            waiter.continuation.resume(returning: outcome)
            return
        }
        waiters[id] = waiter
        lock.unlock()
    }

    private func pruneRecentEnded(_ now: ContinuousClock.Instant) {
        let cutoff: ContinuousClock.Instant = now - pollWindow
        if let keep = recentEnded.firstIndex(where: { $0.at >= cutoff }) {
            if keep > 0 { recentEnded.removeFirst(keep) }
        } else {
            recentEnded.removeAll()
        }
    }

    // MARK: - Past the lock

    private func perform(_ effects: Effects) {
        for (method, params) in effects.posts {
            link.post(method, params)
        }
        if let failure = effects.failure {
            link.failAll(failure)
        }
        for reason in effects.interrupts {
            link.interrupt(reason)
        }
        if !effects.facts.isEmpty {
            lock.lock()
            let handler = factHandler
            lock.unlock()
            if let handler {
                for fact in effects.facts {
                    handler(fact)
                }
            }
        }
        for (continuation, outcome) in effects.resumes {
            continuation.resume(returning: outcome)
        }
    }

    // MARK: - Helpers

    /// A request's identity across a polling loop: method, origin and path
    /// — the query (a timestamp, a cursor) changes at every turn.
    public static func requestKey(method: String, url: String) -> String {
        var base = Substring(url)
        if let cut = base.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            base = base[..<cut]
        }
        return method.uppercased() + " " + String(base)
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: end).components
        return max(0, Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000))
    }

    /// A deadline on the dispatch clock, a millisecond late rather than
    /// early (the two clocks drift apart across sleep); capped at a day.
    static func dispatchTime(_ instant: ContinuousClock.Instant) -> DispatchTime {
        let left = ContinuousClock.now.duration(to: instant)
        guard left > .zero else { return DispatchTime.now() + .milliseconds(1) }
        let parts = left.components
        let seconds = min(parts.seconds, 86_400)
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        return DispatchTime.now() + .nanoseconds(nanoseconds) + .milliseconds(1)
    }
}
