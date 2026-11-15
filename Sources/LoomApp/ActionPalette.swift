import AppKit
import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// One entry of the ⌘K action palette: icon, title, subtitle, its section
/// header, an optional shortcut hint, and the action it runs — or the one
/// thing it asks first, in the palette itself.
struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let section: String
    var shortcut: String?
    /// Set when the action needs one line of text before it can run: Return
    /// turns the palette into that prompt, and `run` is never called.
    var prompt: PalettePrompt?
    let run: () -> Void
}

extension PaletteAction {
    /// "Review code". Named: the theme tour opens the palette on its prompt.
    static let reviewID = "act.review"
}

/// What an action asks in the palette before it runs — one line, typed where
/// the search was. Never a second sheet: the palette is already there, with
/// the keyboard (ADR-0024).
struct PalettePrompt {
    /// Shown in the field, in place of the search placeholder.
    let title: String
    /// Under the field: what Return does.
    let hint: String
    /// What the field holds when the prompt opens, selected. Read then, not
    /// when the actions are listed: only the action that wants the clipboard
    /// looks at it.
    var prefill: () -> String? = { nil }
    /// Return. nil: the text was taken, and the palette closes. Else one
    /// line saying why not, shown under the field: the prompt stays.
    let submit: (String) -> String?
}

/// `run` and the prompt's closures cannot be compared; the fields a row
/// shows, the ranking reads and a prompt displays are what decides whether
/// the list must be rebuilt.
extension PaletteAction: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id, lhs.icon == rhs.icon, lhs.title == rhs.title,
              lhs.subtitle == rhs.subtitle, lhs.section == rhs.section,
              lhs.shortcut == rhs.shortcut else { return false }
        return lhs.prompt?.title == rhs.prompt?.title && lhs.prompt?.hint == rhs.prompt?.hint
    }
}

/// A row of the list and its place in it, counted from the top across the
/// sections: what the selection counts in.
private struct PaletteEntry: Identifiable {
    let index: Int
    let action: PaletteAction
    var id: String { action.id }
}

private struct PaletteSection: Identifiable {
    let title: String
    let entries: [PaletteEntry]
    var id: String { title }
}

/// The list as displayed. Rendering and keyboard selection both read it, so
/// the highlighted row is always the one ↑↓ landed on. Built when the query
/// (or the action list) changes, never per body: the body runs again on
/// every row the pointer crosses.
private struct PaletteListing {
    /// The order sections are drawn in — also the order ↑↓ walks through them.
    static let sectionOrder = ["Navigation", "Actions", "Extensions", "Theme", "Projects", "Sessions"]

    let sections: [PaletteSection]
    /// The rows end to end: row i is the i-th one ↑↓ lands on.
    let rows: [PaletteAction]

    /// `shown`, best first, laid out under its section headers.
    init(_ shown: [PaletteAction]) {
        let grouped: [String: [PaletteAction]] = Dictionary(grouping: shown, by: { $0.section })
        var sections: [PaletteSection] = []
        var rows: [PaletteAction] = []
        for title in Self.sectionOrder {
            guard let actions = grouped[title], !actions.isEmpty else { continue }
            var entries: [PaletteEntry] = []
            entries.reserveCapacity(actions.count)
            for action in actions {
                entries.append(PaletteEntry(index: rows.count, action: action))
                rows.append(action)
            }
            sections.append(PaletteSection(title: title, entries: entries))
        }
        self.sections = sections
        self.rows = rows
    }

    /// With an empty query only Navigation + Actions show — the launcher pose.
    init(launcher actions: [PaletteAction]) {
        self.init(actions.filter { $0.section == "Navigation" || $0.section == "Actions" })
    }
}

/// What had the keyboard when the palette opened — a terminal, a field, a
/// web page. A sheet left it where it was, in the window underneath; an
/// overlay takes it from its own window and has to hand it back.
@MainActor
private enum PaletteKeyboard {
    private static weak var owner: NSView?
    private static var caret: NSRange?
    /// Counts the openings: a hand-back still pending from the last one is
    /// not this one's.
    private static var opening = 0

