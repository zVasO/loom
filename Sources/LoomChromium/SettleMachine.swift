import Foundation

/// The waits of `settle` (ADR-0015, design §4), with the numbers the step-0
/// probe measured. They replace WebKit's fixed 300 + 150 ms: every wait here
/// ends on an event, the caps only bound pages that never calm down.
public struct SettlePolicy: Sendable, Equatable {
    /// In-page: a rAF raced with this timeout (the helper's stability check
    /// and `afterFrame`), so a throttled or hidden page cannot stall a click.
    public var frameFallback: Duration
    /// A navigation requested (`frameRequestedNavigation`) that neither
    /// starts nor commits within this was cancelled: `preventDefault`, a
    /// blocked scheme, a download decided in the renderer.
    public var requestedNoStart: Duration
    /// How long an action waits for the load it caused, from its ack.
    public var loadCapAction: Duration
    /// How long `navigate` waits for its load, from the wait's start.
    public var loadCapNavigate: Duration
    /// Quiet after the last tracked request ended: a fetch that starts
    /// another when it ends (a chain) is still one burst.
    public var chainWindow: Duration
    /// The network-quiet wait gives up this long after the ack (actions) or
    /// the load (navigations): a long-poll costs 2 s, never the whole limit.
    public var quietCap: Duration
    /// A request whose key was in flight at the mark, or ended this long
    /// before it, is a polling loop: the action did not start it.
    public var pollWindow: Duration

    public init(frameFallback: Duration = .milliseconds(50),
                requestedNoStart: Duration = .milliseconds(500),
                loadCapAction: Duration = .seconds(10),
                loadCapNavigate: Duration = .seconds(30),
                chainWindow: Duration = .milliseconds(32),
                quietCap: Duration = .seconds(2),
                pollWindow: Duration = .seconds(2)) {
        self.frameFallback = frameFallback
        self.requestedNoStart = requestedNoStart
        self.loadCapAction = loadCapAction
        self.loadCapNavigate = loadCapNavigate
        self.chainWindow = chainWindow
        self.quietCap = quietCap
        self.pollWindow = pollWindow
    }
}

/// What `PageSignals` makes of the DevTools events of one page, in wire
/// order. Only the main frame's navigations count; requests are XHR and
/// fetch of any frame of the session.
public enum SettleEvent: Sendable, Equatable {
    /// `Page.frameRequestedNavigation{disposition:"currentTab"}`, main frame:
    /// the page asked to leave; the start may never come.
    case navRequested
    /// `frameStartedNavigating` (a different document), `frameStartedLoading`
    /// (no loader: it may still turn out same-document) or the main
    /// Document's `requestWillBeSent`.
    case navStarted(loaderId: String?)
    /// `Page.navigatedWithinDocument`: pushState, a hash. No load follows.
    case sameDocument
    /// `Page.frameNavigated` of the main frame: a new document.
    case committed(loaderId: String)
    /// `Page.lifecycleEvent` of the main frame ("load", "DOMContentLoaded").
    case lifecycle(name: String, loaderId: String)
    /// The main Document's request failed for real (not `ERR_ABORTED`).
    case docFailed(loaderId: String?, errorText: String)
    /// `frameStoppedLoading` of the main frame (no loader), or its Document
    /// aborted (a download, a 204, a superseded load: that loader).
    case navStopped(loaderId: String?)
    /// An XHR or fetch; `key` is method + origin + path (no query).
    case requestStarted(id: String, key: String)
    /// Its response arrived. That ends it for the settle: a fetch whose
    /// body the page never reads gets no `loadingFinished` (recorded
    /// traces), and a streamed body may never end.
    case requestAnswered(id: String)
    /// `loadingFinished` or `loadingFailed`; after an answer, it only
    /// restarts the chain window (the page just read the body).
    case requestEnded(id: String)
    /// A JavaScript dialog parked for an answer, or a file chooser.
    case modal
    case crashed
    case detached
    /// The in-page `setTimeout(0)` barrier answered: every request and
    /// navigation the action caused synchronously is already applied.
    case barrierDone
    /// The barrier failed because its document went away ("Cannot find
    /// context with specified id", "Execution context was destroyed."): a
    /// navigation, even when its commit is not seen yet.
    case barrierLost
}

