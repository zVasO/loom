import Testing
import LoomCore
import LoomAgents
import Foundation
@testable import LoomTerminal

/// Regression guard for the hot paths of the performance audits
/// (docs/perf-audit-2026-08-17.md, docs/perf-audit-2026-09-22.md). Every
/// probe asserts a bound derived from the audit's target, widened by
/// `slack`: the point is catching a lost cache or a per-frame copy — an
/// order of magnitude — not timing a build. The numbers are still printed
/// for the before/after the audit asks to re-measure on a Mac.
@Suite("PERF PROBES", .serialized)
struct PerfProbes {

    /// 3× the target in release, 10× in debug: unoptimised Swift is that
    /// much slower on cell copies, and `swift test` builds debug.
    static let slack: Double = {
        #if DEBUG
        return 10
        #else
        return 3
        #endif
    }()

    /// The bound a probe asserts for a target in milliseconds.
    static func bound(_ targetMilliseconds: Double) -> Duration {
        .milliseconds(targetMilliseconds * slack)
    }

    /// The engine is fed and read from one queue, as in production (ADR-0007).
    private let queue = DispatchQueue(label: "test.perf.session")

    private func filledEngine(lines: Int = 5000, cols: Int = 100, rows: Int = 40) -> SwiftTermEngine {
        let engine = SwiftTermEngine(geometry: TerminalGeometry(cols: cols, rows: rows), scrollback: 10_000)
        queue.sync {
            for index in 0..<lines {
                engine.feed(ArraySlice("line \(index): the quick brown fox jumps over the lazy dog 0123456789\r\n".utf8))
            }
        }
        return engine
    }

    /// The mean duration of one iteration.
    private func measure(_ iterations: Int, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { body() }
        return (clock.now - start) / iterations
    }

    // P0 (August) incremental tail: at steady stream the history tail
    // extracts one new scrollback row, not 400. The snapshot is still a
    // full copy on a scrolled frame — SwiftTerm marks scrollTop…scrollBottom
    // on every scroll — so the row cache is guarded by `snapshotDirtyCost`.
    @Test("streaming frame: one line in, snapshot + historyTail(400) out, under a millisecond")
    func frameCostStreaming() {
        let engine = filledEngine()
        var index = 5000
        let perFrame = queue.sync {
            measure(30) {
                engine.feed(ArraySlice("line \(index): streamed while the pane watches\r\n".utf8))
                index += 1
                _ = engine.snapshot()
                _ = engine.historyTail(400)
            }
        }
        print("PERF streaming frame (100x40, tail 400): \(perFrame) per frame")
        #expect(perFrame < Self.bound(1), "a frame at steady stream costs \(perFrame): the tail cache is gone")
    }

    // P1-5: a row the emulator did not touch is handed back as is.
    @Test("a one-row change costs a one-row snapshot, and the rows stay exact")
    func snapshotDirtyCost() {
        let engine = filledEngine()
        queue.sync { _ = engine.snapshot() }   // primes the row cache
        var tick = 0
        let perSnapshot = queue.sync {
            measure(30) {
                engine.feed(ArraySlice("\u{1B}[10;1Htick \(tick)".utf8))   // row 10 only, no scroll
                tick += 1
                _ = engine.snapshot()
            }
        }
        print("PERF one-row snapshot (100x40): \(perSnapshot)")
        #expect(perSnapshot < Self.bound(0.5), "a one-row change re-copied the screen: \(perSnapshot)")

        // The same build's full copy — a scroll marks every row — for scale:
        // whatever the machine, the one-row snapshot is a fraction of it.
        let full = filledEngine()
        queue.sync { _ = full.snapshot() }
        let perFullCopy = queue.sync {
            measure(30) {
                full.feed(ArraySlice("\u{1B}[40;1H\r\n".utf8))   // scroll: rows 0…39 dirty
                _ = full.snapshot()
            }
        }
        print("PERF full-copy snapshot (100x40): \(perFullCopy)")
        #expect(perSnapshot * 4 < perFullCopy,
                "a one-row change cost \(perSnapshot) against \(perFullCopy) for a full copy: the row cache is gone")