    /// Before the palette's field asks for the keyboard: who has it now.
    static func remember() {
        opening += 1
        owner = nil
        caret = nil
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            // A field being edited: the window's shared editor stands in for
            // it. The field is what takes the keyboard back — and the caret
            // its place, where AppKit would select the whole text.
            owner = editor.delegate as? NSView
            caret = editor.selectedRange()
        } else {
            owner = window.firstResponder as? NSView
        }
    }

    /// The palette closed, in the pass that removes it: its field may still
    /// be in the window with the keyboard, and what its action focuses comes
    /// in a later pass — so the keyboard is taken from the field now. Asked
    /// once more shortly after: Return ends with AppKit selecting the
    /// field's text again, which takes back a keyboard given during it.
    static func giveBack() {
        hand(fromField: true)
        let closed = opening
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard closed == opening else { return }
            hand(fromField: false)
            owner = nil
            caret = nil
        }
    }

    /// The key monitor that keeps Tab in the palette, for as long as it shows.
    private static var tabMonitor: Any?

    /// A sheet was its own window: Tab had nowhere to go. An overlay shares
    /// its window's key loop with every field and terminal under the scrim,
    /// and Tab handed one of them the keyboard — the palette still drawn,
    /// Return then answered by a field nobody sees. While the palette
    /// shows, Tab (⇧ or not) goes nowhere in its window.
    static func holdTab() {
        guard tabMonitor == nil else { return }
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 48: the Tab key. A sheet over the window keeps its own, and
            // so does an input method composing in the field.
            guard event.keyCode == 48, let window = event.window,
                  window === (NSApp.mainWindow ?? NSApp.keyWindow),
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }
            return nil
        }
    }

    static func releaseTab() {
        if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
        tabMonitor = nil
    }

    /// Never taken from a view that got the keyboard meanwhile, and a view
    /// that left the window (its tab was closed) is not called back.
    private static func hand(fromField: Bool) {
        guard let view = owner, let window = view.window else { return }
        let current = window.firstResponder
        guard current !== view else { return }
        let idle = current == nil || current === window
        let inField = (current as? NSTextView)?.isFieldEditor == true
        guard idle || (fromField && inField), window.makeFirstResponder(view) else { return }
        if let range = caret, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           NSMaxRange(range) <= (editor.string as NSString).length {
            editor.setSelectedRange(range)
        }
    }
}

/// Where the palette shows: over the window's own content, not in a sheet
/// (ADR-0024) — a scrim that takes the clicks, the palette near the top, no
/// transition either way. A sheet was a window built and animated on every
/// ⌘K, and animated away before the result showed. Esc, ⌘K again or a click
/// outside closes it.
struct PaletteOverlay: View {
    @Binding var isPresented: Bool
    /// Called while the palette shows, and only then: nothing is listed for
    /// a closed palette, whatever changes in the app meanwhile.
    let actions: () -> [PaletteAction]
    let transcriptSearch: (String) async -> [SessionStore.SearchHit]
    let onOpenSession: (SessionID) -> Void
    /// The action whose prompt the palette opens on, when something other
    /// than ⌘K opened it.
    @State private var opensOn: String?

    var body: some View {
        ZStack(alignment: .top) {
            if isPresented {
                Color.black.opacity(DefaultTheme.colorScheme == .dark ? 0.5 : 0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                    .transition(.identity)
                ActionPaletteView(actions: actions(),
                                  transcriptSearch: transcriptSearch,
                                  onOpenSession: onOpenSession,
                                  opensOn: opensOn,
                                  isPresented: $isPresented)
                    // The shadow is cast by a plain shape behind the palette:
                    // cast by the palette itself, it would be drawn again
                    // with every keystroke.
                    .background {
                        RoundedRectangle(cornerRadius: DefaultTheme.radius(10))
                            .fill(DefaultTheme.surface)
                            .shadow(color: .black.opacity(DefaultTheme.colorScheme == .dark ? 0.5 : 0.18),
                                    radius: 24, y: 10)
                    }
                    .padding(.top, DefaultTheme.space(80))
                    .transition(.identity)
            }
        }
        // The terminal panes watch every click and wheel event of this
        // window: under the palette they stand down. When it closes, the
        // keyboard goes back to what had it, and a terminal takes it if
        // that left it to no one.
        .onChange(of: isPresented) {
            if isPresented {
                WindowOverlay.isUp = true
                PaletteKeyboard.holdTab()
            } else {
                PaletteKeyboard.releaseTab()
                PaletteKeyboard.giveBack()
                WindowOverlay.isUp = false
                if opensOn != nil { opensOn = nil }
            }
        }
        // The theme tour's "palette-review": the palette, asking for the
        // pull request.
        .onReceive(NotificationCenter.default.publisher(for: .loomTourShow)) { note in
            guard let state = note.object as? String, state == "palette-review" else { return }
            opensOn = PaletteAction.reviewID
            isPresented = true
        }
    }
}

/// The ⌘K action palette (Raycast-style): search across commands, settings,
/// projects and sessions; ↑↓ to navigate, Enter to run, Esc to close.
/// With an empty query only Navigation + Actions show — the launcher pose.
/// An action that has a question (`PalettePrompt`) asks it here: the field
/// becomes its answer, the list its hint, and Esc returns to the list.
struct ActionPaletteView: View {
    let actions: [PaletteAction]
    let transcriptSearch: (String) async -> [SessionStore.SearchHit]
    let onOpenSession: (SessionID) -> Void
    /// The id of an action whose prompt the palette opens on.
    let opensOn: String?
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @State private var transcriptHits: [SessionStore.SearchHit] = []
    @State private var listing: PaletteListing
    /// The actions' titles as the match reads them, folded once per action
    /// list — at the first character typed — instead of once per keystroke.
    /// Empty until then, and again when the list changes.
    @State private var keys: [[Character]] = []
    /// The action whose prompt is up, if any.
    @State private var asking: PaletteAction?
    @State private var promptError: String?
    /// Where the pointer was when the list last changed or scrolled (see `hover`).
    @State private var restingPointer = CGPoint.zero
    /// The Esc press last answered (see `escape`).
    @State private var lastEscape: TimeInterval = 0
    @FocusState private var searchFocused: Bool

