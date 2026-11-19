import Foundation

/// Which pane a terminal lives in. Each role remembers its own grid: the
/// review drawer and the Sessions tab are different shapes, and a session
/// born at the wrong one is resized while its agent boots.
public enum TerminalPaneRole: Sendable {
    case session
    case review
    /// The Sessions tab with the side panel open: a narrower shape of its own,
    /// so a split never becomes the launch grid of every new session — and a
    /// stack resumed with its panel open is born at the split's grid.
    case sessionSplit
    /// The fleet panel under the Sessions view: the stack's shell, a short
    /// wide band of its own.
    case panel
    /// Mission Control: the selected session's main terminal under the
    /// table — the window's full width, the height the table leaves.
    case missionControl

    /// The drawer's width before the user ever dragged it (GlobalPRsView).
    public static let defaultReviewDrawerWidth: CGFloat = 420

    var colsKey: String {
        switch self {
        case .session: "loom.terminal.cols"
        case .review: "loom.review.cols"
        case .sessionSplit: "loom.terminal.split.cols"
        case .panel: "loom.terminal.panel.cols"
        case .missionControl: "loom.terminal.mission.cols"
        }
    }

    var rowsKey: String {
        switch self {
        case .session: "loom.terminal.rows"
        case .review: "loom.review.rows"
        case .sessionSplit: "loom.terminal.split.rows"
        case .panel: "loom.terminal.panel.rows"
        case .missionControl: "loom.terminal.mission.rows"
        }
    }

    /// Whether the pane takes the keyboard on appearing and whenever nothing
    /// owns it. A pane that sits beside another keyboard owner — the fleet
    /// panel's shell under the main terminal, Mission Control's terminal
    /// under its table — takes it on a click or when asked, never by itself.
    var claimsIdleFocus: Bool {
        switch self {
        case .session, .review, .sessionSplit: true
        case .panel, .missionControl: false
        }
    }
}
