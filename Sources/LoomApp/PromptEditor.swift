import AppKit
import LoomUI
import SwiftUI

/// A prompt in the Settings page. A long one is folded to its first lines,
/// unfolded with a click; unfolded, it is as tall as its text. It never
/// scrolls on its own: a TextEditor scrolls inside the page and, under the
/// pointer, took the page's scroll for itself.
struct PromptEditor: View {
    @Binding var text: String
    /// The lines shown folded; a text this short or shorter is never folded.
    var foldedLines = 4
    var minHeight: CGFloat = 60
    var fontSize: CGFloat = 11
    @State private var expanded = false

    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var foldable: Bool { lineCount > foldedLines }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if foldable && !expanded {
                folded
            } else {
                GrowingTextView(text: $text, fontSize: fontSize, minHeight: minHeight,
                                onEdit: { if foldable { expanded = true } })
                    .padding(.horizontal, 4).padding(.vertical, 4)
                if foldable {
                    footer("Fold", systemImage: "chevron.up") { expanded = false }
                }
            }
        }
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    /// The first lines, and how many there are.
    private var folded: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(foldedLines).joined(separator: "\n"))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(DefaultTheme.secondaryText)
                .lineLimit(foldedLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.top, 9).padding(.bottom, 4)
            footer("Show all · \(lineCount) lines", systemImage: "chevron.down") { expanded = true }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded = true }
        .help("Click to edit")
    }

    private func footer(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DefaultTheme.accent)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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