    init(actions: [PaletteAction],
         transcriptSearch: @escaping (String) async -> [SessionStore.SearchHit],
         onOpenSession: @escaping (SessionID) -> Void,
         opensOn: String? = nil,
         isPresented: Binding<Bool>) {
        self.actions = actions
        self.transcriptSearch = transcriptSearch
        self.onOpenSession = onOpenSession
        self.opensOn = opensOn
        _isPresented = isPresented
        // Seeded here: the first pass already draws the launcher pose, not
        // an empty list a second pass has to fill.
        _listing = State(initialValue: PaletteListing(launcher: actions))
    }

    private var totalCount: Int { listing.rows.count + transcriptHits.count }

    var body: some View {
        // Around the field too: ↑↓ are pressed in it, and scroll the list.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                field(proxy)
                Divider().overlay(DefaultTheme.cardBorder)
                if let prompt = asking?.prompt {
                    promptBody(prompt)
                } else {
                    results
                }
                Divider().overlay(DefaultTheme.cardBorder)
                footer
            }
        }
        .frame(width: 640)
        .frame(maxHeight: 520)
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        // The app moved under the palette (a session started, an extension
        // loaded): the titles are folded again, the query is asked again.
        .onChange(of: actions) {
            guard asking == nil else {
                keys = []
                return
            }
            let shown = found(by: query, refold: true)
            listing = shown
            clampSelection(to: shown.rows.count + transcriptHits.count)
        }
        // Only the transcript search waits here, debounced: what the query
        // finds among the actions is set with the query itself (`edit`).
        .task(id: query) {
            let searched = query
            // A prompt's text is an answer, not a search.
            guard asking == nil, searched.count >= 2 else {
                if !transcriptHits.isEmpty { transcriptHits = [] }
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await transcriptSearch(searched)
            // The text may have moved on while the query ran: stale hits would
            // answer a question nobody is asking any more.
            guard !Task.isCancelled, searched == query, asking == nil else { return }
            transcriptHits = hits
            clampSelection(to: listing.rows.count + hits.count)
        }
        .onAppear {
            // Before the field asks for the keyboard: who has it now.
            PaletteKeyboard.remember()
            restingPointer = NSEvent.mouseLocation
            searchFocused = true
            // Asked again once the palette is in the window: a focus asked
            // for in the pass that inserts the field can be dropped.
            DispatchQueue.main.async { searchFocused = true }
            if let opensOn, let action = actions.first(where: { $0.id == opensOn }) {
                ask(action)
            }
        }
    }

    // MARK: The field

