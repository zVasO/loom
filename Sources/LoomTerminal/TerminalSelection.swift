import Foundation

// Turning "the user dragged from here to there" into text. The view only knows
// which cell the pointer is over; ordering, clipping, block geometry and the
// trailing-space trim all happen here, where they can be tested.

/// A cell address. `row` is ABSOLUTE — counted from the start of the scrollback,
/// like `historyBase` — so a selection survives new output pushing the screen up.
///
/// `col` is a BOUNDARY between cells, not a cell: it ranges over `0...cols`. That
/// is what makes a plain click (anchor == head) an EMPTY selection instead of a
/// stray one-character highlight every time the user clicks to focus the terminal.
public struct TerminalPosition: Hashable, Comparable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (lhs: TerminalPosition, rhs: TerminalPosition) -> Bool {
        (lhs.row, lhs.col) < (rhs.row, rhs.col)
    }
}

public struct TerminalSelection: Equatable, Sendable {

    /// `block` is the ⌥ drag: a rectangle of columns, for pulling one column out
    /// of a table. The agent draws a lot of those.
    public enum Mode: Sendable {
        case linear
        case block
    }

    public var anchor: TerminalPosition?
    public var head: TerminalPosition?
    public var mode: Mode
    /// Resolved when the drag ENDS, never at ⌘C: the agent repaints its viewport
    /// several times a second, so text read later is not the text that was framed.
    public var capturedText: String?

    public static let empty = TerminalSelection()

    public init(anchor: TerminalPosition? = nil,
                head: TerminalPosition? = nil,
                mode: Mode = .linear,
                capturedText: String? = nil) {
        self.anchor = anchor
        self.head = head
        self.mode = mode
        self.capturedText = capturedText
    }

    /// Document order, so a drag upwards reads the same as a drag downwards.
    /// Meaningless for `block`, which needs its corners, not its endpoints.
    public var ordered: (from: TerminalPosition, to: TerminalPosition)? {
        guard let anchor, let head else { return nil }
        return (min(anchor, head), max(anchor, head))
    }

    public var rowRange: ClosedRange<Int>? {
        guard let anchor, let head else { return nil }
        return min(anchor.row, head.row)...max(anchor.row, head.row)
    }

    public var isActive: Bool {
        guard let anchor, let head else { return false }
        switch mode {
        case .linear: return anchor != head
        case .block: return anchor.col != head.col
        }
    }

    /// The columns highlighted on one absolute row, or `nil` if the row is outside
    /// the selection. Half-open, because columns are boundaries.
    public func columnRange(forRow row: Int, cols: Int) -> Range<Int>? {
        guard isActive, let anchor, let head, let rows = rowRange, rows.contains(row) else {
            return nil
        }
        switch mode {
        case .block:
            return clamp(min(anchor.col, head.col)..<max(anchor.col, head.col), to: cols)
        case .linear:
            guard let (from, to) = ordered else { return nil }
            return clamp((row == from.row ? from.col : 0)..<(row == to.row ? to.col : cols),
                         to: cols)
        }
    }

    /// The selected text, ready for the pasteboard.
    public func text(history: [TerminalLine],
                     historyBase: Int,
                     screen: TerminalScreen) -> String? {
        guard isActive, let rows = rowRange else { return nil }
        let cols = screen.geometry.cols
        var lines: [String] = []
        for row in rows {
            guard let range = columnRange(forRow: row, cols: cols),
                  let line = line(at: row, history: history, historyBase: historyBase,
                                  screen: screen)
            else { continue }
            lines.append(Self.piece(of: line, in: range))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The engine pads every row to the full grid width with spaces, so a naive
    /// copy drags a hundred of them behind each line. They are cut only once the
    /// selection reaches past the row's last real character — inside it, spaces
    /// are exactly what the user framed.
    private static func piece(of line: TerminalLine, in range: Range<Int>) -> String {
        let cells = line.cells
        let lower = min(range.lowerBound, cells.count)
        let upper = min(range.upperBound, cells.count)
        let text = String(cells[lower..<upper].map(\.character))
        let contentEnd = cells.lastIndex { $0.character != " " }.map { $0 + 1 } ?? 0
        guard range.upperBound >= contentEnd else { return text }
        var trimmed = text
        while trimmed.last == " " { trimmed.removeLast() }
        return trimmed
    }

    /// Everything the pane holds — history then screen — for ⌘⇧A. Carries its own
    /// text, like a finished drag does.
    public static func all(history: [TerminalLine],
                           historyBase: Int,
                           screen: TerminalScreen) -> TerminalSelection {
        let rows = history.count + screen.lines.count
        guard rows > 0 else { return .empty }
        var selection = TerminalSelection(
            anchor: TerminalPosition(row: historyBase, col: 0),
            head: TerminalPosition(row: historyBase + rows - 1, col: screen.geometry.cols))
        selection.capturedText = selection.text(history: history, historyBase: historyBase,
                                                screen: screen)
        return selection
    }

    /// `nil` once a row has scrolled out of the window the surface keeps: the
    /// selection outlives the 400 lines of history it was anchored in.
    private func line(at row: Int,
                      history: [TerminalLine],
                      historyBase: Int,
                      screen: TerminalScreen) -> TerminalLine? {
        let index = row - historyBase
        guard index >= 0 else { return nil }
        if index < history.count { return history[index] }
        let onScreen = index - history.count
        return onScreen < screen.lines.count ? screen.lines[onScreen] : nil
    }

    private func clamp(_ range: Range<Int>, to cols: Int) -> Range<Int>? {
        let lower = max(0, min(range.lowerBound, cols))
        let upper = max(lower, min(range.upperBound, cols))
        return lower < upper ? lower..<upper : nil
    }
}

/// Word boundaries for a double click. Paths and URLs must come out whole —
/// selecting `foo-bar.txt` or a URL in one gesture is the point of the gesture —
/// so the separators they are built from count as word characters.
public enum TerminalWord {
    private static let joiners: Set<Character> = ["_", "-", ".", "/", "~", ":"]

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || joiners.contains(character)
    }

    /// The run around `cell`, whichever kind it is: a click on blanks selects the
    /// run of blanks, like every text view does.
    public static func range(in cells: [TerminalCell], at cell: Int) -> Range<Int> {
        guard !cells.isEmpty else { return 0..<0 }
        let index = min(max(0, cell), cells.count - 1)
        let wanted = isWordCharacter(cells[index].character)
        var lower = index
        while lower > 0, isWordCharacter(cells[lower - 1].character) == wanted { lower -= 1 }
        var upper = index + 1
        while upper < cells.count, isWordCharacter(cells[upper].character) == wanted { upper += 1 }
        return lower..<upper
    }
}

/// Click counting, done by us: by the time SwiftUI runs a drag callback,
/// `NSApp.currentEvent` is not reliably the mouse-down that started it.
public enum TerminalClick {
    /// Wraps back to 1 past the triple click, like AppKit does.
    public static func count(previous: Int,
                             sameCell: Bool,
                             elapsed: TimeInterval,
                             interval: TimeInterval) -> Int {
        guard sameCell, elapsed <= interval, previous >= 1, previous < 3 else { return 1 }
        return previous + 1
    }

    /// Did that press/release mean the PROGRAM, or did it mean a selection? The
    /// cell alone would say "tap" to a drag that wandered off and came back, so
    /// the travelled distance decides alongside it.
    public static func isTap(from down: CGPoint,
                             to up: CGPoint,
                             sameCell: Bool,
                             slop: CGFloat) -> Bool {
        guard sameCell else { return false }
        return hypot(up.x - down.x, up.y - down.y) <= slop
    }
}
