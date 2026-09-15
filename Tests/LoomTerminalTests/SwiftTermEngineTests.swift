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

    // TRM-06 — why the session pane stopped scrolling under claude 2.x. A
    // full-screen agent REPAINTS its viewport (alternate screen, absolute cursor
    // moves) where a command-line program scrolls it. Nothing is ever pushed off
    // the top, so the scrollback the view offers stays empty however long the
    // session runs — and that is why the agent asks for the wheel itself.
    // Shape replayed from a real claude 2.1 transcript.
    @Test("a full-screen agent leaves no history behind, and takes the mouse")
    func agentPleinEcranSansHistorique() {
        let engine = makeEngine(rows: 4)
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[?1049h\u{1B}[2J\u{1B}[?1000h\u{1B}[?1006h".utf8))
            for frame in 0..<20 {
                for row in 1...4 {
                    engine.feed(ArraySlice("\u{1B}[\(row);1Hframe \(frame) row \(row)".utf8))
                }
            }
            #expect(engine.snapshot().lines[0].text.hasPrefix("frame 19"), "the agent did draw")
            #expect(engine.historyTail(400).isEmpty,
                    "repainting is not scrolling: nothing ever reaches the scrollback")
            #expect(engine.mouseReporting,
                    "so the agent took the wheel, to scroll the viewport it owns")
        }
    }

    @Test("mouse tracking is off until the program asks for it")
    func suiviSourisEteintParDefaut() {
        let engine = makeEngine()
        queue.sync {
            #expect(engine.mouseReporting == false)
            engine.feed(ArraySlice("\u{1B}[?1000h".utf8))
            #expect(engine.mouseReporting, "DECSET 1000 — the program takes the mouse")
            engine.feed(ArraySlice("\u{1B}[?1000l".utf8))
            #expect(engine.mouseReporting == false, "and hands it back")
        }
    }

    @Test("a wheel notch becomes an SGR mouse report for the program")
    func moletteEncodeeEnRapportSGR() {
        let engine = makeEngine()
        var upstream: [UInt8] = []
        engine.onUpstream = { upstream.append(contentsOf: $0) }
        queue.sync {
            // What claude emits at startup: tracking on, SGR encoding.
            engine.feed(ArraySlice("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            engine.sendWheel(.up, atCol: 3, row: 5)
            engine.sendWheel(.down, atCol: 3, row: 5)
        }
        // Buttons 4 and 5, coordinates 1-based on the wire.
        #expect(String(decoding: upstream, as: UTF8.self) == "\u{1B}[<64;4;6M\u{1B}[<65;4;6M")
    }

    // The agent draws targets — a close box, a file row — that carry no
    // keybinding whatsoever. A click is the ONLY way in, and it is a pair: the
    // press opens it, the release is what the program acts on.
    @Test("a click becomes an SGR press AND release for the program")
    func clicEncodeEnPaireSGR() {
        let engine = makeEngine()
        var upstream: [UInt8] = []
        engine.onUpstream = { upstream.append(contentsOf: $0) }
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            engine.sendClick(atCol: 3, row: 5)
        }
        // Button 0, coordinates 1-based on the wire; 'M' opens, 'm' closes.
        #expect(String(decoding: upstream, as: UTF8.self) == "\u{1B}[<0;4;6M\u{1B}[<0;4;6m")
    }

    @Test("without mouse tracking a click sends nothing at all")
    func clicMuetSansSuivi() {
        let engine = makeEngine()
        var upstream: [UInt8] = []
        engine.onUpstream = { upstream.append(contentsOf: $0) }
        queue.sync {
            engine.sendClick(atCol: 0, row: 0)
        }
        #expect(upstream.isEmpty, "a program that did not ask for the mouse must not be fed bytes")
    }

    @Test("without mouse tracking the wheel sends nothing at all")
    func moletteMuetteSansSuivi() {
        let engine = makeEngine()
        var upstream: [UInt8] = []
        engine.onUpstream = { upstream.append(contentsOf: $0) }
        queue.sync {
            engine.sendWheel(.up, atCol: 0, row: 0)
        }
        #expect(upstream.isEmpty, "a program that did not ask for the mouse must not be fed bytes")
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

    // P0 perf: the tail is cached and grown incrementally — correctness first.
    @Test("incremental tail equals a from-scratch rebuild after growth")
    func incrementalTailCorrectness() {
        let engine = makeEngine(cols: 40, rows: 6)
        queue.sync {
            for index in 1...20 { engine.feed(ArraySlice("first-\(index)\r\n".utf8)) }
            _ = engine.historyTail(400)                       // primes the cache
            for index in 21...40 { engine.feed(ArraySlice("second-\(index)\r\n".utf8)) }
            let incremental = engine.historyTail(400)

            let fresh = makeEngine(cols: 40, rows: 6)
            for index in 1...20 { fresh.feed(ArraySlice("first-\(index)\r\n".utf8)) }
            for index in 21...40 { fresh.feed(ArraySlice("second-\(index)\r\n".utf8)) }
            #expect(incremental == fresh.historyTail(400), "cache must never change the result")
        }
    }

    @Test("a resize invalidates the tail cache (scrollback reflows)")
    func tailCacheInvalidatedOnResize() {
        let engine = makeEngine(cols: 40, rows: 6)
        queue.sync {
            for index in 1...30 { engine.feed(ArraySlice("row-\(index)\r\n".utf8)) }
            _ = engine.historyTail(400)
            engine.resize(to: TerminalGeometry(cols: 60, rows: 8))
            let after = engine.historyTail(400)
            let fresh = makeEngine(cols: 40, rows: 6)
            for index in 1...30 { fresh.feed(ArraySlice("row-\(index)\r\n".utf8)) }
            fresh.resize(to: TerminalGeometry(cols: 60, rows: 8))
            #expect(after == fresh.historyTail(400))
        }
    }
}