    private func field(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: DefaultTheme.space(10)) {
            AppIcon(asking?.icon ?? "magnifyingglass", size: 15.5)
                .foregroundStyle(DefaultTheme.secondaryText)
            // One field for the search and for a prompt: it keeps the
            // keyboard when the palette changes from one to the other.
            TextField(asking?.prompt?.title ?? "Search commands, settings, projects, sessions…",
                      text: Binding(get: { query }, set: { edit($0) }))
                .textFieldStyle(.plain)
                .themeFont(size: 15)
                .foregroundStyle(DefaultTheme.primaryText)
                .focused($searchFocused)
                .onSubmit { submit() }
                .onKeyPress(.upArrow) { step(-1, proxy) }
                .onKeyPress(.downArrow) { step(1, proxy) }
                .onKeyPress(.escape) { escape(); return .handled }
                .onExitCommand { escape() }
            PaletteKeyChip(label: "esc")
        }
        .padding(.horizontal, DefaultTheme.space(16)).padding(.vertical, DefaultTheme.space(14))
    }

    /// One keystroke, one pass: the text, what it finds and the selection
    /// change together. The list used to trail the field by a render, and
    /// the selection by another.
    private func edit(_ text: String) {
        guard text != query else { return }
        query = text
        guard asking == nil else {
            if promptError != nil { promptError = nil }
            return
        }
        listing = found(by: text)
        if selection != 0 { selection = 0 }
        restingPointer = NSEvent.mouseLocation
    }

    /// What `text` finds among the actions, rank-sorted inside each section.
    /// `refold`: the action list changed, its folded titles are stale.
    private func found(by text: String, refold: Bool = false) -> PaletteListing {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if refold, !keys.isEmpty { keys = [] }
            return PaletteListing(launcher: actions)
        }
        var folded: [[Character]] = refold ? [] : keys
        if refold || folded.count != actions.count {
            folded = actions.map { CommandPalette.key(for: $0.title) }
            keys = folded
        }
        let ranked: [PaletteAction] = CommandPalette.rankIndices(query: trimmed, keys: folded)
            .map { actions[$0] }
        return PaletteListing(ranked)
    }

    /// The selection stays on a row when the list shrinks under it.
    private func clampSelection(to count: Int) {
        let last = max(count - 1, 0)
        if selection > last { selection = last }
    }

    // MARK: The list

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                ForEach(listing.sections) { section in
                    sectionHeader(section.title)
                    // A row is its action, not its place: a filter that moves
                    // it keeps it, instead of making it again.
                    ForEach(section.entries) { entry in
                        PaletteRow(icon: entry.action.icon,
                                   title: entry.action.title,
                                   subtitle: entry.action.subtitle,
                                   shortcut: entry.action.shortcut,
                                   isSelected: entry.index == selection)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture { run(entry.action) }
                            .onHover { inside in hover(inside, at: entry.index) }
                            .id(entry.id)
                    }
                }
                if !transcriptHits.isEmpty {
                    sectionHeader("In transcripts")
                    ForEach(Array(transcriptHits.enumerated()), id: \.element.id) { offset, hit in
                        PaletteRow(icon: "text.magnifyingglass",
                                   title: hit.title,
                                   subtitle: hit.snippet,
                                   excerpt: true,
                                   isSelected: listing.rows.count + offset == selection)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture { open(hit) }
                            .onHover { inside in hover(inside, at: listing.rows.count + offset) }
                            .id(hit.id)
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
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(10)).padding(.top, DefaultTheme.space(10)).padding(.bottom, DefaultTheme.space(4))
    }

    /// The pointer selects a row by moving onto it. A row that only appears
    /// under a pointer at rest does not: the list changes under it at every
    /// keystroke, and Return runs what the keyboard chose.
    private func hover(_ inside: Bool, at index: Int) {
        guard inside, selection != index, NSEvent.mouseLocation != restingPointer else { return }
        selection = index
    }

    /// ↑↓ walk the list, and scroll it: only the keyboard does — a row under
    /// the pointer is in view already. In a prompt they are the field's own.
    private func step(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard asking == nil else { return .ignored }
        let count = totalCount
        guard count > 0 else { return .handled }
        let target = (min(selection, count - 1) + delta + count) % count
        selection = target
        // The scroll may bring another row under the pointer: not a hover.
        restingPointer = NSEvent.mouseLocation
        let rows = listing.rows
        if target < rows.count {
            proxy.scrollTo(rows[target].id, anchor: nil)
        } else {
            proxy.scrollTo(transcriptHits[target - rows.count].id, anchor: nil)
        }
        return .handled
    }

    // MARK: A prompt

    private func promptBody(_ prompt: PalettePrompt) -> some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            Text(prompt.hint)
                .themeFont(size: 12)
                .foregroundStyle(DefaultTheme.secondaryText)
            if let promptError {
                Text(promptError)
                    .themeFont(size: 12)
                    .foregroundStyle(DefaultTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DefaultTheme.space(16)).padding(.vertical, DefaultTheme.space(14))
    }

    /// The palette becomes the action's prompt: same panel, same field, the
    /// keyboard where it was.
    private func ask(_ action: PaletteAction) {
        guard let prompt = action.prompt else { return }
        let prefill = prompt.prefill() ?? ""
        asking = action
        promptError = nil
        query = prefill
        searchFocused = true
        guard !prefill.isEmpty else { return }
        // Offered, not imposed: selected, so that typing replaces it. Once
        // the field holds it — the text reaches the field after this pass.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard asking != nil,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DefaultTheme.space(14)) {
            if asking == nil {
                legend("↑↓", "navigate")
                legend("enter", "select")
                legend("esc", "close")
            } else {
                legend("enter", "confirm")
                legend("esc", "back")
            }
            Spacer()
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(9))
    }

    private func legend(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: DefaultTheme.space(5)) {
            PaletteKeyChip(label: key)
            Text(meaning).themeFont(size: 11).foregroundStyle(DefaultTheme.secondaryText)
        }
    }

    // MARK: Return, Esc, a click

    /// Return: the selected row — or, in a prompt, its answer.
    private func submit() {
        guard let prompt = asking?.prompt else {
            runSelected()
            return
        }
        if let refusal = prompt.submit(query) {
            promptError = refusal
            searchFocused = true
        } else {
            isPresented = false
        }
    }

    /// Esc reaches a field as a key press or as its exit command, depending
    /// on what the field's editor makes of it; a sheet closed on it by
    /// itself. Both are listened to, and a press is answered once.
    private func escape() {
        let pressed = NSApp.currentEvent?.timestamp ?? 0
        guard pressed == 0 || pressed != lastEscape else { return }
        lastEscape = pressed
        back()
    }

    /// Esc: out of a prompt, back to the list, on the action that asked;
    /// out of the list, the palette closes.
    private func back() {
        guard let asked = asking else {
            isPresented = false
            return
        }
        let shown = found(by: "")
        asking = nil
        promptError = nil
        query = ""
        listing = shown
        selection = shown.rows.firstIndex { $0.id == asked.id } ?? 0
        restingPointer = NSEvent.mouseLocation
    }

    private func runSelected() {
        let rows = listing.rows
        if selection < rows.count {
            run(rows[selection])
        } else if selection - rows.count < transcriptHits.count {
            open(transcriptHits[selection - rows.count])
        }
    }

    /// A row chosen, by Return or by a click. The palette closes first — at
    /// once, there is no sheet to wait for — unless the action has a
    /// question: then it stays, and asks it.
    private func run(_ action: PaletteAction) {
        guard action.prompt == nil else {
            ask(action)
            return
        }
        isPresented = false
        action.run()
    }

    private func open(_ hit: SessionStore.SearchHit) {
        isPresented = false
        onOpenSession(hit.id)
    }
}

