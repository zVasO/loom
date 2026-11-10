import Testing
import AppKit
import LoomUI

// The one conversion the whole selection rests on: a point in the padded content
// becomes a cell address. Rows and columns deliberately do NOT round the same way.

@Suite("TerminalMetrics — a point becomes a cell")
struct TerminalMetricsTests {

    private let cell = TerminalMetrics.cellSize
    private let inset = TerminalMetrics.gridInset

    private func point(col: CGFloat, row: CGFloat) -> CGPoint {
        CGPoint(x: inset + cell.width * col, y: inset + cell.height * row)
    }

    @Test("width(forColumns:) holds exactly that many columns — one cell less holds one fewer")
    func largeurPourColonnes() {
        let width = TerminalMetrics.width(forColumns: 80)
        #expect(TerminalMetrics.grid(fitting: CGSize(width: width, height: 400)).cols == 80)
        #expect(TerminalMetrics.grid(fitting: CGSize(width: width - cell.width, height: 400)).cols == 79)
    }

    @Test("the padding is deducted: the first cell starts at the inset, not at zero")
    func remplissageDeduit() {
        let boundary = TerminalMetrics.boundary(at: point(col: 0.1, row: 0.1), rows: 10, cols: 40)
        #expect(boundary.row == 0)
        #expect(boundary.col == 0)
    }

    @Test("rows floor and columns round — the distinction the selection depends on")
    func lignesPlancherColonnesArrondi() {
        let boundary = TerminalMetrics.boundary(at: point(col: 5.75, row: 2.75), rows: 10, cols: 40)
        #expect(boundary.row == 2, "the row under the pointer, never the nearest edge")
        #expect(boundary.col == 6, "past the middle of column 5, the boundary is its right edge")
    }

    @Test("on the left half of a glyph the boundary stays before it")
    func moitieGaucheResteAvant() {
        #expect(TerminalMetrics.boundary(at: point(col: 5.25, row: 0), rows: 10, cols: 40).col == 5)
    }

    @Test("columns clamp to cols INCLUSIVE: the right edge of the last cell is valid")
    func colonnesBorneesInclusivement() {
        #expect(TerminalMetrics.boundary(at: point(col: 999, row: 0), rows: 10, cols: 40).col == 40)
    }

    @Test("rows clamp to the content, above it as well as below")
    func lignesBornees() {
        #expect(TerminalMetrics.boundary(at: point(col: 0, row: 999), rows: 10, cols: 40).row == 9)
        let above = TerminalMetrics.boundary(at: CGPoint(x: -50, y: -50), rows: 10, cols: 40)
        #expect(above.row == 0)
        #expect(above.col == 0)
    }

