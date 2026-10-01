import AppKit
import LoomCore
import LoomTerminal
import LoomUI
import SwiftUI

/// The self-contained terminal pane: surface fetch, attach lifecycle, grid
/// resize (TRM-02, placeholder-proof), keyboard capture and boot placeholder.
/// Used by the session detail AND the embedded PR review pane — the wiring
/// lives once.
struct TerminalPane: View {
    let model: AppModel
    let sessionID: SessionID
    /// Where this pane lives — the grid it measures is remembered per role.
    let role: TerminalPaneRole
    /// A divider beside the pane is being dragged: the grid holds until the
    /// drag ends, then the pane fits once — a drag with pauses used to apply
    /// one resize, hence one repaint of the conversation, per pause.
    let fitSuspended: Bool
    /// The pane's other shape (with the side panel open: the full width; with
    /// it closed: the split's), whose grid is remembered from the same fit —
    /// the launch grid of either shape never goes stale while the other shows.
    let otherShape: (role: TerminalPaneRole, width: CGFloat)?
    /// Seeded from the model's cache: a live session's pane paints its retained
    /// screen in its first commit, no spinner, no actor round trip first.
    @State private var surface: TerminalSurface?

    init(model: AppModel, sessionID: SessionID, role: TerminalPaneRole = .session,
         fitSuspended: Bool = false, otherShape: (role: TerminalPaneRole, width: CGFloat)? = nil) {
        self.model = model
        self.sessionID = sessionID
        self.role = role
        self.fitSuspended = fitSuspended
        self.otherShape = otherShape
        _surface = State(initialValue: model.cachedSurface(for: sessionID))
    }
    @State private var paneSize: CGSize = .zero
    /// The surface the last fit went to: its first fit is immediate, the
    /// following ones are debounced.
    @State private var fittedSurface: ObjectIdentifier?
    @State private var selection = TerminalSelection.empty
    /// One transient badge slot, shared by everything worth flashing: the grid
    /// applied by a resize, the characters a copy took. Two badges in the same
    /// corner would sit on top of each other.
    @State private var badge: String?
    /// Terminal.app's "Option as Meta": ⌥+letter sends ESC+letter. Off by
    /// default — it would take the AZERTY braces and the dead keys away.
    @AppStorage(KeyboardPreferences.userDefaultsKey) private var optionAsMeta = false