/// One row of the list — a VALUE SwiftUI compares (`.equatable()`): a
/// keystroke, an arrow or a hover re-runs the rows that changed, not every
/// visible one. What a click and the pointer do is attached by the list,
/// outside the comparison: a closure here would go stale in a row that is
/// kept.
private struct PaletteRow: View, Equatable {
    let icon: String
    let title: String
    let subtitle: String
    var shortcut: String?
    /// A transcript excerpt under the title: mono, on one line.
    var excerpt = false
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DefaultTheme.space(11)) {
            AppIcon(icon, size: 15.5)
                .foregroundStyle(isSelected ? DefaultTheme.accentInk : DefaultTheme.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                Text(title)
                    .themeFont(size: 13, weight: .medium)
                    .foregroundStyle(DefaultTheme.primaryText)
                if excerpt {
                    Text(subtitle)
                        .themeFont(size: 11, design: .monospaced)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                } else {
                    HStack(spacing: DefaultTheme.space(5)) {
                        Text(subtitle)
                            .themeFont(size: 11)
                            .foregroundStyle(DefaultTheme.secondaryText)
                        if let shortcut {
                            Text("• \(shortcut)")
                                .themeFont(size: 11)
                                .foregroundStyle(DefaultTheme.mutedText)
                        }
                    }
                }
            }
            Spacer()
            if isSelected { PaletteKeyChip(label: "enter") }
        }
        .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(7))
        .background(isSelected ? DefaultTheme.surfaceRaised : .clear,
                    in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
    }
}

private struct PaletteKeyChip: View {
    let label: String

    var body: some View {
        Text(label)
            .themeFont(size: 10, weight: .medium, design: .monospaced)
            .foregroundStyle(DefaultTheme.secondaryText)
            .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(3))
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(5)))
            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(5))
                .stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }
}
