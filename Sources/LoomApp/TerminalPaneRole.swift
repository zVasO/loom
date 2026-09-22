import Foundation

/// Which pane a terminal lives in. Each role remembers its own grid: the
/// review drawer and the Sessions tab are different shapes, and a session
/// born at the wrong one is resized while its agent boots.
public enum TerminalPaneRole: Sendable {
    case session
    case review

    /// The drawer's width before the user ever dragged it (GlobalPRsView).
    public static let defaultReviewDrawerWidth: CGFloat = 420

    var colsKey: String {
        switch self {
        case .session: "loom.terminal.cols"
        case .review: "loom.review.cols"
        }
    }

    var rowsKey: String {
        switch self {
        case .session: "loom.terminal.rows"
        case .review: "loom.review.rows"
        }
    }
}