    @Test("the word column floors where the boundary rounds")
    func colonneDeMotPlancher() {
        let x = inset + cell.width * 5.75
        #expect(TerminalMetrics.cellColumn(atX: x, cols: 40) == 5,
                "rounding here would make a double click on the right of a glyph take the NEXT word")
        #expect(TerminalMetrics.boundary(at: CGPoint(x: x, y: inset), rows: 10, cols: 40).col == 6)
    }

    // MARK: - Staying glued to the bottom

    @Test("pinned only when the end of the content sits at the bottom edge")
    func colleEnBas() {
        let height = cell.height
        #expect(TerminalMetrics.isPinnedToBottom(contentEnd: 600, viewportHeight: 600,
                                                 cellHeight: height))
        #expect(TerminalMetrics.isPinnedToBottom(contentEnd: 600 + height / 3,
                                                 viewportHeight: 600, cellHeight: height),
                "a fraction of a row past the edge is still the bottom")
        #expect(!TerminalMetrics.isPinnedToBottom(contentEnd: 600 + height * 10,
                                                  viewportHeight: 600, cellHeight: height),
                "ten rows below the edge: the user scrolled up, leave them there")
        #expect(TerminalMetrics.isPinnedToBottom(contentEnd: 400, viewportHeight: 600,
                                                 cellHeight: height),
                "content shorter than the viewport is always at its end")
    }

    @Test("the word column never runs off the row")
    func colonneDeMotBornee() {
        #expect(TerminalMetrics.cellColumn(atX: inset + cell.width * 999, cols: 40) == 39)
        #expect(TerminalMetrics.cellColumn(atX: -100, cols: 40) == 0)
    }

    // MARK: - A click for the program

    @Test("a click lands on the screen row under it, wherever in the cell — the close box of a one-row header")
    func clicSurLaLigneSousLePointeur() {
        // No scrollback: content row n is screen row n, top, middle and bottom of the cell alike.
        for fraction in [0.02, 0.5, 0.98] {
            let hit = TerminalMetrics.screenCell(at: point(col: 12.5, row: 3 + fraction),
                                                 historyRows: 0, screenRows: 24, cols: 80)
            #expect(hit?.row == 3, "at \(fraction) of the cell's height")
            #expect(hit?.col == 12)
        }
    }

    @Test("the scrollback above the screen is not the program's: its rows are deducted, a click there is nobody's")
    func clicSousLHistorique() {
        let onScreen = TerminalMetrics.screenCell(at: point(col: 0.5, row: 400 + 7.9),
                                                  historyRows: 400, screenRows: 24, cols: 80)
        #expect(onScreen?.row == 7)
        #expect(onScreen?.col == 0)
        let inScrollback = TerminalMetrics.screenCell(at: point(col: 0.5, row: 399.9),
                                                      historyRows: 400, screenRows: 24, cols: 80)
        #expect(inScrollback?.row == nil, "the last line of the scrollback")
        let first = TerminalMetrics.screenCell(at: point(col: 0.5, row: 400),
                                               historyRows: 400, screenRows: 24, cols: 80)
        #expect(first?.row == 0, "the first line of the screen")
    }

    @Test("a click clamps to the screen: the padding under the last row is that row, the right edge the last column")
    func clicBorne() {
        let below = TerminalMetrics.screenCell(at: point(col: 999, row: 24.4),
                                               historyRows: 0, screenRows: 24, cols: 80)
        #expect(below?.row == 23)
        #expect(below?.col == 79)
        let above = TerminalMetrics.screenCell(at: CGPoint(x: 0, y: 0), historyRows: 0, screenRows: 24, cols: 80)
        #expect(above?.row == 0, "the padding above the first row, without scrollback")
        let noScreen = TerminalMetrics.screenCell(at: point(col: 0, row: 0), historyRows: 0, screenRows: 0, cols: 80)
        #expect(noScreen?.row == nil)
    }

    @Test("a pane whose height is not a whole number of rows: the leftover is ABOVE the grid, the click still finds its row")
    func resteAuDessusDeLaGrille() {
        // A pane 0.8 row taller than 24 rows, glued to its bottom: the content
        // overflows by the scrollback, and row r of the screen starts
        // (400 + r) rows into the padded content — where the old conversion
        // counted r rows from the PANE's top and found r + 1 for most of the cell.
        let paneHeight = inset * 2 + cell.height * 24.8
        let grid = TerminalMetrics.grid(fitting: CGSize(width: 800, height: paneHeight))
        #expect(grid.rows == 24)
        // The header of a pane drawn on screen row 5, clicked at 60 % of its height.
        let inContent = point(col: 70.5, row: 400 + 5.6)
        #expect(TerminalMetrics.screenCell(at: inContent, historyRows: 400, screenRows: 24, cols: 100)?.row == 5)
        // The same point seen from the pane's bottom edge: 18 whole rows under it.
        let fromBottom = inset + cell.height * (24 - 5.6)
        #expect(TerminalMetrics.rowsAboveLast(distanceFromBottom: fromBottom) == 18)
        #expect(24 - 1 - TerminalMetrics.rowsAboveLast(distanceFromBottom: fromBottom) == 5)
    }

    @Test("rows above the last one: zero on the last row and in the padding under it")
    func lignesAuDessusDeLaDerniere() {
        #expect(TerminalMetrics.rowsAboveLast(distanceFromBottom: 0) == 0)
        #expect(TerminalMetrics.rowsAboveLast(distanceFromBottom: inset + cell.height * 0.5) == 0)
        #expect(TerminalMetrics.rowsAboveLast(distanceFromBottom: inset + cell.height * 1.01) == 1)
        #expect(TerminalMetrics.rowsAboveLast(distanceFromBottom: inset + cell.height * 10.5) == 10)
    }
}
