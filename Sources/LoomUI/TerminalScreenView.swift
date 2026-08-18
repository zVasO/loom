import AppKit
import LoomTerminal
import SwiftUI

/// Terminal grid metrics: the view and the PTY must speak the SAME
/// geometry (TRM-02) — this is where a point becomes a cell.
public enum TerminalMetrics {
    public static let fontSize: CGFloat = 12.5
    static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    /// Measured on a 100-character PROBE via TextKit: a mono glyph's advance
    /// is fractional (≈7.52 pt at 12.5) — measuring it on a single character
    /// rounds, and the error ×100 columns had the PTY announcing more columns
    /// than the view displays: text clipped on the right.
    public static let cellSize: CGSize = {
        let probe = NSAttributedString(string: String(repeating: "0", count: 100),
                                       attributes: [.font: nsFont])
        let measured = probe.size()
        return CGSize(width: measured.width / 100,
                      height: ceil(measured.height) + 1)
    }()

    /// How many cells fit in `size` (view padding deducted).
    public static func grid(fitting size: CGSize, insets: CGFloat = 16) -> (cols: Int, rows: Int) {
        let cell = cellSize
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        return (max(20, Int((size.width - insets) / cell.width)),
                max(4, Int((size.height - insets) / cell.height)))
    }
}

/// Renders a `TerminalScreen` — the view pulls values, never the engine
/// (ADR-0007/0008). The grid matches the PTY geometry exactly:
/// no scrolling, no wrapping — the agent draws for the real size.
public struct TerminalScreenView: View {
    public let screen: TerminalScreen
    public let history: [TerminalLine]
    /// Absolute scrollback index of history[0] — STABLE row identity, so the
    /// diff skips untouched history lines instead of re-checking 400 per frame.
    public let historyBase: Int
    /// Pinned to the bottom during the stream; scrolling up into history unpins,
    /// coming back down re-pins (tracks the scroll geometry).
    @State private var pinnedToBottom = true

    public init(screen: TerminalScreen, history: [TerminalLine] = [], historyBase: Int = 0) {
        self.screen = screen
        self.history = history
        self.historyBase = historyBase
    }

    public var body: some View {
        let cell = TerminalMetrics.cellSize
        // Auto-follow triggers on CONTENT, not on repaint: claude redraws its
        // spinner several times a second even when idle, and snapping to the
        // bottom on every revision made scrolling up a race the user always
        // lost — the wheel moved 3-10 pt per event, the next repaint yanked
        // the view back before the 24 pt unpin threshold could be crossed.
        let totalRows = history.count + screen.lines.count
        ScrollViewReader { proxy in
            GeometryReader { container in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.offset) { index, line in
                            row(line, height: cell.height)
                                .id(historyBase + index)
                        }
                        ForEach(Array(screen.lines.enumerated()), id: \.offset) { index, line in
                            row(line, height: cell.height,
                                cursorCol: index == screen.cursor.row ? screen.cursor.col : nil)
                        }
                        Color.clear.frame(height: 0).id("bas")   // anchor marker: zero height, otherwise it clips the top
                    }
                    .padding(8)
                    // Portable bottom tracking (works on macOS 14 too, which
                    // previously fell back to "always pinned" — unscrollable):
                    // distance between the content's bottom edge and the
                    // viewport's bottom edge, published as a preference.
                    .background(GeometryReader { content in
                        Color.clear.preference(
                            key: BottomDistanceKey.self,
                            value: content.frame(in: .named("terminal.scroll")).maxY
                                   - container.size.height)
                    })
                }
                .coordinateSpace(name: "terminal.scroll")
                .onPreferenceChange(BottomDistanceKey.self) { distance in
                    let atBottom = distance <= 24
                    if pinnedToBottom != atBottom { pinnedToBottom = atBottom }
                }
            }
            // The user always wins the race: the FIRST upward wheel tick over
            // the terminal unpins, before any snap can fire.
            .background(ScrollWheelUpSensor { pinnedToBottom = false })
            .onChange(of: totalRows) {
                if pinnedToBottom { proxy.scrollTo("bas", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bas", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(DefaultTheme.contentBackground)
    }

    /// `cursorCol`: the terminal cursor, drawn by US (the agent only paints
    /// its cells) — without it, one would type blind into its field.
    private func row(_ line: TerminalLine, height: CGFloat, cursorCol: Int? = nil) -> some View {
        Text(attributed(line))
            .font(.system(size: TerminalMetrics.fontSize, design: .monospaced))
            .textSelection(.enabled)   // mouse selection + ⌘C
            .frame(height: height, alignment: .leading)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .topLeading) {
                if let col = cursorCol {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DefaultTheme.accent.opacity(0.55))
                        .frame(width: TerminalMetrics.cellSize.width, height: height - 2)
                        .offset(x: CGFloat(col) * TerminalMetrics.cellSize.width, y: 1)
                }
            }
    }

    /// P0 perf: consecutive same-style cells become ONE attributed piece —
    /// measured 18× cheaper than a per-cell append (most lines are 1-3 runs).
    private func attributed(_ line: TerminalLine) -> AttributedString {
        var result = AttributedString()
        let cells = line.cells
        var runStart = 0
        while runStart < cells.count {
            let style = cells[runStart].style
            var runEnd = runStart + 1
            while runEnd < cells.count, cells[runEnd].style == style { runEnd += 1 }
            var piece = AttributedString(String(cells[runStart..<runEnd].map(\.character)))
            piece.foregroundColor = DefaultTheme.terminalColor(style.foreground, isBackground: false)
            let background = DefaultTheme.terminalColor(style.background, isBackground: true)
            if background != .clear { piece.backgroundColor = background }
            if style.attributes.contains(.bold) {
                piece.font = .system(size: TerminalMetrics.fontSize, design: .monospaced).bold()
            }
            result.append(piece)
            runStart = runEnd
        }
        return result
    }
}


/// Distance between the scroll content's bottom edge and the viewport's
/// bottom edge — ≤ 0 means fully scrolled down.
private struct BottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Invisible AppKit sensor: fires on upward scroll-wheel ticks INSIDE its own
/// bounds. Wheel events land in the NSScrollView, never in SwiftUI gestures —
/// a local event monitor is the only reliable tap, and the bounds check keeps
/// one terminal pane from unpinning another.
private struct ScrollWheelUpSensor: NSViewRepresentable {
    let onScrollUp: () -> Void

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        view.onScrollUp = onScrollUp
        return view
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onScrollUp = onScrollUp
    }

    final class SensorView: NSView {
        var onScrollUp: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    guard let self, let window = self.window,
                          event.window === window else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point), event.scrollingDeltaY > 0 {
                        self.onScrollUp?()
                    }
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
