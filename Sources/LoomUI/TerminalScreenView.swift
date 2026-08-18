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
    public init(screen: TerminalScreen, history: [TerminalLine] = [], historyBase: Int = 0) {
        self.screen = screen
        self.history = history
        self.historyBase = historyBase
    }

    public var body: some View {
        let cell = TerminalMetrics.cellSize
        // NO manual follow-the-tail machinery. Every previous attempt (scrollTo
        // on each revision, then a wheel sensor unpinning it) fought the user
        // for control of the scroll position — and the user lost. SwiftUI's own
        // bottom anchor keeps new output in view AND leaves the wheel alone.
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
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.visible)   // a terminal that scrolls should look like it
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