        // Whatever moved every row — a scroll, insert/delete line, the
        // alternate screen, a resize — the incremental rows equal a
        // from-scratch copy of the same bytes.
        let scratch = filledEngine()
        let script = ["\u{1B}[40;1Hscroll\r\n", "\u{1B}[5;1H\u{1B}[2L", "\u{1B}[3M",
                      "\u{1B}[?1049h\u{1B}[2;2Halt", "\u{1B}[?1049l", "back\r\n"]
        queue.sync {
            for past in 0..<tick { scratch.feed(ArraySlice("\u{1B}[10;1Htick \(past)".utf8)) }
            for chunk in script {
                engine.feed(ArraySlice(chunk.utf8))
                _ = engine.snapshot()
            }
            scratch.feed(ArraySlice(script.joined().utf8))
            #expect(engine.snapshot().lines == scratch.snapshot().lines, "after scroll, IL/DL and the alternate screen")
            engine.resize(to: TerminalGeometry(cols: 80, rows: 30))
            scratch.resize(to: TerminalGeometry(cols: 80, rows: 30))
            #expect(engine.snapshot().lines == scratch.snapshot().lines, "after a resize too")
        }
    }

    // P1-6: a resize re-primes the tail with what is asked, not with the cap.
    @Test("a resize re-primes exactly the tail asked for, equal to a fresh engine's")
    func tailPrimeCost() {
        let engine = filledEngine()
        queue.sync { _ = engine.historyTail(400) }
        let clock = ContinuousClock()
        let (elapsed, tail): (Duration, [TerminalLine]) = queue.sync {
            engine.resize(to: TerminalGeometry(cols: 90, rows: 40))
            let start = clock.now
            let tail = engine.historyTail(400)
            return (clock.now - start, tail)
        }
        print("PERF historyTail(400) after a resize, 5000 lines: \(elapsed)")
        #expect(tail.count == 400)
        let fresh = filledEngine()
        queue.sync {
            fresh.resize(to: TerminalGeometry(cols: 90, rows: 40))
            #expect(fresh.historyTail(400) == tail, "the re-primed tail is the fresh engine's")
        }
    }

    // P1-6: the sampler and readiness read a walked tail, never a snapshot.
    @Test("the visible tail is read without a snapshot, and reads what the snapshot would")
    func visibleTailCost() {
        let engine = filledEngine(lines: 10)
        queue.sync {
            engine.feed(ArraySlice("padded with blanks        \r\n".utf8))
            engine.feed(ArraySlice("\u{1B}[20;12Hafter never-written cells\r\n".utf8))
            engine.feed(ArraySlice("日本 wide\r\n".utf8))
        }
        let (tail, derived, perRead): ([String], [String], Duration) = queue.sync {
            let derived = Array(engine.snapshot().lines
                .map(\.text)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(12))
            let tail = engine.visibleTail(12)
            return (tail, derived, measure(30) { _ = engine.visibleTail(12) })
        }
        print("PERF visibleTail(12) on 100x40: \(perRead)")
        // A wide character is one cell in the walked string and two in the
        // snapshot's cells: compared everywhere else, checked on its own.
        #expect(tail.filter { !$0.hasSuffix("wide") } == derived.filter { !$0.hasSuffix("wide") },
                "blanks trimmed, never-written cells read as spaces")
        #expect(tail.contains { $0.hasPrefix("日") && $0.hasSuffix("wide") })
        #expect(perRead < Self.bound(0.3), "the tail walked the rows in \(perRead)")
    }

    // P0-2: the native conversations are indexed in one walk, and asked
    // about with a set lookup — hermetic, on a temp tree.
    @Test("the native index is one walk over 10,000 files, and membership is a set lookup")
    func existsIndexCost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-index-probe-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        var known: [SessionID] = []
        for slug in 0..<50 {
            let directory = root.appendingPathComponent("-Users-me-project-\(slug)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for _ in 0..<200 {
                let id = SessionID()
                known.append(id)
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent("\(id.rawValue.uuidString).jsonl").path,
                    contents: nil)
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let index = ClaudeNativeSessions.index(projectsDirectory: root)
        let walk = clock.now - start
        print("PERF index() over 50 slugs x 200 files: \(walk)")
        #expect(index.count == 10_000)
        #expect(walk < Self.bound(20), "one walk of 10,000 files took \(walk)")

        var cursor = 0
        var found = 0
        let perLookup = measure(1000) {
            if ClaudeNativeSessions.contains(index, known[cursor % known.count]) { found += 1 }
            cursor += 1
        }
        print("PERF contains() x1000: \(perLookup * 1000)")
        #expect(found == 1000)
        #expect(perLookup * 1000 < Self.bound(1), "1000 lookups took \(perLookup * 1000): not O(1)")
    }
}
