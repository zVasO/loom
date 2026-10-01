import CoreGraphics

/// When a terminal pane's measured size becomes a PTY resize (TRM-02) —
/// pure, so the rules that keep claude from repainting its conversation for
/// nothing are pinned by tests rather than buried in a view.
public enum TerminalFitPolicy {

    public enum Decision: Equatable, Sendable {
        /// Nothing to apply: the size is not a real one, or fitting is on hold.
        case skip
        /// The first fit of a surface in this pane: no reason to wait.
        case immediate
        /// Wait for the size to settle: every resize that reaches the PTY makes
        /// the agent repaint its whole conversation, and a slide that resized
        /// it three times left three copies in the scrollback.
        case debounced
    }

    /// Below this the surface refuses the geometry (20 × 5 cells), and the
    /// first layout pass measures zero.
    public static let minimumPaneSize = CGSize(width: 160, height: 60)

    /// Outlasts a layout animation on purpose (see `.debounced`).
    public static let debounce: Duration = .milliseconds(220)

    /// - Parameter suspended: a divider is being dragged — the terminal keeps
    ///   its grid until the drag ends, then fits once.
    public static func decide(size: CGSize, suspended: Bool, isFirstFitForSurface: Bool) -> Decision {
        if suspended { return .skip }
        guard size.width >= minimumPaneSize.width, size.height >= minimumPaneSize.height else {
            return .skip
        }
        return isFirstFitForSurface ? .immediate : .debounced
    }
}
