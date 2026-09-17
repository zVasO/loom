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
}
