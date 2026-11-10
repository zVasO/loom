import LoomCore
import LoomUI
import SwiftUI

/// Mission Control (⌘G): the whole fleet in one window — its head (title,
/// location, filter), the session table, and under it the selected session's
/// MAIN TERMINAL: the real one, fitted to its pane, where the conversation
/// reads as it does in the Sessions tab and where you type your answer.
/// Spot the session that waits for you, answer it, move on.
///
/// The table keeps the keyboard (↑ ↓, ↵, R) until you click the terminal or
/// press R: the terminal never takes it by itself. Its height depends on the
/// window alone, so the terminal under it is resized by a window resize and
/// by nothing else — a filter that hides rows costs no repaint.
struct MissionControlView: View {
    let model: AppModel
    let onOpen: (SessionID) -> Void

    @State private var filter: FleetFilter = .all
    @State private var selected: SessionID?
    /// The session whose terminal shows: the selection once it rests. Walking
    /// the table with ↑ ↓ must not fit — resize — every session on the way.
    @State private var shown: SessionID?
    /// Bumped to hand the terminal the keyboard (Reply, R).
    @State private var terminalFocus = 0
    @State private var terminalHasKeyboard = false

    private var fleet: [AppModel.SessionItem] {
        model.sessions.filter { !$0.isShell }
    }

    private var visible: [AppModel.SessionItem] {
        fleet.filter { filter.matches($0) }
    }

    private var shownItem: AppModel.SessionItem? {
        fleet.first { $0.id == shown }
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
        .task(id: selected) {
            guard selected != shown else { return }
            // The first terminal shows at once; afterwards the selection
            // rests a moment before its terminal replaces the one on screen.
            if shown != nil { try? await Task.sleep(for: .milliseconds(160)) }
            guard !Task.isCancelled else { return }
            shown = selected
        }
    }

    private var window: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                FleetHead(model: model, filter: $filter, counts: FleetFilter.counts(fleet))
                Hairline()
                FleetTable(model: model, items: visible, selected: $selected,
                           onOpen: onOpen, onReply: reply(to:))
                    .frame(height: Self.tableHeight(windowHeight: proxy.size.height))
                Hairline()
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline()
                FleetFooter(model: model, items: fleet,
                            hints: [(["↑", "↓"], "navigate"), (["↵"], "open"), (["R"], "type in the terminal")])
            }
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DefaultTheme.line2, lineWidth: 1))
    }

    /// The table's share of the window: about three tenths of its height in
    /// whole rows, three at least, eight at most — the rest is the terminal's.
    static func tableHeight(windowHeight: CGFloat) -> CGFloat {
        let rows = Int((windowHeight * 0.3 - FleetTable.headerHeight) / FleetTable.rowHeight)
        return FleetTable.headerHeight + CGFloat(min(8, max(3, rows))) * FleetTable.rowHeight
    }

    // MARK: - Terminal

    @ViewBuilder
    private var terminal: some View {
        if let item = shownItem {
            VStack(spacing: 0) {
                terminalHead(item)
                Hairline()
                if item.isDormant {
                    dormantNotice(item)
                } else {
                    // One pane for every session shown: it follows the
                    // session it is given, and keeps its key capture — the
                    // keyboard handed over by Reply stays where it was put.
                    TerminalPane(model: model, sessionID: item.id, role: .missionControl,
                                 focusRequest: terminalFocus,
                                 onFocusChange: { terminalHasKeyboard = $0 })
                }
            }
            .background(DefaultTheme.contentBackground)
        } else {
            Text(visible.isEmpty ? "No session matches this filter." : "Select a session: its terminal shows here.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DefaultTheme.contentBackground)
        }
    }

    private func terminalHead(_ item: AppModel.SessionItem) -> some View {
        HStack(spacing: 10) {
            LucideIcon(.terminal, size: 14).foregroundStyle(DefaultTheme.secondaryText)
            MonoLabel("Main terminal")
            MonoLabel(item.title, color: DefaultTheme.mutedText)
            StatusTag(FleetState.label(item), color: FleetState.color(item))
            Spacer(minLength: 12)
            if !item.isDormant {
                if terminalHasKeyboard {
                    StatusTag("Typing here", color: DefaultTheme.accent)
                } else {
                    HStack(spacing: 5) {
                        KeyCap("R")
                        MonoLabel("or click to type", color: DefaultTheme.mutedText)
                    }
                }
            }
            if let branch = item.branch {
                Text(branch)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            FleetButton("Open", prominent: false) { onOpen(item.id) }
                .help("Open this session in the Sessions tab (↵)")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(DefaultTheme.background)
    }

    private func dormantNotice(_ item: AppModel.SessionItem) -> some View {
        VStack(spacing: 10) {
            Text("Session inactive — Resume reopens its conversation.")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
            FleetButton("Resume", prominent: true) {
                Task { await model.resumeDormant(item.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Selection

    /// Reply, from a row's button or R: that session's terminal shows at
    /// once and takes the keyboard — what you type next goes to its agent.
    private func reply(to id: SessionID) {
        selected = id
        shown = id
        terminalFocus += 1
        // A pane that mounts for this very reply (nothing shown before, or an
        // inactive session) is born after the request: ask again once it is there.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard shown == id else { return }
            terminalFocus += 1
        }
    }

    /// Keeps a visible row selected: the one already chosen, else the first
    /// session that waits for you, else the first row.
    private func ensureSelection() {
        if let selected, visible.contains(where: { $0.id == selected }) { return }
        selected = (visible.first { $0.state == .needsInput } ?? visible.first)?.id
    }
}