    var body: some View {
        Group {
            if let surface {
                TerminalScreenView(screen: surface.screen, history: surface.history,
                                   historyBase: surface.historyBase,
                                   selection: $selection,
                                   onCopied: { badge = copiedBadge($0) })
                    // TRM-02: the view announces its grid. Measured from a
                    // BACKGROUND geometry reader feeding @State — a wrapping
                    // GeometryReader hands `.task(id:)` a value that is not
                    // state, and the resize can then miss a size change.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PaneSizeKey.self, value: proxy.size)
                    })
                    .onPreferenceChange(PaneSizeKey.self) { paneSize = $0 }
                    // task(id:) gives a free debounce while resizing: each new
                    // size cancels the pending one. The delay outlasts a layout
                    // animation on purpose: every resize that reaches the PTY
                    // makes the agent repaint its whole conversation, and a
                    // slide that resized it three times left three copies.
                    // Keyed on the SURFACE too: a new session in the same pane
                    // (another PR tab) is fitted at once, not left at its
                    // launch grid until the pane happens to move.
                    // Keyed on the suspension as well: the end of a divider
                    // drag is itself the change that fits the final size.
                    .task(id: FitKey(size: paneSize, surface: ObjectIdentifier(surface),
                                     suspended: fitSuspended)) {
                        let first = fittedSurface != ObjectIdentifier(surface)
                        switch TerminalFitPolicy.decide(size: paneSize, suspended: fitSuspended,
                                                        isFirstFitForSurface: first) {
                        case .skip:
                            return
                        case .immediate:
                            fittedSurface = ObjectIdentifier(surface)
                        case .debounced:
                            try? await Task.sleep(for: TerminalFitPolicy.debounce)
                            guard !Task.isCancelled else { return }
                        }
                        let grid = TerminalMetrics.grid(fitting: paneSize)
                        surface.resize(cols: grid.cols, rows: grid.rows)
                        model.noteTerminalGrid(cols: grid.cols, rows: grid.rows, role: role)
                        if let otherShape {
                            let other = TerminalMetrics.grid(fitting: CGSize(width: otherShape.width,
                                                                             height: paneSize.height))
                            model.noteTerminalGrid(cols: other.cols, rows: other.rows, role: otherShape.role)
                        }
                        badge = "\(grid.cols)×\(grid.rows)"
                    }
                    // Keystrokes go to the agent's field (first responder).
                    // NO tap gesture and no contentShape here: they would claim the
                    // press that starts a selection drag. Reclaiming focus on click
                    // is already the job of KeyCaptureView's mouse-down monitor,
                    // which exists precisely because that tap never fired.
                    .background(KeyCaptureView(modes: surface.modes,
                                               preferences: KeyboardPreferences(optionAsMeta: optionAsMeta),
                                               onWheel: { direction, col, row in
                                                   surface.sendWheel(direction, atCol: col, row: row)
                                               },
                                               onClick: { col, row in
                                                   surface.sendClick(atCol: col, row: row)
                                               },
                                               onCopy: { selection.capturedText },
                                               onCopied: { badge = copiedBadge($0) },
                                               onFocus: { surface.setFocus($0) },
                                               onText: { text in
                                                   // Typing dismisses the selection, like any
                                                   // terminal — and this is also what covers
                                                   // Escape, which the agent must still receive.
                                                   if selection.isActive { selection = .empty }
                                                   surface.send(text)
                                               }))
                    // Absolute rows mean nothing across a reflow or another terminal.
                    .onChange(of: surface.screen.geometry) { selection = .empty }
                    .onReceive(NotificationCenter.default.publisher(for: .loomSelectAllTerminal)) { _ in
                        selection = .all(history: surface.history,
                                         historyBase: surface.historyBase,
                                         screen: surface.screen)
                        // The keyboard follows the selection: ⌘C copies from
                        // whoever has it, and a page or an address bar beside
                        // the terminal may. Freed, the terminal reclaims it.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    // claude's boot takes seconds — never a silent black screen.
                    // Gated on real output: the pane's own first fit bumps the
                    // screen revision before the agent has printed a byte.
                    .overlay {
                        if !surface.hasOutput {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("claude is starting…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DefaultTheme.secondaryText)
                                Text("Plugins and MCP servers load first — unauthenticated MCP servers slow this down (run /mcp).")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DefaultTheme.mutedText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 380)
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(DefaultTheme.surfaceRaised, in: Capsule())
                                .overlay(Capsule().stroke(DefaultTheme.cardBorder, lineWidth: 1))
                                .padding(10)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.hover, value: badge)
                    // Each new badge restarts the countdown: task(id:) cancels the
                    // pending clear, so a copy right after a resize is not cut short.
                    .task(id: badge) {
                        guard badge != nil else { return }
                        try? await Task.sleep(for: .seconds(1.4))
                        guard !Task.isCancelled else { return }
                        badge = nil
                    }
                    .background(DefaultTheme.contentBackground)
                    // Keyed on the surface: a pane whose session changed (the PR
                    // drawer switching tabs) attaches the NEW surface; an id-less
                    // task ran once and left the newcomer detached.
                    .task(id: ObjectIdentifier(surface)) { await surface.attached() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sessionID) {
            selection = .empty
            let fetched = await model.surface(for: sessionID)
            if fetched !== surface { surface = fetched }
        }
    }
}

/// A copy leaves no trace of its own — the badge is the only confirmation that
/// ⌘C, or a silent copy-on-select, actually took something.
private func copiedBadge(_ characters: Int) -> String {
    characters == 1 ? "1 character copied" : "\(characters.formatted()) characters copied"
}

/// What a fit depends on: the pane's size, the surface it goes to, and
/// whether fitting is on hold.
private struct FitKey: Equatable {
    let size: CGSize
    let surface: ObjectIdentifier
    let suspended: Bool
}

private struct PaneSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
