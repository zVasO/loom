import Foundation

/// A stack's side panel: the browser shown beside its terminal, and the rules
/// for when the agent may show it on its own (pure, so they are tested).
///
/// Every open or close resizes the terminal — one repaint of claude's whole
/// conversation — so the agent reveals the panel AT MOST ONCE per stack, and
/// never again once the user closed it after that.
public struct SidePanelState: Equatable, Sendable {

    public enum Source: Hashable, Sendable {
        /// The agent's own browser (ADR-0014).
        case agent
        /// One of the stack's Web panes, the user's browsers.
        case pane(UUID)
    }

    public private(set) var isOpen = false
    public private(set) var source: Source?
    /// The agent's browser was shown — by the agent's first use, or because
    /// the user picked it. From then on the agent never opens the panel itself.
    public private(set) var agentRevealed = false
    /// The agent used its browser while the panel was closed: the view settles
    /// it with the layout it has (`resolvePendingReveal`), since only the view
    /// knows whether the terminal would keep its 80 columns.
    public private(set) var pendingReveal = false

    public init(agentRevealed: Bool = false) {
        self.agentRevealed = agentRevealed
    }

    // MARK: - The user

    /// Shows `source` — opening the panel when closed.
    public mutating func open(_ source: Source) {
        self.source = source
        isOpen = true
        pendingReveal = false
        if source == .agent { agentRevealed = true }
    }

    public mutating func close() {
        isOpen = false
        pendingReveal = false
    }

    /// What the Browser button does: closing only when the panel is open AND
    /// the agent is not busy off screen — then the click means "show me", and
    /// the caller opens the agent's browser instead.
    public func buttonCloses(agentActiveOffscreen: Bool) -> Bool {
        isOpen && !agentActiveOffscreen
    }

    /// A pane was closed: a panel that showed it has nothing left to show.
    public mutating func sourceRemoved(_ removed: Source) {
        guard source == removed else { return }
        source = nil
        isOpen = false
    }

    // MARK: - The agent

    /// The agent touched a page in its browser. The first time only:
    /// - panel open on one of the user's panes → it switches to the agent's
    ///   browser (no resize: the panel keeps its width), so the user watches;
    /// - panel closed → a reveal is pending, for the view to settle.
    /// Returns whether the state changed.
    @discardableResult
    public mutating func agentDidUseBrowser() -> Bool {
        guard !agentRevealed else { return false }
        if isOpen {
            source = .agent
            agentRevealed = true
            pendingReveal = false
            return true
        }
        guard !pendingReveal else { return false }
        pendingReveal = true
        return true
    }

    /// The view's answer to a pending reveal. Too narrow for the terminal to
    /// keep its 80 columns: nothing opens (the Browser button's dot says the
    /// agent is busy), and a later use may try again.
    public mutating func resolvePendingReveal(terminalFits: Bool) {
        guard pendingReveal else { return }
        pendingReveal = false
        guard terminalFits else { return }
        open(.agent)
    }
}
