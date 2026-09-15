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

    /// Padding between the pane's edge and the first cell. The grid origin and
    /// the cell count are both measured from it — they must not drift apart.
    public static let gridInset: CGFloat = 8

    /// How many cells fit in `size` (view padding deducted).
    public static func grid(fitting size: CGSize,
                            insets: CGFloat = gridInset * 2) -> (cols: Int, rows: Int) {
        let cell = cellSize
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        return (max(20, Int((size.width - insets) / cell.width)),
                max(4, Int((size.height - insets) / cell.height)))
    }

    /// A point in the padded content's coordinate space → a cell boundary.
    ///
    /// The row is an INDEX — floor, the row the pointer is over. The column is a
    /// BOUNDARY — rounded to the nearest, so dragging past half a glyph takes it,
    /// and a plain click lands on a single boundary, which is an EMPTY selection
    /// rather than a stray one-character highlight.
    public static func boundary(at point: CGPoint, rows: Int, cols: Int) -> (row: Int, col: Int) {
        let cell = cellSize
        guard cell.width > 0, cell.height > 0 else { return (0, 0) }
        let row = Int(((point.y - gridInset) / cell.height).rounded(.down))
        let col = Int(((point.x - gridInset) / cell.width).rounded())
        return (min(max(0, row), max(0, rows - 1)), min(max(0, col), max(0, cols)))
    }

    /// The cell the pointer is INSIDE, for word and line selection. A boundary
    /// would round up on the right half of a glyph and pick the next word.
    public static func cellColumn(atX x: CGFloat, cols: Int) -> Int {
        let cell = cellSize
        guard cell.width > 0 else { return 0 }
        return min(max(0, Int(((x - gridInset) / cell.width).rounded(.down))), max(0, cols - 1))
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
    @Binding public var selection: TerminalSelection
    /// How many characters copy-on-select put on the pasteboard.
    private let onCopied: ((Int) -> Void)?

    public init(screen: TerminalScreen, history: [TerminalLine] = [], historyBase: Int = 0,
                selection: Binding<TerminalSelection> = .constant(.empty),
                onCopied: ((Int) -> Void)? = nil) {
        self.screen = screen
        self.history = history
        self.historyBase = historyBase
        self._selection = selection
        self.onCopied = onCopied
    }

    /// One press, kept only to tell a double click from two single ones.
    private struct Press {
        let at: TimeInterval
        let row: Int
        let col: Int
        let count: Int
    }

    @State private var dragging = false
    @State private var lastPress: Press?

    private static let space = "loom.terminal"

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
            .padding(TerminalMetrics.gridInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The selection layer sits ON TOP: cells carry ANSI background
            // colours painted by Text itself, and a highlight behind them would
            // vanish on exactly the lines people want to copy. An overlay also
            // leaves the measured size alone, so it cannot move the bottom anchor.
            .overlay(alignment: .topLeading) { selectionLayer }
            // Named HERE, on the padded content: the drag then reports positions
            // already free of the scroll offset, and `- gridInset` is the only
            // correction left.
            .coordinateSpace(name: Self.space)
            .contentShape(Rectangle())
            .gesture(selectionDrag)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.visible)   // a terminal that scrolls should look like it
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(DefaultTheme.contentBackground)
    }

    // MARK: - Selection

    private var contentRows: Int { history.count + screen.lines.count }

    private func contentLine(_ index: Int) -> TerminalLine? {
        guard index >= 0 else { return nil }
        if index < history.count { return history[index] }
        let onScreen = index - history.count
        return onScreen < screen.lines.count ? screen.lines[onScreen] : nil
    }

    /// Consecutive rows sharing one column range become ONE rectangle: a linear
    /// selection is at most three (partial head, full body, partial tail), a block
    /// exactly one — instead of a shape per row.
    private var selectionRects: [CGRect] {
        guard selection.isActive, let rows = selection.rowRange else { return [] }
        let cell = TerminalMetrics.cellSize
        let inset = TerminalMetrics.gridInset
        let cols = screen.geometry.cols
        var rects: [CGRect] = []
        var run: (first: Int, last: Int, columns: Range<Int>)?
        func flush() {
            guard let run else { return }
            rects.append(CGRect(x: inset + CGFloat(run.columns.lowerBound) * cell.width,
                                y: inset + CGFloat(run.first - historyBase) * cell.height,
                                width: CGFloat(run.columns.count) * cell.width,
                                height: CGFloat(run.last - run.first + 1) * cell.height))
        }
        for row in rows {
            guard let columns = selection.columnRange(forRow: row, cols: cols) else { continue }
            if let current = run, current.columns == columns, current.last + 1 == row {
                run = (current.first, row, columns)
            } else {
                flush()
                run = (row, row, columns)
            }
        }
        flush()
        return rects
    }

    private var selectionLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(selectionRects.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .fill(DefaultTheme.accent.opacity(0.25))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !dragging {
                    dragging = true
                    beginPress(at: value.location)
                    return
                }
                // Read live: pressing ⌥ MID-drag must flip to a block, the way
                // every emulator behaves. A captured event could not tell us.
                guard lastPress?.count == 1 else { return }
                selection.mode = NSEvent.modifierFlags.contains(.option) ? .block : .linear
                selection.head = position(at: value.location)
            }
            .onEnded { _ in
                dragging = false
                guard selection.isActive else { return }
                selection.capturedText = selection.text(history: history,
                                                        historyBase: historyBase,
                                                        screen: screen)
                if UserDefaults.standard.bool(forKey: "loom.terminal.copyOnSelect"),
                   let text = selection.capturedText, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onCopied?(text.count)
                }
            }
    }

    private func position(at point: CGPoint) -> TerminalPosition {
        let boundary = TerminalMetrics.boundary(at: point, rows: contentRows,
                                                cols: screen.geometry.cols)
        return TerminalPosition(row: historyBase + boundary.row, col: boundary.col)
    }

    /// Mouse-down: word and line selection happen HERE, not on release — that is
    /// the right feel, and it is also the only moment a click count means anything.
    private func beginPress(at point: CGPoint) {
        let cols = screen.geometry.cols
        let boundary = TerminalMetrics.boundary(at: point, rows: contentRows, cols: cols)
        let now = Date.timeIntervalSinceReferenceDate
        let count = TerminalClick.count(
            previous: lastPress?.count ?? 0,
            sameCell: lastPress.map { $0.row == boundary.row && $0.col == boundary.col } ?? false,
            elapsed: now - (lastPress?.at ?? 0),
            interval: NSEvent.doubleClickInterval)
        lastPress = Press(at: now, row: boundary.row, col: boundary.col, count: count)
        let row = historyBase + boundary.row

        switch count {
        case 2:
            let cells = contentLine(boundary.row)?.cells ?? []
            let word = TerminalWord.range(in: cells,
                                          at: TerminalMetrics.cellColumn(atX: point.x, cols: cols))
            selection = TerminalSelection(anchor: TerminalPosition(row: row, col: word.lowerBound),
                                          head: TerminalPosition(row: row, col: word.upperBound))
        case 3:
            selection = TerminalSelection(anchor: TerminalPosition(row: row, col: 0),
                                          head: TerminalPosition(row: row, col: cols))
        default:
            let flags = NSEvent.modifierFlags
            let head = TerminalPosition(row: row, col: boundary.col)
            // ⇧ keeps the anchor where it was: the selection grows from it.
            let anchor = flags.contains(.shift) ? (selection.anchor ?? head) : head
            selection = TerminalSelection(anchor: anchor, head: head,
                                          mode: flags.contains(.option) ? .block : .linear)
        }
    }

    // MARK: - Rows

    /// `cursorCol`: the terminal cursor, drawn by US (the agent only paints
    /// its cells) — without it, one would type blind into its field.
    private func row(_ line: TerminalLine, height: CGFloat, cursorCol: Int? = nil) -> some View {
        Text(attributed(line))
            .font(.system(size: TerminalMetrics.fontSize, design: .monospaced))
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
