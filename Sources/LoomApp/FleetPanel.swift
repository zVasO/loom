import LoomCore
import LoomUI
import SwiftUI

/// The fleet panel under the Sessions view: the whole fleet without leaving
/// the session you work in. Three tabs — another session's terminal, the
/// transition journal, Mission Control's table — in a bar drawn like the
/// landing page's mock window. Folded, only the bar stays; ⌘J folds and
/// unfolds it. Its height is fixed: opening or folding costs the terminal
/// above one resize, never a stream of them.
struct FleetPanel: View {
    let model: AppModel
    /// The session the main area shows — the panel's terminal starts elsewhere.
    let currentSessionID: SessionID?
    let onOpen: (SessionID) -> Void

    @AppStorage("loom.fleetPanel.open") private var isOpen = true
    @AppStorage("loom.fleetPanel.tab") private var tabRaw = Tab.missionControl.rawValue
    @State private var filter: FleetFilter = .all
    @State private var selected: SessionID?
    @FocusState private var replyFocused: Bool

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
        if fleet.isEmpty {
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
                switch tab {
                case .terminal: terminalTab
                case .transitions: TransitionJournalView(model: model)
                case .missionControl: missionControlTab
                }
                Hairline()
                FleetFooter(model: model, items: fleet, hints: hints)
            }
        }
    }

    @ViewBuilder
    private var terminalTab: some View {
        if let item = fleet.first(where: { $0.id == selected }) ?? fleet.first {
            FleetTerminalView(model: model, item: item, lines: 9, replyFocused: $replyFocused,
                              choices: fleet, onChoose: { selected = $0 })
                .id(item.id)
        }
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
        case .terminal: [(["↵"], "reply"), (["⌘", "J"], "fold")]
        case .transitions: [(["⌘", "J"], "fold")]
        case .missionControl: [(["↑", "↓"], "navigate"), (["↵"], "open"), (["R"], "reply")]
        }
    }

    // MARK: - Selection

    /// Reply from the table: the terminal tab takes the session, its field the focus.
    private func reply(to id: SessionID) {
        selected = id
        tabRaw = Tab.terminal.rawValue
        DispatchQueue.main.async { replyFocused = true }
    }

    /// The panel follows a session of its own: the one chosen, else the first
    /// that waits for you, else the first one the main area does not show.
    private func ensureSelection() {
        if let selected, fleet.contains(where: { $0.id == selected }) { return }
        selected = (fleet.first { $0.state == .needsInput }
                    ?? fleet.first { $0.id != currentSessionID }
                    ?? fleet.first)?.id
    }
}
