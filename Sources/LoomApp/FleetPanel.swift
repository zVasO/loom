import LoomCore
import LoomUI
import SwiftUI

/// The panel under the Sessions view, like an editor's integrated terminal:
/// a shell in the worktree of the session open above, the transition journal
/// and Mission Control's table, in a bar drawn like the landing page's mock
/// window. Folded, only the bar stays; ⌘J folds and unfolds it. Its height is
/// fixed: opening or folding costs the terminal above one resize, never a
/// stream of them.
struct FleetPanel: View {
    let model: AppModel
    /// The session the main area shows: the panel's shell lives in its stack.
    let currentSessionID: SessionID?
    let onOpen: (SessionID) -> Void

    @AppStorage("loom.fleetPanel.open") private var isOpen = true
    @AppStorage("loom.fleetPanel.tab") private var tabRaw = Tab.missionControl.rawValue
    @State private var filter: FleetFilter = .all
    @State private var selected: SessionID?
    /// The shell shown, per stack — the person's last pick among its terminals.
    @State private var shellByStack: [SessionID: SessionID] = [:]
    /// Stacks the panel already opened a shell for: if that shell is closed,
    /// the panel offers a new one instead of launching it behind your back.
    @State private var provisioned: Set<SessionID> = []

    static let height: CGFloat = 300

