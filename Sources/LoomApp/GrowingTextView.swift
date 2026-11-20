import AppKit
import LoomUI
import SwiftUI

/// Plain-text editing as tall as its text, with no scroll view of its own:
/// the wheel goes to the page. No smart quotes, dashes or replacements — a
/// prompt is code.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11
    var minHeight: CGFloat = 60
    /// The person typed (not a text set from outside).
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PageTextView {
        let view = PageTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 4, height: 5)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.delegate = context.coordinator
        view.string = text
        style(view)
        return view
    }

    func updateNSView(_ view: PageTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            // Set from outside (Reset to default, the model's value on show).
            view.string = text
        }
        style(view)
    }

    /// The theme's colours, at every update: the theme may have changed.
    private func style(_ view: PageTextView) {
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = NSColor(DefaultTheme.primaryText)
        view.insertionPointColor = NSColor(DefaultTheme.primaryText)
    }

    /// As tall as the text at the width offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageTextView, context: Context) -> CGSize? {
        var width = proposal.width ?? 480
        if !width.isFinite || width <= 0 { width = 480 }
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else {
            return CGSize(width: width, height: minHeight)
        }
        let inset = nsView.textContainerInset
        container.containerSize = NSSize(width: max(1, width - inset.width * 2),
                                         height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        // An empty last line (a text ending in a newline) still takes a line.
        let extra = nsView.string.hasSuffix("\n") || nsView.string.isEmpty
            ? manager.defaultLineHeight(for: nsView.font ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular))
            : 0
        return CGSize(width: width, height: max(minHeight, ceil(used + extra + inset.height * 2)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.onEdit()
        }
    }
}

/// The page scrolls, never this view: the wheel goes on to its scroll view.
final class PageTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