/// How a settle ended.
public enum SettleOutcome: Sendable, Equatable {
    /// No navigation (or a same-document one) and the network went quiet,
    /// or stayed busy until the quiet cap.
    case quiet
    /// A new document loaded, then went quiet (or reached the quiet cap).
    case loaded
    /// The load cap passed before the load: the page answers as it is.
    case stillLoading
    /// The main document failed: `errorText` is Chromium's `net::ERR_*`.
    case failed(errorText: String)
    /// A dialog or a file chooser waits for an answer.
    case modal
    case crashed
    case detached

    /// The note the answer carries, in the WebKit engine's words.
    public var note: String? {
        switch self {
        case .stillLoading: return "The page was still loading when the wait ended."
        case .quiet, .loaded, .failed, .modal, .crashed, .detached: return nil
        }
    }
}

/// Where a page stood just before an action was sent.
public struct PageMark: Sendable, Equatable {
    /// The last event already applied: the settle looks at what follows.
    public var sequence: Int
    /// The document generation (main-frame commits so far).
    public var generation: Int
    /// Keys of the XHR/fetch unanswered at the mark, or answered or ended
    /// within `SettlePolicy.pollWindow` before it: polling loops, never
    /// waited for by an action.
    public var pollKeys: Set<String>
    public var at: ContinuousClock.Instant

    public init(sequence: Int, generation: Int = 0, pollKeys: Set<String> = [],
                at: ContinuousClock.Instant = ContinuousClock.now) {
        self.sequence = sequence
        self.generation = generation
        self.pollKeys = pollKeys
        self.at = at
    }
}

/// The settle as a pure state machine (design §4): events go in with their
/// time, a verdict comes out — done, or "ask again at this instant unless an
/// event comes first". No clock, no I/O: `PageSignals` drives it live on the
/// reader queue, the tests replay recorded orderings through it.
///
/// After an action: a modal or a crash ends it at once; a navigation it
/// caused is waited for until its load (or failure, stop, same-document
/// end, or the load cap); then the XHR/fetch started since the mark, less
/// the polling ones, must end and stay ended for `chainWindow`, within
/// `quietCap`. With no navigation at all, the in-page barrier must have
/// answered first: only then are the requests the action caused known.
public struct SettleMachine: Sendable {

    public enum Kind: Sendable, Equatable {
        /// A click, a key, a type: anything that may or may not navigate.
        case action
        /// `Page.navigate` (or a history entry) answered with this loader;
        /// nil: it was same-document, no load to wait for. Requests count
        /// from the commit, with no polling heuristic.
        case navigation(loaderId: String?)
    }

    public enum Verdict: Sendable, Equatable {
        case done(SettleOutcome)
        /// Nothing to conclude yet: ask again at this instant if no event
        /// came first (nil: only an event can change the verdict).
        case waitUntil(ContinuousClock.Instant?)
    }

    private enum Navigation: Sendable, Equatable {
        case idle
        case requested(at: ContinuousClock.Instant)
        case started(loaderId: String?, at: ContinuousClock.Instant)
        case committed(loaderId: String, at: ContinuousClock.Instant)
    }

    public let mark: PageMark
    public let policy: SettlePolicy
    public let kind: Kind
    /// When the wait began: the action's ack, or the navigate reply.
    public let start: ContinuousClock.Instant

    private var navigation: Navigation
    /// Any navigation signal since the mark: the barrier is then not needed.
    private var sawNavigation: Bool
    private var committedSinceMark = false
    private var barrierSeen = false
    private var terminal: SettleOutcome?
    private var loadedAt: ContinuousClock.Instant?
    private var inFlight: Set<String> = []
    /// Answered, body not finished yet.
    private var answered: Set<String> = []
    private var lastEnded: ContinuousClock.Instant?

