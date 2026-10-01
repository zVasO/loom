import LoomCore
import LoomUI
import LoomWeb
import Foundation

// The side panel (the browser beside a stack's terminal): its state lives
// here, keyed by the stack's parent session, so a shell of the stack shows
// the same panel and the agents API can reveal it without any view around.

extension AppModel {

    /// The width the user last dragged the panel to — one for every stack.
    static let sidePanelWidthKey = "loom.session.sidePanelWidth"
    /// The stacks whose agent already revealed its browser: kept across
    /// launches, so a relaunch never re-reveals (each reveal costs a repaint).
    static let agentRevealedKey = "loom.session.agentRevealed"

    /// nil until the user drags the divider.
    var storedSidePanelWidth: CGFloat? {
        let width = UserDefaults.standard.double(forKey: Self.sidePanelWidthKey)
        return width > 0 ? CGFloat(width) : nil
    }

    func storeSidePanelWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: Self.sidePanelWidthKey)
    }

    /// The stack a session belongs to: a shell answers its parent.
    func stackParentID(of id: SessionID) -> SessionID {
        sessions.first { $0.id == id }?.parentID ?? id
    }

    func sidePanel(for parent: SessionID) -> SidePanelState {
        sidePanels[parent] ?? SidePanelState()
    }

    /// The stack's Web panes, in opening order.
    func panes(of parent: SessionID) -> [BrowserPane] {
        browserPanes.filter { $0.parentID == parent }
    }

    /// The Browser button and ⌘⇧B.
    func toggleSidePanel(for parent: SessionID) {
        var state = sidePanel(for: parent)
        let agentOffscreen = isAgentBrowserActiveOffscreen(parent)
        if state.buttonCloses(agentActiveOffscreen: agentOffscreen) {
            state.close()
        } else {
            state.open(agentOffscreen ? .agent : defaultSidePanelSource(for: parent))
        }
        updateSidePanel(state, for: parent)
    }

    func showInSidePanel(_ source: SidePanelState.Source, for parent: SessionID) {
        var state = sidePanel(for: parent)
        state.open(source)
        updateSidePanel(state, for: parent)
    }

    func closeSidePanel(for parent: SessionID) {
        var state = sidePanel(for: parent)
        state.close()
        updateSidePanel(state, for: parent)
    }

    /// A fresh Web pane, shown in the panel at once.
    func newPaneInSidePanel(for parent: SessionID) {
        showInSidePanel(.pane(openBrowserPane(for: parent)), for: parent)
    }

    /// The view settles a reveal the agent asked for, with the layout it has.
    func resolvePendingReveal(for parent: SessionID, terminalFits: Bool) {
        var state = sidePanel(for: parent)
        guard state.pendingReveal else { return }
        state.resolvePendingReveal(terminalFits: terminalFits)
        updateSidePanel(state, for: parent)
    }

    /// What the panel opens on: what it showed last if that still exists, the
    /// agent's browser when the stack has one, the stack's first pane — or a
    /// new one, so the button never opens onto nothing.
    private func defaultSidePanelSource(for parent: SessionID) -> SidePanelState.Source {
        if let last = sidePanels[parent]?.source, sidePanelSourceExists(last, parent: parent) {
            return last
        }
        if hasAgentBrowser(parent) { return .agent }
        if let first = panes(of: parent).first { return .pane(first.id) }
        return .pane(openBrowserPane(for: parent))
    }

    private func sidePanelSourceExists(_ source: SidePanelState.Source, parent: SessionID) -> Bool {
        switch source {
        case .agent: return hasAgentBrowser(parent)
        case .pane(let id): return browserPane(id) != nil
        }
    }

    func updateSidePanel(_ state: SidePanelState, for parent: SessionID) {
        let before = sidePanels[parent]
        guard before != state else { return }
        sidePanels[parent] = state
        if before?.agentRevealed != state.agentRevealed { saveAgentRevealed() }
    }

    /// A closed pane leaves no panel pointing at it.
    func sidePanelPaneRemoved(_ id: UUID) {
        for parent in Array(sidePanels.keys) {
            sidePanels[parent]?.sourceRemoved(.pane(id))
        }
    }

    /// An archived stack forgets its panel.
    func forgetSidePanel(_ parent: SessionID) {
        guard sidePanels.removeValue(forKey: parent) != nil else { return }
        saveAgentRevealed()
    }

    // MARK: - Persistence (only what must survive: the panel starts closed)

    private func saveAgentRevealed() {
        let ids = sidePanels.filter { $0.value.agentRevealed }.keys.map(\.rawValue.uuidString).sorted()
        UserDefaults.standard.set(ids, forKey: Self.agentRevealedKey)
    }

    func restoreSidePanels() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.agentRevealedKey) ?? []
        // A stack that no longer exists is dropped — judged only when the
        // store answered: an empty list is a failed read, not "no sessions".
        let known = Set(allRecords.map(\.id)).union(sessions.map(\.id))
        for raw in ids {
            guard let uuid = UUID(uuidString: raw) else { continue }
            let id = SessionID(uuid)
            guard known.isEmpty || known.contains(id) else { continue }
            sidePanels[id] = SidePanelState(agentRevealed: true)
        }
        saveAgentRevealed()
    }

    // MARK: - The agent's browser (ADR-0014) — none before it exists

    func hasAgentBrowser(_ parent: SessionID) -> Bool { false }

    /// The agent is driving its browser and the panel does not show it.
    func isAgentBrowserActiveOffscreen(_ parent: SessionID) -> Bool { false }
}
