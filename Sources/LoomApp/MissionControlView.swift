import LoomCore
import LoomUI
import SwiftUI

/// Mission Control (⌘G): the whole fleet as the landing page's mock draws it —
/// one window with its head (title, location, filter), the session table, the
/// selected session's main terminal and a status footer. Spot the session
/// that waits for you, answer it, move on.
struct MissionControlView: View {
    let model: AppModel
    let onOpen: (SessionID) -> Void

    @State private var filter: FleetFilter = .all
    @State private var selected: SessionID?
    @FocusState private var replyFocused: Bool

    private var fleet: [AppModel.SessionItem] {
        model.sessions.filter { !$0.isShell }
    }

    private var visible: [AppModel.SessionItem] {
        fleet.filter { filter.matches($0) }
    }

    var body: some View {
        Group {
            if fleet.isEmpty {
                emptyState
            } else {
                window.padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.background)
        .onAppear(perform: ensureSelection)
        .onChange(of: fleet.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: filter) { _, _ in ensureSelection() }
    }

    private var window: some View {
        VStack(spacing: 0) {
            FleetHead(model: model, filter: $filter, counts: FleetFilter.counts(fleet))
            Hairline()
            FleetTable(model: model, items: visible, selected: $selected,
                       onOpen: onOpen, onReply: reply(to:))
                .frame(maxHeight: .infinity)
            if let item = fleet.first(where: { $0.id == selected }) {
                Hairline()
                FleetTerminalView(model: model, item: item, lines: 8, replyFocused: $replyFocused)
                    .frame(height: item.state == .needsInput ? 252 : 214)
                    .id(item.id)
            }
            Hairline()
            FleetFooter(model: model, items: fleet,
                        hints: [(["↑", "↓"], "navigate"), (["↵"], "open"), (["R"], "reply")])
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DefaultTheme.line2, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LucideIcon(.layoutGrid, size: 34)
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("No live session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            HStack(spacing: 4) {
                KeyCap("⌘")
                KeyCap("N")
                Text("starts one in the current project.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func reply(to id: SessionID) {
        selected = id
        // The reply field mounts with the terminal of the new selection.
        DispatchQueue.main.async { replyFocused = true }
    }

    /// Keeps a visible row selected: the one already chosen, else the first
    /// session that waits for you, else the first row.
    private func ensureSelection() {
        if let selected, visible.contains(where: { $0.id == selected }) { return }
        selected = (visible.first { $0.state == .needsInput } ?? visible.first)?.id
    }
}