    public init(mark: PageMark, policy: SettlePolicy = SettlePolicy(), kind: Kind,
                start: ContinuousClock.Instant) {
        self.mark = mark
        self.policy = policy
        self.kind = kind
        self.start = start
        switch kind {
        case .action:
            navigation = .idle
            sawNavigation = false
        case .navigation(let loaderId):
            if let loaderId {
                navigation = .started(loaderId: loaderId, at: start)
            } else {
                navigation = .idle
            }
            sawNavigation = true
        }
    }

    /// Applies one event that happened at `time`. Events must come in wire
    /// order; their times never go backwards.
    public mutating func apply(_ event: SettleEvent, at time: ContinuousClock.Instant) {
        expireRequest(at: time)
        switch terminal {
        case .crashed?, .detached?:
            return   // nothing comes back from those
        default:
            break
        }
        switch event {
        case .crashed:
            terminal = .crashed
        case .detached:
            terminal = .detached
        case .modal:
            if terminal == nil { terminal = .modal }
        case .barrierDone:
            barrierSeen = true
        case .barrierLost:
            barrierSeen = true
            // A commit already seen explains it; otherwise one is coming.
            guard !committedSinceMark else { break }
            switch navigation {
            case .idle, .requested:
                sawNavigation = true
                navigation = .started(loaderId: nil, at: time)
            case .started, .committed:
                break
            }
        case .navRequested:
            sawNavigation = true
            switch navigation {
            case .idle, .requested:
                navigation = .requested(at: time)
            case .started, .committed:
                break   // the start that follows tells which load to wait for
            }
        case .navStarted(let loaderId):
            sawNavigation = true
            switch navigation {
            case .idle, .requested:
                navigation = .started(loaderId: loaderId, at: time)
            case .started(let current, let since):
                // A loader learnt, or a newer navigation superseding this one.
                if let loaderId, loaderId != current {
                    navigation = .started(loaderId: loaderId, at: current == nil ? since : time)
                }
            case .committed(let current, _):
                // frameStartedLoading (no loader) during a load is the same
                // load; a new loader is a new navigation (a redirect by script).
                if let loaderId, loaderId != current {
                    navigation = .started(loaderId: loaderId, at: time)
                }
            }
        case .sameDocument:
            sawNavigation = true
            switch navigation {
            case .requested, .started(.none, _):
                navigation = .idle
            case .idle, .started, .committed:
                break   // a known new document goes on loading
            }
        case .committed(let loaderId):
            sawNavigation = true
            committedSinceMark = true
            navigation = .committed(loaderId: loaderId, at: time)
            // What the old document had in flight answers to nobody now.
            inFlight.removeAll()
            answered.removeAll()
            lastEnded = nil
        case .lifecycle(let name, let loaderId):
            guard name == "load" else { break }
            switch navigation {
            case .committed(let current, _) where current == loaderId:
                navigation = .idle
                loadedAt = time
            case .started(let current?, _) where current == loaderId:
                navigation = .idle
                loadedAt = time
            default:
                break   // an older document's load, or one we never saw start
            }
        case .docFailed(let loaderId, let errorText):
            guard terminal == nil else { break }
            switch navigation {
            case .requested:
                terminal = .failed(errorText: errorText)
            case .started(let current, _):
                if current == nil || loaderId == nil || current == loaderId {
                    terminal = .failed(errorText: errorText)
                }
            case .committed(let current, _):
                if loaderId == nil || current == loaderId {
                    terminal = .failed(errorText: errorText)
                }
            case .idle:
                break   // not a load this wait is about
            }
        case .navStopped(let loaderId):
            switch navigation {
            case .requested:
                navigation = .idle
            case .started(let current, _):
                // Stopped before any commit: cancelled, a download, a 204.
                if loaderId == nil || current == nil || current == loaderId {
                    navigation = .idle
                }
            case .committed(let current, _):
                // Stopped after the commit with no load seen (window.stop()):
                // as loaded as it will get.
                if loaderId == nil || current == loaderId {
                    navigation = .idle
                    loadedAt = time
                }
            case .idle:
                break
            }
        case .requestStarted(let id, let key):
            if kind == .action, mark.pollKeys.contains(key) { break }
            inFlight.insert(id)
        case .requestAnswered(let id):
            if inFlight.remove(id) != nil {
                answered.insert(id)
                lastEnded = time
            }
        case .requestEnded(let id):
            if inFlight.remove(id) != nil || answered.remove(id) != nil {
                lastEnded = time
            }
        }
    }

