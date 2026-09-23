import Testing
import Foundation
import LoomTerminal
@testable import LoomUI

/// Regression guard for the view-side row build (audit 2026-09-22, P0-1):
/// consecutive same-style cells become one attributed piece, so a row of
/// eight coloured runs costs eight appends, not a hundred. The bound is
/// the audit's target widened 10× in debug, 3× in release.
@MainActor
@Suite("PERF PROBES — terminal rows")
struct TerminalRowProbes {

    private static let slack: Double = {
        #if DEBUG
        return 10
        #else
        return 3
        #endif
    }()

    @Test("forty rows of eight coloured runs and bold pieces build in a millisecond")
    func attributedCost() {
        let lines: [TerminalLine] = (0..<40).map { row in
            let cells = (0..<96).map { col -> TerminalCell in
                let run = col / 12
                let style = CellStyle(foreground: .ansi(UInt8(run + 1)),
                                      attributes: run % 2 == 0 ? [.bold] : [])
                let scalar = UnicodeScalar(65 + ((col + row) % 26))!
                return TerminalCell(character: Character(scalar), style: style)
            }
            return TerminalLine(cells: cells)
        }
        // Prime what is not row work: the lazy statics (the fonts, the ANSI
        // palette) and Foundation's first use of the SwiftUI attribute keys.
        _ = TerminalRow.attributed(lines[0])
        let clock = ContinuousClock()
        var built: [AttributedString] = []
        built.reserveCapacity(lines.count)
        // Best of three: a one-shot timing shares the machine with every
        // other suite `swift test` runs alongside.
        var elapsed: Duration = .seconds(1)
        for _ in 0..<3 {
            built.removeAll(keepingCapacity: true)
            let start = clock.now
            for line in lines { built.append(TerminalRow.attributed(line)) }
            elapsed = min(elapsed, clock.now - start)
        }
        let characters = built.reduce(0) { $0 + $1.characters.count }
        print("PERF TerminalRow.attributed x40 (8 runs each), best of 3: \(elapsed)")
        #expect(characters == 40 * 96)
        #expect(elapsed < .milliseconds(1 * Self.slack),
                "40 rows of 8 runs took \(elapsed): the run batching is gone")
    }
}
