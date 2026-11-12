import LoomAgents
import LoomCore
import LoomPersistence
import LoomTerminal
import LoomUI
import SwiftUI

// The fleet's pieces — table, journal, footer — shared by Mission Control (⌘G)
// and the fleet panel under the Sessions view. Their measures are the landing
// page's mock (site/index.html: .app-head, .grid-table, .app-foot, .log):
// 38 pt rows, 10/14 pt insets, hairlines at 8 % of the text colour, mono
// capitals for every figure. A session's terminal is never one of these
// pieces: wherever it shows it is the real pane (TerminalPane).

// MARK: - Small pieces

/// A 1 pt rule at the theme's hairline opacity.
@MainActor
struct Hairline: View {
    var body: some View {
        Rectangle().fill(DefaultTheme.line).frame(height: 1)
    }
}

/// Mono capitals for counters, column titles and metadata.
@MainActor
struct MonoLabel: View {
    let text: String
    let size: CGFloat
    let color: Color?

    init(_ text: String, size: CGFloat = 11, color: Color? = nil) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .themeFont(size: size, weight: .medium, design: .monospaced, tracking: size * 0.05)
            .monospacedDigit()
            .foregroundStyle(color ?? DefaultTheme.secondaryText)
            .lineLimit(1)
    }
}

/// Keys and what they do, for the footer.
@MainActor
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: DefaultTheme.space(4)) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            MonoLabel(label, color: DefaultTheme.mutedText).padding(.leading, DefaultTheme.space(2))
        }
    }
}

/// The state as the fleet writes it: its raw name, in its colour.
@MainActor
enum FleetState {
    static func label(_ item: AppModel.SessionItem) -> String {
        item.state.rawValue
    }

    static func color(_ state: SessionState) -> Color {
        switch state {
        case .interrupted: DefaultTheme.accent
        case .completed, .archived, .draft: DefaultTheme.secondaryText
        default: DefaultTheme.badgeColor(for: state)
        }
    }

    static func color(_ item: AppModel.SessionItem) -> Color {
        color(item.state)
    }

    /// The process runs, so the clock runs.
    static func isLive(_ item: AppModel.SessionItem) -> Bool {
        !item.isDormant && [.starting, .working, .needsInput, .idle].contains(item.state)
    }
}

/// The context ring of a row: 14 pt, a 3 pt band over the hairline track.
@MainActor
struct FleetRing: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(DefaultTheme.line2, lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color, lineWidth: 3)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .frame(width: 14, height: 14)
    }
}

/// hh:mm:ss since `start`, ticking once a second while `live` — only this
/// text redraws.
@MainActor
struct FleetDuration: View {
    let start: Date
    let end: Date?
    let live: Bool

    var body: some View {
        if live {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(start)))
            }
        } else {
            Text(Self.format((end ?? Date()).timeIntervalSince(start)))
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

/// The compact button of a row: accent-filled for what waits on you,
/// outlined otherwise.
@MainActor
struct FleetButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, prominent: Bool, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .themeFont(size: 11.5, weight: .medium)
                .foregroundStyle(prominent ? DefaultTheme.accentText : DefaultTheme.primaryText)
                .padding(.horizontal, DefaultTheme.space(8))
                .frame(height: DefaultTheme.space(24))
                .background(prominent ? DefaultTheme.accent : DefaultTheme.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                    .strokeBorder(prominent ? Color.clear : (hovered ? DefaultTheme.line3 : DefaultTheme.line2), lineWidth: 1))
                .brightness(prominent && hovered ? 0.06 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

// MARK: - Filter

enum FleetFilter: CaseIterable, Hashable {
    case all, working, needsInput, idle

    var title: String {
        switch self {
        case .all: "All"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .idle: "Idle"
        }
    }

    func matches(_ item: AppModel.SessionItem) -> Bool {
        switch self {
        case .all: true
        case .working: item.state == .working
        case .needsInput: item.state == .needsInput
        case .idle: item.state == .idle
        }
    }

    static func counts(_ items: [AppModel.SessionItem]) -> [FleetFilter: Int] {
        Dictionary(uniqueKeysWithValues: allCases.map { filter in
            (filter, items.filter { filter.matches($0) }.count)
        })
    }
}

/// The segmented filter: 2 pt inset well, 22 pt segments.
@MainActor
struct FleetFilterBar: View {
    @Binding var selection: FleetFilter
    let counts: [FleetFilter: Int]

    var body: some View {
        HStack(spacing: DefaultTheme.space(2)) {
            ForEach(FleetFilter.allCases, id: \.self) { filter in
                Segment(title: filter.title, count: counts[filter] ?? 0, isOn: selection == filter) {
                    selection = filter
                }
            }
        }
        .padding(DefaultTheme.space(2))
        .background(DefaultTheme.background, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).strokeBorder(DefaultTheme.line, lineWidth: 1))
        .fixedSize()
    }

    private struct Segment: View {
        let title: String
        let count: Int
        let isOn: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: DefaultTheme.space(6)) {
                    Text(title.uppercased())
                        .foregroundStyle(isOn || hovered ? DefaultTheme.primaryText : DefaultTheme.mutedText)
                    Text("\(count)").foregroundStyle(DefaultTheme.secondaryText)
                }
                .themeFont(size: 11, weight: .medium, design: .monospaced, tracking: 0.55)
                .monospacedDigit()
                .padding(.horizontal, DefaultTheme.space(8))
                .frame(height: DefaultTheme.space(22))
                .background(isOn ? DefaultTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(4))
                    .strokeBorder(isOn ? DefaultTheme.line2 : .clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(.hover, value: hovered)
            .animation(.hover, value: isOn)
        }
    }
}

