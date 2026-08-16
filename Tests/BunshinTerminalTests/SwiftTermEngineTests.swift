import Testing
import BunshinCore
import BunshinTerminal
import BunshinTerminalTestSupport
import Dispatch

// L'adapter de production du seam TerminalEngine, testé au même seam que LineEngine :
// on nourrit des octets, on lit des écrans-valeurs. Les attendus viennent du
// comportement xterm documenté, pas de l'implémentation.

@Suite("SwiftTermEngine — adapter de production")
struct SwiftTermEngineTests {
    let queue = DispatchQueue(label: "test.session")

    private func makeEngine(cols: Int = 40, rows: Int = 6) -> any TerminalEngine {
        SwiftTermEngine(geometry: TerminalGeometry(cols: cols, rows: rows), scrollback: 100)
    }

    @Test("du texte simple avec retours chariot devient des lignes d'écran")
    func texteSimple() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("Bonjour\r\nle monde".utf8))
            let screen = engine.snapshot()
            #expect(screen.lines[0].text.hasPrefix("Bonjour"))
            #expect(screen.lines[1].text.hasPrefix("le monde"))
            #expect(screen.cursor.row == 1)
        }
    }

    @Test("les séquences ANSI de couleur produisent des styles, pas du texte")
    func couleursAnsi() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[31mrouge\u{1B}[0m sobre".utf8))
            let screen = engine.snapshot()
            let cells = screen.lines[0].cells
            #expect(screen.lines[0].text.hasPrefix("rouge sobre"), "les séquences ne fuient pas dans le texte")
            #expect(cells[0].style.foreground == .ansi(1), "« r » de rouge est en rouge ANSI")
            #expect(cells[6].style.foreground == .default, "après le reset, retour à la couleur par défaut")
        }
    }

    @Test("le curseur suit les séquences de positionnement")
    func positionnementCurseur() {
        let engine = makeEngine()
        queue.sync {
            engine.feed(ArraySlice("\u{1B}[3;5H".utf8))   // CUP ligne 3, colonne 5 (1-indexé)
            let screen = engine.snapshot()
            #expect(screen.cursor.row == 2)
            #expect(screen.cursor.col == 4)
        }
    }

    @Test("la révision n'avance que quand l'écran change")
    func revisionMonotone() {
        let engine = makeEngine()
        queue.sync {
            let before = engine.snapshot().revision
            engine.feed(ArraySlice("x".utf8))
            let after = engine.snapshot().revision
            #expect(after > before)
            #expect(engine.snapshot().revision == after, "snapshot sans nouvel octet ne change pas la révision")
        }
    }
}

extension SwiftTermEngineTests {
    @Test("le scrollback est accessible : les lignes sorties de l'écran restent lisibles")
    func scrollbackAccessible() {
        let engine = makeEngine(cols: 40, rows: 6)
        queue.sync {
            for index in 1...30 {
                engine.feed(ArraySlice("ligne-\(index)\r\n".utf8))
            }
            let history = engine.historyTail(10)
            #expect(history.count == 10, "on demande les 10 dernières lignes au-dessus de l'écran")
            #expect(history.contains { $0.text.hasPrefix("ligne-2") },
                    "les lignes chassées de l'écran par le flux sont dans l'historique")
            let screen = engine.snapshot()
            #expect(screen.lines.contains { $0.text.hasPrefix("ligne-30") },
                    "l'écran visible, lui, montre la fin du flux")
        }
    }
}
