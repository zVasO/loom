import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// One entry of the ⌘K action palette: icon, title, subtitle, its section
/// header, an optional shortcut hint, and the action it runs.
struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let section: String
    var shortcut: String?
    let run: () -> Void
}

/// `run` is a closure and cannot be compared; the fields a row shows and the
/// ranking reads are what decides whether the sections must be rebuilt.
extension PaletteAction: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.icon == rhs.icon && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.section == rhs.section
            && lhs.shortcut == rhs.shortcut
    }
}

/// The ⌘K action palette (Raycast-style): search across commands, settings,
/// projects and sessions; ↑↓ to navigate, Enter to run, Esc to close.
/// With an empty query only Navigation + Actions show — the launcher pose.
struct ActionPaletteView: View {
    let actions: [PaletteAction]
    let transcriptSearch: (String) async -> [SessionStore.SearchHit]
    let onOpenSession: (SessionID) -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @State private var transcriptHits: [SessionStore.SearchHit] = []
    @FocusState private var searchFocused: Bool

    /// The order sections are drawn in — also the order ↑↓ walks through them.
    private static let sectionOrder = ["Navigation", "Actions", "Extensions", "Theme", "Projects", "Sessions"]

    /// The filtered entries, rank-sorted inside each section.
    private var matchedActions: [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return actions.filter { $0.section == "Navigation" || $0.section == "Actions" }
        }
        let ranked = CommandPalette.rank(query: trimmed, in: actions.map(\.title))
        let order = Dictionary(ranked.enumerated().map { ($1, $0) }) { first, _ in first }
        return actions
            .filter { order[$0.title] != nil }
            .sorted { (order[$0.title] ?? .max, $0.section) < (order[$1.title] ?? .max, $1.section) }
    }

    /// The sections as displayed, each with the index its first row carries.
    /// Rendering and keyboard selection both read this, so the highlighted row
    /// is always the one ↑↓ landed on. Computed when the query (or the action
    /// list) changes, not per body: the fuzzy ranking folds every candidate
    /// through ICU, and the body re-ran on every hovered row.
    @State private var sections: [(section: String, start: Int, actions: [PaletteAction])] = []

    private func computeSections() -> [(section: String, start: Int, actions: [PaletteAction])] {
        let grouped = Dictionary(grouping: matchedActions, by: \.section)
        var start = 0
        var result: [(String, Int, [PaletteAction])] = []
        for section in Self.sectionOrder {
            guard let entries = grouped[section], !entries.isEmpty else { continue }
            result.append((section, start, entries))
            start += entries.count
        }
        return result
    }

    /// The displayed entries flattened — index i is the i-th visible row.
    private var visibleActions: [PaletteAction] {
        sections.flatMap(\.actions)
    }

    private var totalCount: Int { visibleActions.count + transcriptHits.count }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(DefaultTheme.cardBorder)
            results
            Divider().overlay(DefaultTheme.cardBorder)
            footer
        }
        .frame(width: 640)
        .frame(maxHeight: 520)
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        .onChange(of: query, initial: true) { sections = computeSections() }
        .onChange(of: actions) { sections = computeSections() }
        .task(id: query) {
            selection = 0
            let searched = query
            guard searched.count >= 2 else { transcriptHits = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await transcriptSearch(searched)
            // The text may have moved on while the query ran: stale hits would
            // answer a question nobody is asking any more.
            guard !Task.isCancelled, searched == query else { return }
            transcriptHits = hits
        }
    }

    private var searchField: some View {
        HStack(spacing: DefaultTheme.space(10)) {
            AppIcon("magnifyingglass", size: 15.5)
                .foregroundStyle(DefaultTheme.secondaryText)
            TextField("Search commands, settings, projects, sessions…", text: $query)
                .textFieldStyle(.plain)
                .themeFont(size: 15)
                .foregroundStyle(DefaultTheme.primaryText)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
            keyChip("esc")
        }
        .padding(.horizontal, DefaultTheme.space(16)).padding(.vertical, DefaultTheme.space(14))
        .onAppear { searchFocused = true }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                    let sections = self.sections
                    let actionCount = sections.reduce(0) { $0 + $1.actions.count }
                    ForEach(sections, id: \.section) { section, start, entries in
                        sectionHeader(section)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { offset, action in
                            row(action, index: start + offset)
                                .id(start + offset)
                        }
                    }
                    if !transcriptHits.isEmpty {
                        sectionHeader("In transcripts")
                        ForEach(Array(transcriptHits.enumerated()), id: \.element.id) { offset, hit in
                            transcriptRow(hit, index: actionCount + offset)
                                .id(actionCount + offset)
                        }
                    }
                    if totalCount == 0 {
                        Text("No result")
                            .themeFont(size: 12)
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .padding(DefaultTheme.space(16))
                    }
                }
                .padding(DefaultTheme.space(8))
            }
            .frame(maxHeight: 400)
            .onChange(of: selection) {
                proxy.scrollTo(selection, anchor: nil)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(10)).padding(.top, DefaultTheme.space(10)).padding(.bottom, DefaultTheme.space(4))
    }

    private func row(_ action: PaletteAction, index: Int) -> some View {
        let isSelected = index == selection
        return HStack(spacing: DefaultTheme.space(11)) {
            AppIcon(action.icon, size: 15.5)
                .foregroundStyle(isSelected ? DefaultTheme.accent : DefaultTheme.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                Text(action.title)
                    .themeFont(size: 13, weight: .medium)
                    .foregroundStyle(DefaultTheme.primaryText)
                HStack(spacing: DefaultTheme.space(5)) {
                    Text(action.subtitle)
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.secondaryText)
                    if let shortcut = action.shortcut {
                        Text("• \(shortcut)")
                            .themeFont(size: 11)
                            .foregroundStyle(DefaultTheme.mutedText)
                    }
                }
            }
            Spacer()
            if isSelected { keyChip("enter") }
        }
        .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(7))
        .background(isSelected ? DefaultTheme.surfaceRaised : .clear,
                    in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .contentShape(Rectangle())
        .onTapGesture {
            isPresented = false
            action.run()
        }
        .onHover { if $0, selection != index { selection = index } }
    }

    private func transcriptRow(_ hit: SessionStore.SearchHit, index: Int) -> some View {
        let isSelected = index == selection
        return HStack(spacing: DefaultTheme.space(11)) {
            AppIcon("text.magnifyingglass", size: 15.5)
                .foregroundStyle(isSelected ? DefaultTheme.accent : DefaultTheme.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                Text(hit.title)
                    .themeFont(size: 13, weight: .medium)
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(hit.snippet)
                    .themeFont(size: 11, design: .monospaced)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected { keyChip("enter") }
        }
        .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(7))
        .background(isSelected ? DefaultTheme.surfaceRaised : .clear,
                    in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .contentShape(Rectangle())
        .onTapGesture {
            isPresented = false
            onOpenSession(hit.id)
        }
        .onHover { if $0, selection != index { selection = index } }
    }

    private var footer: some View {
        HStack(spacing: DefaultTheme.space(14)) {
            HStack(spacing: DefaultTheme.space(5)) {
                keyChip("↑↓")
                Text("navigate").themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
            }
            HStack(spacing: DefaultTheme.space(5)) {
                keyChip("enter")
                Text("select").themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
            }
            HStack(spacing: DefaultTheme.space(5)) {
                keyChip("esc")
                Text("close").themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(9))
    }

    private func keyChip(_ label: String) -> some View {
        Text(label)
            .themeFont(size: 10, weight: .medium, design: .monospaced)
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(3))
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(5))
                .stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func move(_ delta: Int) {
        guard totalCount > 0 else { return }
        selection = (selection + delta + totalCount) % totalCount
    }

    private func runSelected() {
        guard totalCount > 0 else { return }
        isPresented = false
        if selection < visibleActions.count {
            visibleActions[selection].run()
        } else {
            let hit = transcriptHits[selection - visibleActions.count]
            onOpenSession(hit.id)
        }
    }
}