// MARK: - Head

/// Title, location and filter — the mock's `.app-head`.
@MainActor
struct FleetHead: View {
    let model: AppModel
    @Binding var filter: FleetFilter
    let counts: [FleetFilter: Int]

    private var location: String? {
        guard let path = model.project(model.selectedProject)?.path else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: DefaultTheme.space(12)) {
            Text("Mission control")
                .themeFont(size: 13, weight: .medium, tracking: -0.13)
                .foregroundStyle(DefaultTheme.primaryText)
            if let location { MonoLabel(location, color: DefaultTheme.mutedText) }
            Spacer(minLength: 12)
            FleetFilterBar(selection: $filter, counts: counts)
        }
        .padding(.horizontal, DefaultTheme.space(14))
        .padding(.vertical, DefaultTheme.space(12))
    }
}

// MARK: - Table

/// One set of widths for the header and every row. Each cell carries the
/// mock's 10 pt side padding itself.
private enum FleetColumns {
    static let state: CGFloat = 124
    static let branch: CGFloat = 186
    static let context: CGFloat = 92
    static let duration: CGFloat = 96
    static let action: CGFloat = 104
    static let pad: CGFloat = 10
}

/// The session table: column header, rows, keyboard (↑ ↓ or j k move, ↵
/// opens, r replies).
@MainActor
struct FleetTable: View {
    let model: AppModel
    let items: [AppModel.SessionItem]
    @Binding var selected: SessionID?
    let onOpen: (SessionID) -> Void
    let onReply: (SessionID) -> Void
    /// Take the keyboard on appearing — Mission Control yes, the panel no:
    /// the terminal above keeps it.
    var autofocus = true
    @FocusState private var focused: Bool

    /// The measures a host sizes the table with (Mission Control gives it a
    /// whole number of rows) — in the theme's spacing, like every length.
    static var rowHeight: CGFloat { DefaultTheme.space(38) }
    static var headerHeight: CGFloat { DefaultTheme.space(30) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            FleetRow(model: model, item: item,
                                     isSelected: item.id == selected,
                                     isLast: index == items.count - 1,
                                     onSelect: { selected = item.id; focused = true },
                                     onOpen: { onOpen(item.id) },
                                     onReply: { onReply(item.id) })
                                .id(item.id)
                        }
                        if items.isEmpty {
                            Text("No session matches this filter.")
                                .themeFont(size: 12)
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DefaultTheme.space(24))
                        }
                    } header: {
                        header
                    }
                }
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.hover) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkr")) { press in
            switch press.characters {
            case "j": move(1)
            case "k": move(-1)
            default:
                // R: type to the session — any live one, not only one that asked.
                guard let selected, let item = items.first(where: { $0.id == selected }),
                      !item.isDormant
                else { return .ignored }
                onReply(selected)
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard let selected else { return .ignored }
            onOpen(selected)
            return .handled
        }
        .onAppear { if autofocus { focused = true } }
    }

    private var header: some View {
        HStack(spacing: 0) {
            title("State").frame(width: FleetColumns.state, alignment: .leading)
            title("Session").frame(maxWidth: .infinity, alignment: .leading)
            title("Branch").frame(width: FleetColumns.branch, alignment: .leading)
            title("Context").frame(width: FleetColumns.context, alignment: .leading)
            title("Duration").frame(width: FleetColumns.duration, alignment: .leading)
            Color.clear.frame(width: FleetColumns.action, height: 1)
        }
        .frame(height: Self.headerHeight)
        .background(DefaultTheme.surface)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func title(_ text: String) -> some View {
        MonoLabel(text, size: 10.5, color: DefaultTheme.mutedText)
            .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : items.count)
        selected = items[min(items.count - 1, max(0, index + delta))].id
    }
}

