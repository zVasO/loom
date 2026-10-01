import CoreGraphics

/// How a session's detail splits between its terminal and the side panel —
/// pure, so the view only asks and the tests pin the rules.
///
/// Every width the terminal column takes reaches the PTY, and claude answers
/// each resize by repainting its whole conversation (commit 8becfee): the
/// layout therefore never shrinks the terminal under the width of 80 columns
/// on its own — its default share, an agent's reveal — and refuses a split
/// it cannot give a real terminal at all. A width the user dragged to is
/// theirs: kept down to the terminal's drag floor.
public struct SidePanelLayout: Equatable, Sendable {
    public let terminalWidth: CGFloat
    public let panelWidth: CGFloat
    /// The terminal keeps its minimum (80 columns). False: the window is too
    /// narrow for both, and the panel squeezes the terminal — only a split the
    /// user asked for is shown that way.
    public let fits: Bool
    /// False: no split at all — the width is degenerate (a first layout pass
    /// measures zero) or too small to hold a panel beside a usable terminal.
    public let showsPanel: Bool

    public init(terminalWidth: CGFloat, panelWidth: CGFloat, fits: Bool, showsPanel: Bool) {
        self.terminalWidth = terminalWidth
        self.panelWidth = panelWidth
        self.fits = fits
        self.showsPanel = showsPanel
    }

    /// Below this a browser is not worth showing.
    public static let minimumPanelWidth: CGFloat = 300
    /// The drag handle's own slot: its hit area overlaps neither the terminal
    /// (whose mouse monitors would take the press) nor the web view.
    public static let handleWidth: CGFloat = 8
    /// The panel's share of the detail before the user ever dragged it.
    public static let defaultPanelFraction: CGFloat = 0.42
    /// Under this a terminal pane is not fitted at all (TerminalFitPolicy):
    /// a split that left less would show a clipped, stale grid.
    public static let terminalFloor: CGFloat = 160

    /// - Parameters:
    ///   - available: the detail's width.
    ///   - preferredPanelWidth: the width the user dragged to; nil = default share.
    ///   - terminalMinimum: the terminal's floor on its own — 80 columns in the app.
    ///   - terminalDragFloor: how narrow the user may drag the terminal — 40
    ///     columns in the app; never under `terminalFloor`.
    public static func resolve(available: CGFloat,
                               preferredPanelWidth: CGFloat?,
                               terminalMinimum: CGFloat,
                               terminalDragFloor: CGFloat = SidePanelLayout.terminalFloor,
                               minimumPanelWidth: CGFloat = SidePanelLayout.minimumPanelWidth,
                               handleWidth: CGFloat = SidePanelLayout.handleWidth,
                               defaultFraction: CGFloat = SidePanelLayout.defaultPanelFraction) -> SidePanelLayout {
        guard available >= minimumPanelWidth + handleWidth + terminalFloor else {
            return SidePanelLayout(terminalWidth: max(0, available), panelWidth: 0,
                                   fits: false, showsPanel: false)
        }
        if let preferredPanelWidth {
            // The user's own width: the terminal gives way down to the drag
            // floor (or what the panel's minimum leaves, if less).
            let floor = max(terminalFloor, min(terminalDragFloor, available - handleWidth - minimumPanelWidth))
            let panel = min(max(preferredPanelWidth, minimumPanelWidth), available - handleWidth - floor)
            let terminal = available - handleWidth - panel
            return SidePanelLayout(terminalWidth: terminal, panelWidth: panel,
                                   fits: terminal >= terminalMinimum, showsPanel: true)
        }
        let largestPanel = available - handleWidth - terminalMinimum
        if largestPanel >= minimumPanelWidth {
            let wanted = (available * defaultFraction).rounded()
            let panel = min(max(wanted, minimumPanelWidth), largestPanel)
            return SidePanelLayout(terminalWidth: available - handleWidth - panel, panelWidth: panel,
                                   fits: true, showsPanel: true)
        }
        // Too narrow for both minimums: the panel keeps its own, the terminal
        // takes what is left (never under the floor, checked above).
        return SidePanelLayout(terminalWidth: available - handleWidth - minimumPanelWidth,
                               panelWidth: minimumPanelWidth, fits: false, showsPanel: true)
    }
}
