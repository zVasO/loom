import LoomAgents
import LoomCore
import LoomPersistence
import LoomTerminal
import LoomUI
import SwiftUI

/// Mission Control: the whole fleet as one dense table. Each live session is
/// a row (state, title, branch, context, duration, the action it waits for);
/// the selected one shows its live terminal underneath, with a reply field
/// when it needs input. Spot the session that waits for you, answer it,
/// move on — without cycling through tabs.
///
/// Keyboard: ↑ ↓ (or j k) move the selection, ↵ opens the session,
/// r focuses the reply field of a session that needs input.
struct MissionControlView: View {
    let model: AppModel
    let onOpen: (SessionID) -> Void

    @State private var filter: FleetFilter = .all
    @State private var selected: SessionID?
    @FocusState private var tableFocused: Bool
    @FocusState private var replyFocused: Bool

    private var fleet: [AppModel.SessionItem] {
        model.sessions.filter { !$0.isShell }
    }

    private var visible: [AppModel.SessionItem] {
        fleet.filter { filter.matches($0) }
    }

    private var selectedItem: AppModel.SessionItem? {
        guard let selected else { return nil }
        return fleet.first { $0.id == selected }
    }

    var body: some View {
        Group {
            if fleet.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    header
                    Hairline()
                    table
                    if let item = selectedItem {
                        Hairline()
                        FleetTerminalPanel(model: model, item: item, replyFocused: $replyFocused)
                            .id(item.id)
                    }
                    Hairline()
                    footer
                }
                .background(DefaultTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DefaultTheme.cardBorder, lineWidth: 1))
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.background)
        .onAppear {
            ensureSelection()
            tableFocused = true
        }
        .onChange(of: fleet.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: filter) { _, _ in ensureSelection() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Mission control")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
            MonoLabel("\(fleet.count) sessions")
            Spacer(minLength: 12)
            FilterBar(selection: $filter, counts: counts)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var counts: [FleetFilter: Int] {
        Dictionary(uniqueKeysWithValues: FleetFilter.allCases.map { f in
            (f, fleet.filter { f.matches($0) }.count)
        })
    }

    // MARK: - Table

    private var table: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(visible) { item in
                            FleetRow(model: model, item: item,
                                     isSelected: item.id == selected,
                                     onSelect: { select(item.id) },
                                     onOpen: { onOpen(item.id) },
                                     onReply: { reply(to: item.id) })
                                .id(item.id)
                        }
                        if visible.isEmpty {
                            Text("No session matches this filter.")
                                .font(.system(size: 12))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    } header: {
                        FleetColumnsHeader()
                    }
                }
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.hover) { proxy.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focused($tableFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkr")) { press in
            switch press.characters {
            case "j": move(1)
            case "k": move(-1)
            default:
                guard let item = selectedItem, item.state == .needsInput else { return .ignored }
                reply(to: item.id)
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard let selected else { return .ignored }
            onOpen(selected)
            return .handled
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(DefaultTheme.badgeColor(for: .working)).frame(width: 6, height: 6)
                MonoLabel("\(counts[.working] ?? 0) working")
            }
            HStack(spacing: 6) {
                Circle().fill(DefaultTheme.badgeColor(for: .needsInput)).frame(width: 6, height: 6)
                MonoLabel("\(counts[.needsInput] ?? 0) needs input")
            }
            HStack(spacing: 6) {
                Circle().fill(DefaultTheme.badgeColor(for: .idle)).frame(width: 6, height: 6)
                MonoLabel("\(counts[.idle] ?? 0) idle")
            }
            Spacer(minLength: 12)
            KeyHint(keys: ["↑", "↓"], label: "navigate")
            KeyHint(keys: ["↵"], label: "open")
            KeyHint(keys: ["R"], label: "reply")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(DefaultTheme.contentBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .light))
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
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Selection

    private func select(_ id: SessionID) {
        selected = id
        tableFocused = true
    }

    private func move(_ delta: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : rows.count)
        selected = rows[min(rows.count - 1, max(0, index + delta))].id
    }

    private func reply(to id: SessionID) {
        selected = id
        // The reply field mounts with the panel of the new selection.
        DispatchQueue.main.async { replyFocused = true }
    }

    /// Keeps a visible row selected: the one already chosen, else the first
    /// session that waits for you, else the first row.
    private func ensureSelection() {
        let rows = visible
        if let selected, rows.contains(where: { $0.id == selected }) { return }
        selected = (rows.first { $0.state == .needsInput } ?? rows.first)?.id
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
}

