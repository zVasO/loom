import Foundation

/// A tab's main-frame loads, from WebKit's navigation callbacks (pure: the
/// clock is passed in). Waiting on one WKNavigation's own completion is
/// brittle — a redirect supersedes it, a same-document navigation (a hash
/// route) never finishes it, a cancelled load just stops — so the engine
/// waits for the tab to be SETTLED instead: nothing provisional, nothing
/// committed but unfinished.
public struct MainFrameLoadTracker: Sendable {

    public typealias NavigationID = ObjectIdentifier

    /// Started (provisional) and not yet committed or failed.
    private var provisional: Set<NavigationID?> = []
    /// Committed, not yet finished or failed.
    private var committed: Set<NavigationID?> = []
    /// Every navigation that ever started — "did one start since?".
    public private(set) var startedCount = 0
    /// A load the engine asked for, and when: one that never starts was a
    /// same-document navigation (or nothing at all).
    private var requestedAt: Double?
    /// The last real failure, cleared by the next request or start.
    public private(set) var lastError: String?

    /// No start within this of a request: the load was same-document.
    public static let noStartGrace: Double = 0.3

    public init() {}

    public mutating func requested(at time: Double) {
        requestedAt = time
        lastError = nil
    }

    public mutating func started(_ id: NavigationID?) {
        startedCount += 1
        requestedAt = nil
        lastError = nil
        provisional.insert(id)
    }

    public mutating func committed(_ id: NavigationID?) {
        provisional.remove(id)
        committed.insert(id)
    }

    public mutating func finished(_ id: NavigationID?) {
        provisional.remove(id)
        committed.remove(id)
    }

    /// `cancelled`: superseded by another load, or stopped on purpose — not
    /// a failure to report.
    public mutating func failed(_ id: NavigationID?, cancelled: Bool, message: String) {
        provisional.remove(id)
        committed.remove(id)
        if !cancelled { lastError = message }
    }

    /// `reloading`: false once a page keeps crashing — it stays stopped.
    public mutating func terminated(reloading: Bool = true) {
        provisional.removeAll()
        committed.removeAll()
        requestedAt = nil
        lastError = reloading ? "the page's process stopped (it is being reloaded)"
            : "the page's process keeps stopping; it was not reloaded — browser_navigate loads it again"
    }

    /// Nothing loading — and a requested load either started or never will.
    public func isSettled(at time: Double) -> Bool {
        guard provisional.isEmpty, committed.isEmpty else { return false }
        if let requestedAt { return time - requestedAt >= Self.noStartGrace }
        return true
    }

    public var isLoading: Bool { !provisional.isEmpty || !committed.isEmpty }
}
