import Testing
import LoomCore
import Foundation
@testable import LoomTerminal

@Suite("PERF PROBES", .serialized)
struct PerfProbes {

    @Test("frame production cost: snapshot + historyTail(400)")
    func frameCost() {
        let engine = SwiftTermEngine(geometry: TerminalGeometry(cols: 100, rows: 40),
                                     scrollback: 10_000)
        // Fill with 5000 lines of realistic output.
        for i in 0..<5000 {
            engine.feed(ArraySlice(Array("line \(i): the quick brown fox jumps over the lazy dog 0123456789\r\n".utf8)))
        }
        var clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<30 { _ = engine.snapshot() }
        let snapTime = clock.now - start
        let start2 = clock.now
        for _ in 0..<30 { _ = engine.historyTail(400) }
        let tailTime = clock.now - start2
        print("PERF snapshot(100x40) x30: \(snapTime)  -> per frame: \(snapTime / 30)")
        print("PERF historyTail(400) x30: \(tailTime)  -> per frame: \(tailTime / 30)")
    }

    @Test("history equality diff cost (what SwiftUI pays per frame)")
    func equalityCost() {
        let engine = SwiftTermEngine(geometry: TerminalGeometry(cols: 100, rows: 40),
                                     scrollback: 10_000)
        for i in 0..<2000 {
            engine.feed(ArraySlice(Array("line \(i): payload payload payload payload payload\r\n".utf8)))
        }
        let a = engine.historyTail(400)
        let b = engine.historyTail(400)
        var clock = ContinuousClock()
        let start = clock.now
        var equal = 0
        for _ in 0..<30 { if a == b { equal += 1 } }
        print("PERF [TerminalLine]x400 equality x30: \(clock.now - start) (\(equal))")
    }
}

extension PerfProbes {
    @Test("view-side AttributedString build: per-cell append vs batched runs")
    func attributedCost() {
        let cells = (0..<100).map { i in
            TerminalCell(character: Character(UnicodeScalar(65 + (i % 26))!))
        }
        let line = TerminalLine(cells: cells)
        var clock = ContinuousClock()

        // Current approach: one AttributedString append per cell.
        let start = clock.now
        for _ in 0..<40 {
            var result = AttributedString()
            for cell in line.cells {
                let piece = AttributedString(String(cell.character))
                result.append(piece)
            }
        }
        print("PERF per-cell append, 40 rows x 100 cols: \(clock.now - start)")

        // Batched: group same-style runs into one string (candidate fix).
        let start2 = clock.now
        for _ in 0..<40 {
            var result = AttributedString()
            let text = String(line.cells.map { $0.character })
            result.append(AttributedString(text))
        }
        print("PERF batched runs, 40 rows x 100 cols: \(clock.now - start2)")
    }
}

import LoomAgents

extension PerfProbes {
    @Test("native-session existence scan against the real ~/.claude/projects")
    func existsScanCost() {
        var clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 { _ = ClaudeNativeSessions.exists(SessionID()) }   // worst case: not found
        print("PERF exists() x20 (miss): \(clock.now - start)  -> per record: \((clock.now - start) / 20)")
    }
}
