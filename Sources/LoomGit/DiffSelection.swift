import Foundation

/// Precomputed display model: parsing and row pairing happen ONCE, off the
/// main thread, when the diff loads — the view was re-running both on every
/// render (every hover, every keystroke), which crawled on large PRs.
public struct DiffFileRows: Identifiable, Equatable, Sendable {
    public let file: DiffParser.File
    /// splitRows for each hunk, same order as file.hunks.
    public let hunkRows: [[DiffParser.SplitRow]]
    public var id: String { file.path }

    public init(file: DiffParser.File, hunkRows: [[DiffParser.SplitRow]]) {
        self.file = file
        self.hunkRows = hunkRows
    }

    public static func compute(_ files: [DiffParser.File]) -> [DiffFileRows] {
        files.map { DiffFileRows(file: $0, hunkRows: $0.hunks.map(DiffParser.splitRows)) }
    }
}

/// Turning a dragged range into code. The view only knows which row the
/// cursor is over; everything else — ordering, clamping, per-file grouping,
/// diff markers — happens here, where it can be tested.
public enum DiffSelection {

    /// A row's address in the whole diff. Ordered like the document, so a
    /// selection is simply the interval between two of them — which is what
    /// makes dragging across files work.
    public struct RowID: Hashable, Comparable, Sendable {
        public let file: Int
        public let hunk: Int
        public let row: Int

        public init(file: Int, hunk: Int, row: Int) {
            self.file = file
            self.hunk = hunk
            self.row = row
        }

        public static func < (lhs: RowID, rhs: RowID) -> Bool {
            (lhs.file, lhs.hunk, lhs.row) < (rhs.file, rhs.hunk, rhs.row)
        }
    }

    /// The selected rows of ONE file: what a GitHub comment can anchor to,
    /// and what claude reads as a self-contained excerpt.
    public struct FileSpan: Equatable, Sendable {
        public let file: String
        public let firstLine: Int
        public let lastLine: Int
        public let code: String
    }

    /// The code covered by the range, grouped per (file, hunk) — line numbers
    /// are only contiguous inside a hunk, so each one stays its own span.
    /// `skipping` drops collapsed files: their rows are not on screen.
    public static func spans(in files: [DiffFileRows], from: RowID, to: RowID,
                             skipping collapsed: Set<String> = []) -> [FileSpan] {
        let lower = min(from, to), upper = max(from, to)
        var result: [FileSpan] = []
        for (fileIndex, entry) in files.enumerated() {
            guard fileIndex >= lower.file, fileIndex <= upper.file,
                  !collapsed.contains(entry.file.path) else { continue }
            for (hunkIndex, rows) in entry.hunkRows.enumerated() {
                guard let bounds = rowBounds(fileIndex: fileIndex, hunkIndex: hunkIndex,
                                             rowCount: rows.count, lower: lower, upper: upper)
                else { continue }
                if let span = span(path: entry.file.path, rows: rows, picked: bounds) {
                    result.append(span)
                }
            }
        }
        return result
    }

    /// Which rows of this hunk fall inside the selection — nil when the hunk
    /// is entirely outside it. Hunks strictly between the endpoints are taken
    /// whole; the endpoints' own hunks are clipped.
    private static func rowBounds(fileIndex: Int, hunkIndex: Int, rowCount: Int,
                                  lower: RowID, upper: RowID) -> ClosedRange<Int>? {
        guard rowCount > 0 else { return nil }
        let first = RowID(file: fileIndex, hunk: hunkIndex, row: 0)
        let last = RowID(file: fileIndex, hunk: hunkIndex, row: rowCount - 1)
        guard last >= lower, first <= upper else { return nil }
        let start = lower > first ? min(lower.row, rowCount - 1) : 0
        let end = upper < last ? max(upper.row, 0) : rowCount - 1
        guard start <= end else { return nil }
        return start...end
    }

    /// One hunk's picked rows, with +/− markers so the reader sees what
    /// changed, and the real line numbers of the new side (old for pure
    /// deletions) so a comment can anchor to them.
    private static func span(path: String, rows: [DiffParser.SplitRow],
                             picked: ClosedRange<Int>) -> FileSpan? {
        var lines: [String] = []
        var numbers: [Int] = []
        for index in picked {
            let row = rows[index]
            // A modified line pairs a deletion with an addition: BOTH sides
            // travel, or the reader only ever sees the new text and cannot
            // tell what it replaced.
            if let left = row.left, left.kind == .deletion {
                lines.append("- " + left.text)
                left.oldNumber.map { numbers.append($0) }
            }
            if let right = row.right {
                lines.append((right.kind == .addition ? "+ " : "  ") + right.text)
                right.newNumber.map { numbers.append($0) }
            }
        }
        guard !lines.isEmpty else { return nil }
        return FileSpan(file: path,
                        firstLine: numbers.min() ?? 0,
                        lastLine: numbers.max() ?? 0,
                        code: lines.joined(separator: "\n"))
    }
}