/// One session of the fleet. Its record (agent, creation date) and context
/// usage are read off the main actor once per native conversation.
@MainActor
private struct FleetRow: View {
    let model: AppModel
    let item: AppModel.SessionItem
    let isSelected: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReply: () -> Void

    @State private var hovered = false
    @State private var record: SessionRecord?
    @State private var loadedUsage: SessionUsageSummary?

    /// Measured against the window claude reported, when it did.
    private var usage: SessionUsageSummary? {
        loadedUsage?.reportingWindow(model.reportedWindows[item.id])
    }

    private var agent: String? {
        record.map { $0.agentID.hasPrefix("claude") ? "claude" : $0.agentID }
    }

    var body: some View {
        HStack(spacing: 0) {
            stateCell.frame(width: FleetColumns.state, alignment: .leading)
            titleCell.frame(maxWidth: .infinity, alignment: .leading)
            branchCell.frame(width: FleetColumns.branch, alignment: .leading)
            contextCell.frame(width: FleetColumns.context, alignment: .leading)
            durationCell.frame(width: FleetColumns.duration, alignment: .leading)
            actionCell.frame(width: FleetColumns.action, alignment: .trailing)
        }
        .frame(height: FleetTable.rowHeight)
        .background(isSelected ? DefaultTheme.wash2 : (hovered ? DefaultTheme.wash : .clear))
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(DefaultTheme.accent).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { if !isLast { Hairline() } }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Open Session", action: onOpen)
            Divider()
            BadgeMenu(model: model, sessionID: item.id, current: item.badges)
        }
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .animation(.hover, value: isSelected)
        .task(id: item.nativeID) {
            // P1 perf: the native .jsonl can be MBs — read only its tail, off
            // the main actor (the context figure lives in the LAST entry).
            let id = item.nativeID
            loadedUsage = await Task.detached(priority: .utility) {
                ClaudeNativeSessions.usage(for: id, tailBytes: 65_536)
            }.value
        }
        .task(id: item.id) {
            record = await model.sessionInfoSnapshot(item.id).record
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(FleetState.label(item))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var stateCell: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            Circle().fill(FleetState.color(item)).frame(width: 6, height: 6)
            Text(FleetState.label(item))
                .themeFont(size: 11, design: .monospaced, tracking: 0.22)
                .foregroundStyle(FleetState.color(item))
                .lineLimit(1)
        }
        .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    private var titleCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DefaultTheme.space(6)) {
                Text(item.title)
                    .themeFont(size: 13, weight: .medium)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                BadgeRow(model: model, badges: item.badges)
            }
            if let agent {
                Text(agent.uppercased())
                    .themeFont(size: 10.5, design: .monospaced, tracking: 0.52)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    private var branchCell: some View {
        Text(item.branch ?? "—")
            .themeFont(size: 11.5, design: .monospaced)
            .foregroundStyle(item.branch == nil ? DefaultTheme.mutedText : DefaultTheme.branch)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    private var contextCell: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            FleetRing(fraction: usage?.fraction,
                      color: usage.map { $0.level == .normal ? DefaultTheme.secondaryText : $0.level.color }
                          ?? DefaultTheme.secondaryText)
            Text(usage.map { "\(Int(($0.fraction * 100).rounded()))%" } ?? "—")
                .themeFont(size: 11, design: .monospaced)
                .monospacedDigit()
                .foregroundStyle(DefaultTheme.secondaryText)
        }
        .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    private var durationCell: some View {
        Group {
            if let record {
                FleetDuration(start: record.createdAt, end: record.endedAt, live: FleetState.isLive(item))
            } else {
                Text("—")
            }
        }
        .themeFont(size: 11.5, design: .monospaced)
        .monospacedDigit()
        .foregroundStyle(DefaultTheme.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }

    @ViewBuilder
    private var actionCell: some View {
        Group {
            if item.state == .needsInput && !item.isDormant {
                FleetButton("Reply", prominent: true, action: onReply)
            } else if item.isDormant {
                FleetButton("Resume", prominent: false) {
                    Task { await model.resumeDormant(item.id) }
                }
            }
        }
        .padding(.horizontal, DefaultTheme.space(FleetColumns.pad))
    }
}

// MARK: - Footer

/// Socket, counts and the keys of the view — the mock's `.app-foot`.
@MainActor
struct FleetFooter: View {
    let model: AppModel
    let items: [AppModel.SessionItem]
    let hints: [(keys: [String], label: String)]

    var body: some View {
        let counts = FleetFilter.counts(items)
        HStack(spacing: DefaultTheme.space(14)) {
            HStack(spacing: DefaultTheme.space(6)) {
                Circle()
                    .fill(model.hooksOnline ? DefaultTheme.badgeColor(for: .working) : DefaultTheme.danger)
                    .frame(width: 6, height: 6)
                MonoLabel(model.hooksOnline ? "Socket 0600" : "Hooks offline", color: DefaultTheme.mutedText)
            }
            MonoLabel("\(items.count) sessions · \(counts[.working] ?? 0) working · \(counts[.needsInput] ?? 0) needs_input",
                      color: DefaultTheme.mutedText)
            Spacer(minLength: 12)
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                KeyHint(keys: hint.keys, label: hint.label)
            }
        }
        .padding(.horizontal, DefaultTheme.space(14))
        .padding(.vertical, DefaultTheme.space(8))
        .background(DefaultTheme.surface)
    }
}