@MainActor
private struct FilterBar: View {
    @Binding var selection: FleetFilter
    let counts: [FleetFilter: Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FleetFilter.allCases, id: \.self) { filter in
                FilterSegment(title: filter.title, count: counts[filter] ?? 0,
                              isOn: selection == filter) { selection = filter }
            }
        }
        .padding(2)
        .background(DefaultTheme.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DefaultTheme.cardBorder, lineWidth: 1))
    }
}

private struct FilterSegment: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                Text("\(count)").foregroundStyle(DefaultTheme.secondaryText)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .monospacedDigit()
            .foregroundStyle(isOn || hovered ? DefaultTheme.primaryText : DefaultTheme.mutedText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isOn ? DefaultTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isOn ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .animation(.hover, value: isOn)
    }
}

// MARK: - Columns

/// One set of widths for the header and every row, so the columns line up.
private enum FleetColumns {
    static let state: CGFloat = 112
    static let branch: CGFloat = 190
    static let context: CGFloat = 78
    static let duration: CGFloat = 84
    static let action: CGFloat = 96
    static let inset: CGFloat = 14
}

@MainActor
private struct FleetColumnsHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            column("State").frame(width: FleetColumns.state, alignment: .leading)
            column("Session").frame(maxWidth: .infinity, alignment: .leading)
            column("Branch").frame(width: FleetColumns.branch, alignment: .leading)
            column("Context").frame(width: FleetColumns.context, alignment: .leading)
            column("Duration").frame(width: FleetColumns.duration, alignment: .leading)
            Color.clear.frame(width: FleetColumns.action, height: 1)
        }
        .padding(.horizontal, FleetColumns.inset)
        .frame(height: 30)
        .background(DefaultTheme.surface)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func column(_ title: String) -> some View {
        MonoLabel(title, color: DefaultTheme.mutedText)
    }
}

// MARK: - Row

/// One session of the fleet. Its record (agent, creation date) and context
/// usage are read off the main actor once per native conversation.
private struct FleetRow: View {
    let model: AppModel
    let item: AppModel.SessionItem
    let isSelected: Bool
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

    /// Alive: the process runs, so the clock runs.
    private var isLive: Bool {
        !item.isDormant && [.starting, .working, .needsInput, .idle].contains(item.state)
    }

    private var stateColor: Color {
        item.isDormant ? DefaultTheme.accent : DefaultTheme.badgeColor(for: item.state)
    }

    private var stateLabel: String {
        item.isDormant ? "inactive" : DefaultTheme.label(for: item.state)
    }

    private var subtitle: String {
        let project = model.project(item.projectID)?.name
        let agent = record.map { $0.agentID.hasPrefix("claude") ? "claude" : $0.agentID }
        return [project, agent].compactMap { $0 }.joined(separator: " · ")
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
        .padding(.horizontal, FleetColumns.inset)
        .frame(height: 42)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(DefaultTheme.accent).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { Hairline() }
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
        .accessibilityLabel("\(item.title), \(stateLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected { return DefaultTheme.surfaceRaised }
        if hovered { return DefaultTheme.surfaceRaised.opacity(0.5) }
        return .clear
    }

    private var stateCell: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 6, height: 6)
            Text(stateLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
    }

