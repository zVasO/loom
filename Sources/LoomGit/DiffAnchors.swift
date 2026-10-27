import Foundation

extension DiffParser {

    /// Whether GitHub takes a review comment on these lines: the file is in
    /// the diff, and both ends of the range sit in ONE of its hunks, on that
    /// side — RIGHT counts the new file's lines (context and additions),
    /// LEFT the old one's (context and deletions). Anything else is refused
    /// with a 422 and would sink the whole review with it.
    public static func canAnchor(path: String, firstLine: Int, lastLine: Int, side: String,
                                 in files: [File]) -> Bool {
        guard firstLine > 0, firstLine <= lastLine,
              let file = files.first(where: { $0.path == path }) else { return false }
        let left = side.uppercased() == "LEFT"
        return file.hunks.contains { hunk in
            let numbers = Set(hunk.lines.compactMap { left ? $0.oldNumber : $0.newNumber })
            return numbers.contains(firstLine) && numbers.contains(lastLine)
        }
    }
}