    public func verdict(at now: ContinuousClock.Instant) -> Verdict {
        if let terminal { return .done(terminal) }
        let navigationCap = start.advanced(by: kind == .action ? policy.loadCapAction : policy.loadCapNavigate)
        switch effectiveNavigation(at: now) {
        case .requested(let at):
            if now >= navigationCap { return .done(settled) }
            return .waitUntil(min(at.advanced(by: policy.requestedNoStart), navigationCap))
        case .started, .committed:
            if now >= navigationCap { return .done(.stillLoading) }
            return .waitUntil(navigationCap)
        case .idle:
            break
        }

        let quietCapAt = (loadedAt ?? start).advanced(by: policy.quietCap)
        if now >= quietCapAt { return .done(settled) }
        if kind == .action, !sawNavigation, !barrierSeen {
            return .waitUntil(quietCapAt)
        }
        if !inFlight.isEmpty {
            return .waitUntil(quietCapAt)
        }
        if let lastEnded {
            let quietAt = lastEnded.advanced(by: policy.chainWindow)
            if now < quietAt { return .waitUntil(min(quietAt, quietCapAt)) }
        }
        return .done(settled)
    }

    /// The outcome if the wait has to end now (the command's deadline, a
    /// cancelled task): a load under way is "still loading".
    public func finalOutcome(at now: ContinuousClock.Instant) -> SettleOutcome {
        if let terminal { return terminal }
        switch effectiveNavigation(at: now) {
        case .started, .committed: return .stillLoading
        case .idle, .requested: return settled
        }
    }

    /// Tracked requests not answered yet (diagnostics, tests).
    public var requestsInFlight: Int { inFlight.count }

    /// The settle run on recorded events as a live wait would run it: it
    /// starts at `start` with the events up to then applied, asks for a
    /// verdict, and moves to the instant the verdict names or to the next
    /// event, whichever is first. Past the last event, only time moves.
    /// Returns the outcome and the instant it was reached.
    public static func replay(_ events: [(at: ContinuousClock.Instant, event: SettleEvent)], mark: PageMark,
                              policy: SettlePolicy = SettlePolicy(), kind: Kind,
                              start: ContinuousClock.Instant) -> (outcome: SettleOutcome, at: ContinuousClock.Instant) {
        var machine = SettleMachine(mark: mark, policy: policy, kind: kind, start: start)
        var index = 0
        var now = start
        // Bounded: each turn applies an event or reaches a verdict's instant.
        for _ in 0..<(events.count * 4 + 64) {
            while index < events.count, events[index].at <= now {
                machine.apply(events[index].event, at: events[index].at)
                index += 1
            }
            switch machine.verdict(at: now) {
            case .done(let outcome):
                return (outcome, now)
            case .waitUntil(let until):
                let nextEvent: ContinuousClock.Instant? = index < events.count ? events[index].at : nil
                let candidates = [until, nextEvent].compactMap { $0 }
                guard let next = candidates.min() else {
                    return (machine.finalOutcome(at: now), now)
                }
                now = max(next, now)
            }
        }
        return (machine.finalOutcome(at: now), now)
    }

    private var settled: SettleOutcome {
        loadedAt == nil ? .quiet : .loaded
    }

    /// A request that never started has expired by `now`.
    private func effectiveNavigation(at now: ContinuousClock.Instant) -> Navigation {
        if case .requested(let at) = navigation, now >= at.advanced(by: policy.requestedNoStart) {
            return .idle
        }
        return navigation
    }

    private mutating func expireRequest(at time: ContinuousClock.Instant) {
        navigation = effectiveNavigation(at: time)
    }
}
