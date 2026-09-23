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
        let clock = ContinuousClock()
        let start = clock.now
        var characters = 0
        for line in lines { characters += TerminalRow.attributed(line).characters.count }
        let elapsed = clock.now - start
        print("PERF TerminalRow.attributed x40 (8 runs each): \(elapsed)")
        #expect(characters == 40 * 96)
        #expect(elapsed < .milliseconds(1 * Self.slack),
                "40 rows of 8 runs took \(elapsed): the run batching is gone")
    }
}