// MARK: - Transition journal

/// Every session's state changes, newest at the bottom, live — the mock's
/// "Journal des transitions".
@MainActor
struct TransitionJournalView: View {
    let model: AppModel
    var showsHeader = true

    @State private var rows: [TransitionRecord] = []

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: DefaultTheme.space(8)) {
                    MonoLabel("Transition journal", color: DefaultTheme.mutedText)
                    Spacer()
                    StatusTag("Live", color: DefaultTheme.badgeColor(for: .working))
                }
                .padding(.horizontal, DefaultTheme.space(10))
                .padding(.vertical, DefaultTheme.space(7))
                Hairline()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text("No transition yet — they appear here as sessions change state.")
                                .themeFont(size: 11.5, design: .monospaced)
                                .foregroundStyle(DefaultTheme.mutedText)
                                .padding(DefaultTheme.space(10))
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            line(row).id(index)
                        }
                    }
                    .padding(.vertical, DefaultTheme.space(6))
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: rows.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .background(DefaultTheme.background)
        .task(id: model.transitionTick) {
            rows = await model.recentTransitions()
        }
    }

    private func line(_ row: TransitionRecord) -> some View {
        HStack(spacing: DefaultTheme.space(10)) {
            Text(Self.time.string(from: row.at))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(width: 92, alignment: .leading)
            Text(Self.source(row.source))
                .foregroundStyle(DefaultTheme.secondaryText)
                .frame(width: 46, alignment: .leading)
            HStack(spacing: 0) {
                Text(row.event ?? "\(row.from.rawValue) → \(row.to.rawValue)")
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(" · \(subject(of: row))")
                    .foregroundStyle(DefaultTheme.mutedText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("→ \(row.to.rawValue)")
                .themeFont(size: 10.5, design: .monospaced)
                .foregroundStyle(FleetState.color(row.to))
        }
        .themeFont(size: 11.5, design: .monospaced)
        .monospacedDigit()
        .padding(.horizontal, DefaultTheme.space(10))
        .padding(.vertical, DefaultTheme.space(3))
    }

    private static func source(_ source: TransitionSource) -> String {
        switch source {
        case .hook: "HOOK"
        case .heuristic: "HEUR"
        case .process: "PROC"
        case .user: "USER"
        }
    }

    /// The session a row is about: its branch without the `loom/` prefix,
    /// else its title.
    private func subject(of row: TransitionRecord) -> String {
        let live = model.sessions.first { $0.id.rawValue.uuidString == row.sessionID }
        let record = live == nil ? model.allRecords.first { $0.id.rawValue.uuidString == row.sessionID } : nil
        if let branch = live?.branch ?? record?.branch {
            return branch.hasPrefix("loom/") ? String(branch.dropFirst(5)) : branch
        }
        return live?.title ?? record?.title ?? String(row.sessionID.prefix(8))
    }
}