    enum Tab: String, CaseIterable {
        case terminal, transitions, missionControl

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .transitions: "Transitions"
            case .missionControl: "Mission control"
            }
        }

        var icon: LucideIcon.Glyph {
            switch self {
            case .terminal: .terminal
            case .transitions: .activity
            case .missionControl: .layoutGrid
            }
        }
    }

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .missionControl }

    private var fleet: [AppModel.SessionItem] {
        model.sessions.filter { !$0.isShell }
    }

    private var visible: [AppModel.SessionItem] {
        fleet.filter { filter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            bar
            if isOpen {
                Hairline()
                content
                    .frame(height: Self.height)
            }
        }
        .background(DefaultTheme.surface)
        .onAppear(perform: ensureSelection)
        .onChange(of: fleet.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: filter) { _, _ in ensureSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .loomToggleFleetPanel)) { _ in
            isOpen.toggle()
        }
    }

    // MARK: - Bar

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { candidate in
                NavTab(candidate.title, icon: candidate.icon, isActive: isOpen && tab == candidate) {
                    if isOpen && tab == candidate {
                        isOpen = false
                    } else {
                        tabRaw = candidate.rawValue
                        isOpen = true
                    }
                }
            }
            if !isOpen, let waiting = FleetFilter.counts(fleet)[.needsInput], waiting > 0 {
                StatusTag("\(waiting) needs input", color: DefaultTheme.badgeColor(for: .needsInput))
                    .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            StatusTag(model.hooksOnline ? "Hooks online" : "Hooks offline",
                      color: model.hooksOnline ? DefaultTheme.badgeColor(for: .working) : DefaultTheme.danger)
            HoverIconButton(systemImage: isOpen ? "chevron.down" : "chevron.up",
                            help: isOpen ? "Fold the fleet panel (⌘J)" : "Unfold the fleet panel (⌘J)") {
                isOpen.toggle()
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(DefaultTheme.background)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if tab == .terminal {
            VStack(spacing: 0) {
                terminalTab
                Hairline()
                FleetFooter(model: model, items: fleet, hints: hints)
            }
        } else if fleet.isEmpty {
            VStack(spacing: 6) {
                Text("No live session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                HStack(spacing: 4) {
                    KeyCap("⌘")
                    KeyCap("N")
                    Text("starts one.").font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if tab == .transitions {
                    TransitionJournalView(model: model)
                } else {
                    missionControlTab
                }
                Hairline()
                FleetFooter(model: model, items: fleet, hints: hints)
            }
        }
    }

    // MARK: - Terminal (the stack's shell)

    /// The stack of the session open above.
    private var stackParent: AppModel.SessionItem? {
        guard let currentSessionID else { return nil }
        let parentID = model.stackParentID(of: currentSessionID)
        return model.sessions.first { $0.id == parentID }
    }

    /// The stack's live shells, in their tab order.
    private var shells: [AppModel.SessionItem] {
        guard let parent = stackParent else { return [] }
        return model.sessions.filter { $0.parentID == parent.id && $0.isShell }
    }

    /// The shell the panel shows: the one picked, else the first that is not
    /// already open above (one terminal never sits in two panes).
    private var shownShell: AppModel.SessionItem? {
        guard let parent = stackParent else { return nil }
        let candidates = shells.filter { $0.id != currentSessionID }
        if let picked = shellByStack[parent.id], let shell = candidates.first(where: { $0.id == picked }) {
            return shell
        }
        return candidates.first
    }

    @ViewBuilder
    private var terminalTab: some View {
        VStack(spacing: 0) {
            terminalHead
            Hairline()
            if let shell = shownShell {
                TerminalPane(model: model, sessionID: shell.id, role: .panel)
                    .id(shell.id)
            } else {
                terminalPlaceholder
            }
        }
        .background(DefaultTheme.contentBackground)
        .task(id: provisionKey) { await provisionShell() }
    }

    private var terminalHead: some View {
        HStack(spacing: 10) {
            LucideIcon(.terminal, size: 14).foregroundStyle(DefaultTheme.secondaryText)
            MonoLabel("Terminal")
            if let parent = stackParent {
                MonoLabel(parent.title, color: DefaultTheme.mutedText)
            }
            HStack(spacing: 2) {
                ForEach(shells.filter { $0.id != currentSessionID }) { shell in
                    NavTab(shell.title, isActive: shell.id == shownShell?.id) {
                        if let parent = stackParent { shellByStack[parent.id] = shell.id }
                    }
                }
                if stackParent != nil {
                    HoverIconButton(systemImage: "plus", help: "New terminal in this worktree") {
                        Task { await openShell() }
                    }
                    .padding(.leading, 4)
                }
            }
            Spacer(minLength: 12)
            if let branch = stackParent?.branch {
                Text(branch)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(DefaultTheme.background)
    }

    @ViewBuilder
    private var terminalPlaceholder: some View {
        VStack(spacing: 10) {
            if stackParent == nil {
                Text("Open a session: its terminal shows here, in its worktree.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            } else if shells.contains(where: { $0.id == currentSessionID }) && shells.count == 1 {
                Text("This stack's terminal is open above.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
                FleetButton("New terminal", prominent: false) { Task { await openShell() } }
            } else {
                Text("No terminal in this worktree.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
                FleetButton("Open a terminal", prominent: true) { Task { await openShell() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What decides whether a shell must be opened: the stack, and whether
    /// the panel shows its terminal at all.
    private var provisionKey: String {
        "\(stackParent?.id.rawValue.uuidString ?? "-")|\(isOpen && tab == .terminal)"
    }

    /// The first time the panel shows a stack's terminal and the stack has
    /// none, it reopens the one remembered from the last launch, or opens one.
    private func provisionShell() async {
        guard isOpen, tab == .terminal, let parent = stackParent,
              !provisioned.contains(parent.id), shownShell == nil,
              !shells.contains(where: { $0.id == currentSessionID }) else { return }
        provisioned.insert(parent.id)
        await openShell()
    }

    private func openShell() async {
        guard let parent = stackParent else { return }
        provisioned.insert(parent.id)
        let grid = model.preferredGrid(for: .panel)
        let id: SessionID?
        if let dormant = model.dormantShells.first(where: { $0.parentID == parent.id }) {
            id = await model.reopenDormantShell(dormant, grid: grid)
        } else {
            id = await model.launchShell(for: parent, grid: grid)
        }
        if let id { shellByStack[parent.id] = id }
    }

    private var missionControlTab: some View {
        VStack(spacing: 0) {
            FleetHead(model: model, filter: $filter, counts: FleetFilter.counts(fleet))
            Hairline()
            FleetTable(model: model, items: visible, selected: $selected,
                       onOpen: onOpen, onReply: reply(to:), autofocus: false)
        }
    }

    private var hints: [(keys: [String], label: String)] {
        switch tab {
        case .terminal: [(["⌘", "J"], "fold")]
        case .transitions: [(["⌘", "J"], "fold")]
        case .missionControl: [(["↑", "↓"], "navigate"), (["↵"], "open"), (["R"], "reply")]
        }
    }

    // MARK: - Selection

    /// Reply from the table: the session opens above, where its agent waits.
    private func reply(to id: SessionID) {
        onOpen(id)
    }

    /// The table keeps a row selected: the one chosen, else the first session
    /// that waits for you, else the first one.
    private func ensureSelection() {
        if let selected, fleet.contains(where: { $0.id == selected }) { return }
        selected = (fleet.first { $0.state == .needsInput } ?? fleet.first)?.id
    }
}
