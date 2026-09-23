import Testing
import Foundation
import LoomGit

/// Regression guard for the diff products (audit 2026-09-22, P0-4 and
/// P1-9): a 5,000-line PR is parsed and paired once, and the rows the view
/// compares per frame are values whose equality is cheap. The bound is the
/// audit's target widened 10× in debug, 3× in release.
@Suite("PERF PROBES — diff rows")
struct DiffRowsProbes {

    private static let slack: Double = {
        #if DEBUG
        return 10
        #else
        return 3
        #endif
    }()

    /// Ten files, five hunks each, a hundred lines per hunk: 5,000 lines,
    /// one deletion and one addition in every five.
    static func syntheticDiff() -> String {
        var text = ""
        for file in 0..<10 {
            text += "diff --git a/src/file\(file).swift b/src/file\(file).swift\n"
            text += "--- a/src/file\(file).swift\n+++ b/src/file\(file).swift\n"
            for hunk in 0..<5 {
                let start = 1 + hunk * 120
                text += "@@ -\(start),80 +\(start),80 @@ func section\(hunk)()\n"
                for line in 0..<100 {
                    switch line % 5 {
                    case 0: text += "-    let old\(line) = compute(\(line))\n"
                    case 1: text += "+    let new\(line) = compute(\(line), cached: true)\n"
                    default: text += "     context line \(line) of hunk \(hunk)\n"
                    }
                }
            }
        }
        return text
    }

    @Test("a 5,000-line diff parses and pairs once; comparing its rows is cheap")
    func computeAndCompare() {
        let diff = Self.syntheticDiff()
        let clock = ContinuousClock()
        let start = clock.now
        let files = DiffParser.parse(diff)
        let rows = DiffFileRows.compute(files)
        let computed = clock.now - start
        print("PERF parse + compute over 5,000 lines: \(computed)")
        #expect(files.count == 10)
        #expect(rows.count == 10)
        let lineCount = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } }
        #expect(lineCount == 5000)

        // What the view pays per frame: a row compared with its previous value.
        let sample = Array(rows.flatMap { $0.hunkRows.flatMap { $0 } }.prefix(100))
        let again = Array(DiffFileRows.compute(files).flatMap { $0.hunkRows.flatMap { $0 } }.prefix(100))
        let compareStart = clock.now
        var equal = 0
        for (lhs, rhs) in zip(sample, again) where lhs == rhs { equal += 1 }
        let compared = clock.now - compareStart
        print("PERF 100 split-row comparisons: \(compared)")
        #expect(equal == 100)
        #expect(compared < .milliseconds(1 * Self.slack),
                "100 row comparisons took \(compared): rows are no longer cheap values")
    }
}
