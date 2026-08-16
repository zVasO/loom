import Testing
import LoomCore
import LoomTerminal
import LoomTerminalTestSupport
import Dispatch

// The production adapter of the TerminalEngine seam, tested at the same seam as
// LineEngine: we feed bytes, we read screen values. Expectations come from
// documented xterm behavior, not from the implementation.

@Suite("SwiftTermEngine — production adapter")
struct SwiftTermEngineTests {
    let queue = DispatchQueue(label: "test.session")

    private func makeEngine(cols: Int = 40, rows: Int = 6) -> any TerminalEngine {
        SwiftTermEngine(geometry: TerminalGeometry(cols: cols, rows: rows), scrollback: 100)
    }

    @Test("plain text with carriage returns becomes screen lines")
    func texteSimple() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("Hello\r\nworld".utf8))
            let screen = engine.snapshot()
            #expect(screen.lines[0].text.hasPrefix("Hello"))
            #expect(screen.lines[1].text.hasPrefix("world"))
            #expect(screen.cursor.row == 1)
        }
    }

    @Test("ANSI color sequences produce styles, not text")
    func couleursAnsi() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[31mred\u{1B}[0mplain".utf8))
            let screen = engine.snapshot()
            let cells = screen.lines[0].cells
            #expect(screen.lines[0].text.hasPrefix("redplain"), "the sequences do not leak into the text")
            #expect(cells[0].style.foreground == .ansi(1), "the 'r' of 'red' is in ANSI red")
            #expect(cells[6].style.foreground == .default, "after the reset, back to the default color")
        }
    }

    @Test("the cursor follows positioning sequences")
    func positionnementCurseur() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[3;5H".utf8))   // CUP row 3, column 5 (1-indexed)
            let screen = engine.snapshot()
            #expect(screen.cursor.row == 2)
            #expect(screen.cursor.col == 4)
        }
    }

    @Test("the revision only advances when the screen changes")
    func revisionMonotone() {
        let engine = makeEngine()
        queue.sync {
            let before = engine.snapshot().revision
            engine.feed(ArraySlice("x".utf8))
            let after = engine.snapshot().revision
            #expect(after > before)
            #expect(engine.snapshot().revision == after, "a snapshot with no new byte does not change the revision")
        }
    }
}

extension SwiftTermEngineTests {
    @Test("the scrollback is accessible: lines pushed off screen remain readable")
    func scrollbackAccessible() {
        let engine = makeEngine(cols: 40, rows: 6)
        queue.sync {
            for index in 1...30 {
                engine.feed(ArraySlice("line-\(index)\r\n".utf8))
            }
            let history = engine.historyTail(10)
            #expect(history.count == 10, "we ask for the last 10 lines above the screen")
            #expect(history.contains { $0.text.hasPrefix("line-2") },
                    "lines chased off the screen by the stream are in the history")
            let screen = engine.snapshot()
            #expect(screen.lines.contains { $0.text.hasPrefix("line-30") },
                    "the visible screen, meanwhile, shows the end of the stream")
        }
    }
}