    private var titleCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                BadgeRow(model: model, badges: item.badges)
            }
            if !subtitle.isEmpty {
                Text(subtitle.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var branchCell: some View {
        if let branch = item.branch {
            MonoTag(branch)
                .truncationMode(.middle)
                .padding(.trailing, 12)
        } else {
            Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(DefaultTheme.mutedText)
        }
    }

    private var contextCell: some View {
        HStack(spacing: 7) {
            ContextRing(fraction: usage?.fraction,
                        color: usage.map { $0.level == .normal ? DefaultTheme.secondaryText : $0.level.color }
                            ?? DefaultTheme.secondaryText,
                        size: 13, lineWidth: 2)
            Text(usage.map { ContextWindowSheet.percent($0.fraction) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(DefaultTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var durationCell: some View {
        Group {
            if let record {
                if isLive {
                    // Self-updating: no state, no timer of ours.
                    Text(record.createdAt, style: .timer)
                } else {
                    Text(Self.elapsed(from: record.createdAt, to: record.endedAt ?? Date()))
                }
            } else {
                Text("—")
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(DefaultTheme.secondaryText)
        .lineLimit(1)
    }

    @ViewBuilder
    private var actionCell: some View {
        if item.state == .needsInput && !item.isDormant {
            RowActionButton("Reply", prominent: true, action: onReply)
        } else if item.isDormant {
            RowActionButton("Resume", prominent: false) {
                Task { await model.resumeDormant(item.id) }
            }
        }
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The compact button of a row: accent-filled for what waits on you,
/// outlined otherwise.
private struct RowActionButton: View {
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(prominent ? DefaultTheme.accentText : DefaultTheme.primaryText)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(prominent ? DefaultTheme.accent : (hovered ? DefaultTheme.surfaceRaised : DefaultTheme.surface),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(prominent ? .clear : DefaultTheme.cardBorder, lineWidth: 1))
                .brightness(prominent && hovered ? 0.06 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

// MARK: - Terminal panel

/// The selected session's main terminal: its live tail and, when the agent
/// waits, a reply field that types straight into it.
private struct FleetTerminalPanel: View {
    let model: AppModel
    let item: AppModel.SessionItem
    var replyFocused: FocusState<Bool>.Binding

    @State private var surface: TerminalSurface?
    @State private var reply = ""

    init(model: AppModel, item: AppModel.SessionItem, replyFocused: FocusState<Bool>.Binding) {
        self.model = model
        self.item = item
        self.replyFocused = replyFocused
        _surface = State(initialValue: model.cachedSurface(for: item.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(DefaultTheme.secondaryText)
                MonoLabel("Main terminal")
                Text(item.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let branch = item.branch { MonoTag(branch) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Hairline()

            Group {
                if let surface {
                    TerminalTail(surface: surface, maxLines: 9, fontSize: 11)
                        // A preview's cadence: four frames a second are plenty.
                        .task(id: ObjectIdentifier(surface)) {
                            await surface.attached(cadence: .preview(.milliseconds(250)))
                        }
                } else if item.isDormant {
                    Text("Session inactive — Resume to reopen its conversation.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .padding(14)
                } else {
                    ProgressView().controlSize(.small).padding(14)
                }
            }
            .frame(height: 172, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()

            if item.state == .needsInput, let surface {
                Hairline()
                HStack(spacing: 8) {
                    Text("›")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                    TextField("Reply to the agent…", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .focused(replyFocused)
                        .onSubmit {
                            let text = reply.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            surface.send(text + "\r")
                            reply = ""
                        }
                    KeyCap("↵")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(DefaultTheme.contentBackground)
        .task(id: item.nativeID) {
            let fetched = await model.surface(for: item.id)
            if fetched !== surface { surface = fetched }
        }
    }
}

/// The last populated lines of a terminal, in mono type.
@MainActor
private struct TerminalTail: View {
    let surface: TerminalSurface
    let maxLines: Int
    let fontSize: CGFloat

    private var lines: [String] {
        // P2 perf: find the populated tail FIRST, then map only what we show.
        let all = surface.screen.lines
        var end = all.count
        while end > 0, all[end - 1].cells.allSatisfy({ $0.character == " " }) { end -= 1 }
        let start = max(0, end - maxLines)
        return all[start..<end].map { String($0.cells.prefix(200).map(\.character)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Small pieces

/// A 1 pt rule in the card border colour.
@MainActor
private struct Hairline: View {
    var body: some View {
        Rectangle().fill(DefaultTheme.cardBorder).frame(height: 1)
    }
}

/// Uppercase mono metadata (counters, column titles, hints).
@MainActor
private struct MonoLabel: View {
    let text: String
    let color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .monospacedDigit()
            .foregroundStyle(color ?? DefaultTheme.secondaryText)
            .lineLimit(1)
    }
}

@MainActor
private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            MonoLabel(label, color: DefaultTheme.mutedText).padding(.leading, 3)
        }
    }
}
