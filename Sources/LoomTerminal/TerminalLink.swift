import Foundation
import LoomCore

/// A link found on screen, and where it is drawn. A soft-wrapped URL is ONE
/// link spanning several rows — that is the whole reason segments exist.
public struct TerminalLink: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let row: Int
        public let columns: Range<Int>
        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    public let target: String
    public let segments: [Segment]
    /// An OSC 8 hyperlink, as opposed to a URL recognised in plain text.
    public let isExplicit: Bool
}

/// Seam: from a cell position to the link under it. Pure — the view supplies
/// the rows it is already rendering, and gets back what to underline and open.
public enum TerminalLinks {
    /// `row` indexes `lines`; `column` indexes that line's cells.
    public static func link(in lines: [TerminalLine], row: Int, column: Int) -> TerminalLink? {
        link(rows: lines.count,
             line: { lines.indices.contains($0) ? lines[$0] : nil },
             row: row, column: column)
    }

    /// Rows are read through an accessor, never collected: the caller renders
    /// screen and scrollback from two separate arrays, and hover asks on every
    /// mouse move.
    public static func link(rows: Int, line: (Int) -> TerminalLine?,
                            row: Int, column: Int) -> TerminalLink? {
        guard let hovered = line(row), hovered.cells.indices.contains(column) else { return nil }
        return explicit(in: line, row: row, column: column, rows: rows)
            ?? implicit(in: line, row: row, column: column, rows: rows)
    }

    // MARK: - OSC 8

    private static func explicit(in line: (Int) -> TerminalLine?,
                                 row: Int, column: Int, rows: Int) -> TerminalLink? {
        guard let target = line(row)?.cells[column].link else { return nil }
        var segments: [TerminalLink.Segment] = []
        for candidate in paragraph(of: row, in: line, rows: rows) {
            guard let cells = line(candidate)?.cells else { continue }
            guard let first = cells.firstIndex(where: { $0.link == target }) else { continue }
            let last = cells.lastIndex(where: { $0.link == target }) ?? first
            segments.append(TerminalLink.Segment(row: candidate, columns: first..<(last + 1)))
        }
        return TerminalLink(target: target, segments: segments, isExplicit: true)
    }

    // MARK: - Plain text

    private static func implicit(in line: (Int) -> TerminalLine?,
                                 row: Int, column: Int, rows: Int) -> TerminalLink? {
        let joined = join(paragraph(of: row, in: line, rows: rows), in: line)
        guard let cursor = joined.positions.firstIndex(where: { $0.row == row && $0.column == column })
        else { return nil }
        guard let range = BareURL.ranges(in: joined.characters).first(where: { $0.contains(cursor) })
        else { return nil }
        return TerminalLink(target: String(joined.characters[range]),
                            segments: segments(of: range, in: joined.positions),
                            isExplicit: false)
    }

    /// Rows of the logical line `row` belongs to: `isWrapped` marks a row as
    /// the continuation of the one above, so the run extends both ways.
    private static func paragraph(of row: Int, in line: (Int) -> TerminalLine?,
                                  rows: Int) -> ClosedRange<Int> {
        var first = row
        while first > 0, line(first)?.isWrapped == true { first -= 1 }
        var last = row
        while last + 1 < rows, line(last + 1)?.isWrapped == true { last += 1 }
        return first...last
    }

    private struct Joined {
        var characters: [Character] = []
        /// Same indices as `characters`: where each one is drawn.
        var positions: [(row: Int, column: Int)] = []
    }

    /// The engine pads every row to the full grid width. Those trailing spaces
    /// must not land between a wrapped URL's halves, so each row is trimmed.
    private static func join(_ rows: ClosedRange<Int>, in line: (Int) -> TerminalLine?) -> Joined {
        var joined = Joined()
        for row in rows {
            guard let cells = line(row)?.cells else { continue }
            let end = cells.lastIndex { $0.character != " " }.map { $0 + 1 } ?? 0
            for column in 0..<end {
                joined.characters.append(cells[column].character)
                joined.positions.append((row: row, column: column))
            }
        }
        return joined
    }

    /// Consecutive positions on one row become a single drawable segment.
    private static func segments(of range: Range<Int>,
                                 in positions: [(row: Int, column: Int)]) -> [TerminalLink.Segment] {
        var segments: [TerminalLink.Segment] = []
        for index in range {
            let position = positions[index]
            if let last = segments.last, last.row == position.row,
               last.columns.upperBound == position.column {
                segments[segments.count - 1] = TerminalLink.Segment(
                    row: last.row, columns: last.columns.lowerBound..<(position.column + 1))
            } else {
                segments.append(TerminalLink.Segment(row: position.row,
                                                     columns: position.column..<(position.column + 1)))
            }
        }
        return segments
    }
}
