import Foundation

/// v4 PR review — turns a unified diff into structure the split view can
/// render (GitHub-style side-by-side). Pure functions, contract-tested.
public enum DiffParser {

    public enum LineKind: Sendable, Equatable {
        case context, addition, deletion
    }

    public struct Line: Sendable, Equatable {
        public let kind: LineKind
        public let text: String
        /// Line number in the OLD file (nil for additions).
        public let oldNumber: Int?
        /// Line number in the NEW file (nil for deletions).
        public let newNumber: Int?
    }

    public struct Hunk: Sendable, Equatable {
        public let header: String
        public let lines: [Line]
    }

    public struct File: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public let path: String
        public let hunks: [Hunk]
        public var additions: Int { hunks.flatMap(\.lines).count { $0.kind == .addition } }
        public var deletions: Int { hunks.flatMap(\.lines).count { $0.kind == .deletion } }
    }

    /// One row of the side-by-side view: old on the left, new on the right.
    public struct SplitRow: Sendable, Equatable {
        public let left: Line?
        public let right: Line?
    }

    public static func parse(_ text: String) -> [File] {
        var files: [File] = []
        var path: String?
        var hunks: [Hunk] = []
        var hunkHeader: String?
        var hunkLines: [Line] = []
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let header = hunkHeader {
                hunks.append(Hunk(header: header, lines: hunkLines))
            }
            hunkHeader = nil
            hunkLines = []
        }

        func closeFile() {
            closeHunk()
            if let path {
                files.append(File(path: path, hunks: hunks))
            }
            path = nil
            hunks = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                // "diff --git a/X b/X" → X (the b/ side: the new name).
                if let range = line.range(of: " b/") {
                    path = String(line[range.upperBound...])
                }
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                hunkHeader = line
                // "@@ -old,count +new,count @@ …"
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                }
                continue
            }
            guard hunkHeader != nil else { continue }   // metadata (index, ---, +++)
            if line.hasPrefix("+") {
                hunkLines.append(Line(kind: .addition, text: String(line.dropFirst()),
                                      oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunkLines.append(Line(kind: .deletion, text: String(line.dropFirst()),
                                      oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                hunkLines.append(Line(kind: .context, text: String(line.dropFirst()),
                                      oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
            // "\\ No newline at end of file" and anything else: ignored.
        }
        closeFile()
        return files
    }

    /// GitHub's split alignment: a run of deletions pairs with the following
    /// run of additions, row by row; the longer run overflows one-sided.
    public static func splitRows(_ hunk: Hunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var deletions: [Line] = []
        var additions: [Line] = []

        func flush() {
            for index in 0..<max(deletions.count, additions.count) {
                rows.append(SplitRow(left: index < deletions.count ? deletions[index] : nil,
                                     right: index < additions.count ? additions[index] : nil))
            }
            deletions = []
            additions = []
        }

        for line in hunk.lines {
            switch line.kind {
            case .deletion: deletions.append(line)
            case .addition: additions.append(line)
            case .context:
                flush()
                rows.append(SplitRow(left: line, right: line))
            }
        }
        flush()
        return rows
    }
}
