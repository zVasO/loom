import Testing
import LoomCore
import LoomTerminal
import Foundation

// Seam: turning "the user dragged from here to there" into the text that lands on
// the pasteboard. Pure — the view only supplies two cell positions.

@Suite("TerminalSelection — from a dragged range to text")
struct TerminalSelectionTests {

    private static let cols = 20

    /// The engine pads every row to the full grid width, so the fixture does too:
    /// the trailing-space trim is the whole reason this seam exists.
    private func line(_ text: String) -> TerminalLine {
        let padded = text.padding(toLength: Self.cols, withPad: " ", startingAt: 0)
        return TerminalLine(cells: padded.map { TerminalCell(character: $0) })
    }

    private func screen(_ texts: [String]) -> TerminalScreen {
        TerminalScreen(geometry: TerminalGeometry(cols: Self.cols, rows: texts.count),
                       lines: texts.map(line),
                       cursor: CursorPosition(col: 0, row: 0),
                       revision: 1)
    }

    private func position(_ row: Int, _ col: Int) -> TerminalPosition {
        TerminalPosition(row: row, col: col)
    }

    // MARK: - Ordering and emptiness

    @Test("a click is not a selection: anchor == head selects nothing")
    func clicSimpleNeSelectionneRien() {
        let selection = TerminalSelection(anchor: position(3, 5), head: position(3, 5))
        #expect(selection.isActive == false,
                "columns are boundaries: without this a click to focus paints a stray character")
        #expect(selection.columnRange(forRow: 3, cols: Self.cols) == nil)
        #expect(TerminalSelection.empty.isActive == false)
    }

    @Test("dragging upwards reads like dragging downwards")
    func glisserVersLeHautEstNormalise() {
        let up = TerminalSelection(anchor: position(5, 8), head: position(2, 1))
        let down = TerminalSelection(anchor: position(2, 1), head: position(5, 8))
        #expect(up.ordered?.from == position(2, 1))
        #expect(up.ordered?.to == position(5, 8))
        #expect(up.columnRange(forRow: 3, cols: Self.cols)
                == down.columnRange(forRow: 3, cols: Self.cols))
    }

    // MARK: - Linear column ranges

    @Test("on a single row the range is exactly the two boundaries")
    func plageSurUneSeuleLigne() {
        let selection = TerminalSelection(anchor: position(4, 3), head: position(4, 9))
        #expect(selection.columnRange(forRow: 4, cols: Self.cols) == 3..<9)
        #expect(selection.columnRange(forRow: 3, cols: Self.cols) == nil)
        #expect(selection.columnRange(forRow: 5, cols: Self.cols) == nil)
    }

    @Test("across rows: the first runs to the edge, the middle is full, the last stops")
    func plagesLineairesSurPlusieursLignes() {
        let selection = TerminalSelection(anchor: position(2, 6), head: position(4, 3))
        #expect(selection.columnRange(forRow: 2, cols: Self.cols) == 6..<Self.cols)
        #expect(selection.columnRange(forRow: 3, cols: Self.cols) == 0..<Self.cols)
        #expect(selection.columnRange(forRow: 4, cols: Self.cols) == 0..<3)
    }

    @Test("boundaries beyond the grid are clamped, never trusted")
    func plagesBorneesALaGrille() {
        let selection = TerminalSelection(anchor: position(1, -4), head: position(1, 999))
        #expect(selection.columnRange(forRow: 1, cols: Self.cols) == 0..<Self.cols)
    }

    // MARK: - Block ranges

    @Test("a block keeps the same columns on every row it spans")
    func plageEnBlocIdentiqueSurChaqueLigne() {
        let selection = TerminalSelection(anchor: position(2, 9), head: position(5, 4),
                                          mode: .block)
        for row in 2...5 {
            #expect(selection.columnRange(forRow: row, cols: Self.cols) == 4..<9,
                    "row \(row): a block is a rectangle, not a text run")
        }
        #expect(selection.columnRange(forRow: 6, cols: Self.cols) == nil)
    }

    @Test("a block dragged straight down selects nothing: it has no width")
    func blocSansLargeurEstInactif() {
        let selection = TerminalSelection(anchor: position(2, 7), head: position(9, 7),
                                          mode: .block)
        #expect(selection.isActive == false)
    }

    // MARK: - Text

    @Test("the padding the engine adds never reaches the pasteboard")
    func espacesDeRemplissageJamaisCopies() {
        let screen = screen(["hello", "world"])
        let selection = TerminalSelection(anchor: position(0, 2), head: position(1, 3))
        #expect(selection.text(history: [], historyBase: 0, screen: screen) == "llo\nwor",
                "the first row is padded to 20 columns — copying them all is unusable")
    }

    @Test("spaces INSIDE the selection are kept: they are what was framed")
    func espacesInterieursPreserves() {
        let screen = screen(["a  b"])
        let selection = TerminalSelection(anchor: position(0, 0), head: position(0, 4))
        #expect(selection.text(history: [], historyBase: 0, screen: screen) == "a  b")
    }

    @Test("a block cut out of a table loses its padding too")
    func blocCoupeSansRemplissage() {
        let screen = screen(["ab", "cd"])
        let selection = TerminalSelection(anchor: position(0, 1), head: position(1, 10),
                                          mode: .block)
        #expect(selection.text(history: [], historyBase: 0, screen: screen) == "b\nd")
    }

    @Test("history and screen are one continuous run of absolute rows")
    func historiqueEtEcranSontContigus() {
        let history = [line("past one"), line("past two")]
        let screen = screen(["live"])
        // historyBase 100 → history rows 100 and 101, screen row 102.
        let selection = TerminalSelection(anchor: position(101, 0), head: position(102, 4))
        #expect(selection.text(history: history, historyBase: 100, screen: screen)
                == "past two\nlive")
    }

    @Test("a row that scrolled out of the buffer is skipped, not crashed on")
    func ligneSortieDuTamponIgnoree() {
        let history = [line("kept")]
        let screen = screen(["live"])
        // Rows 98 and 99 fell below historyBase: the selection outlived them.
        let selection = TerminalSelection(anchor: position(98, 0), head: position(101, 4))
        #expect(selection.text(history: history, historyBase: 100, screen: screen)
                == "kept\nlive")
    }

    @Test("an inactive selection yields no text at all")
    func selectionInactiveNeRendRien() {
        let screen = screen(["hello"])
        let selection = TerminalSelection(anchor: position(0, 2), head: position(0, 2))
        #expect(selection.text(history: [], historyBase: 0, screen: screen) == nil)
        #expect(TerminalSelection.empty.text(history: [], historyBase: 0, screen: screen) == nil)
    }

    @Test("select-all takes history and screen, and carries its own text")
    func toutSelectionner() {
        let history = [line("past")]
        let screen = screen(["live", "here"])
        let selection = TerminalSelection.all(history: history, historyBase: 100, screen: screen)
        #expect(selection.isActive)
        #expect(selection.capturedText == "past\nlive\nhere",
                "⌘⇧A resolves its text immediately, like a finished drag")
    }

    @Test("select-all on an empty pane selects nothing")
    func toutSelectionnerSurPaneVide() {
        let empty = TerminalScreen(geometry: TerminalGeometry(cols: Self.cols, rows: 0),
                                   lines: [],
                                   cursor: CursorPosition(col: 0, row: 0),
                                   revision: 0)
        #expect(TerminalSelection.all(history: [], historyBase: 0, screen: empty).isActive == false)
    }

    // MARK: - Words

    @Test("a double click takes the whole path, separators included")
    func doubleClicPrendLeCheminEntier() {
        let cells = line("open foo-bar.txt now").cells
        let range = TerminalWord.range(in: cells, at: 8)
        #expect(String(cells[range].map(\.character)) == "foo-bar.txt")
    }

    @Test("a double click on blanks takes the run of blanks")
    func doubleClicSurDuBlancPrendLeBlanc() {
        let cells = line("a   b").cells
        let range = TerminalWord.range(in: cells, at: 2)
        #expect(range == 1..<4)
    }

    @Test("a word at the very start of the row stops at the edge")
    func motEnDebutDeLigneSArreteAuBord() {
        let cells = line("alpha beta").cells
        #expect(TerminalWord.range(in: cells, at: 0) == 0..<5)
    }

    // MARK: - Click counting

    @Test("clicks add up while they stay close in time and place")
    func clicsSAccumulent() {
        #expect(TerminalClick.count(previous: 1, sameCell: true, elapsed: 0.1, interval: 0.5) == 2)
        #expect(TerminalClick.count(previous: 2, sameCell: true, elapsed: 0.1, interval: 0.5) == 3)
    }

    @Test("a fourth click starts over, and so does a slow or distant one")
    func compteurDeClicsSeRemetAZero() {
        #expect(TerminalClick.count(previous: 3, sameCell: true, elapsed: 0.1, interval: 0.5) == 1,
                "past the triple click AppKit wraps back to one")
        #expect(TerminalClick.count(previous: 2, sameCell: true, elapsed: 0.9, interval: 0.5) == 1)
        #expect(TerminalClick.count(previous: 2, sameCell: false, elapsed: 0.1, interval: 0.5) == 1)
    }

    // MARK: - Tap or drag

    // Who owns the press when the agent tracks the mouse: a motionless one is
    // meant for the agent's own targets, a travelling one is a selection of ours.
    @Test("a motionless press and release is the agent's click")
    func pressionImmobileEstUnClic() {
        #expect(TerminalClick.isTap(from: CGPoint(x: 40, y: 12), to: CGPoint(x: 41, y: 13),
                                    sameCell: true, slop: 3),
                "a hand never holds perfectly still")
    }

    @Test("a press that travelled is a selection, and the agent hears nothing")
    func pressionQuiSeDeplaceEstUneSelection() {
        #expect(TerminalClick.isTap(from: CGPoint(x: 40, y: 12), to: CGPoint(x: 90, y: 12),
                                    sameCell: false, slop: 3) == false)
        #expect(TerminalClick.isTap(from: CGPoint(x: 40, y: 12), to: CGPoint(x: 44, y: 12),
                                    sameCell: true, slop: 3) == false,
                "a drag that wandered and came back to its own cell is still a drag")
    }
}
