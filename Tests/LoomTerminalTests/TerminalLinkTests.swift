import Testing
import LoomTerminal

// Seam: from a clicked cell to the link under it. Two sources that must behave
// the same for the view — OSC 8 payloads emitted by an agent, and URLs merely
// printed in plain text — and the soft wrap that cuts either one in half.

@Suite("TerminalLinks — the link under the cell")
struct TerminalLinkTests {

    private static let cols = 24

    /// The engine pads every row to the grid width, so fixtures do too.
    private func line(_ text: String, link: String? = nil, isWrapped: Bool = false) -> TerminalLine {
        let padded = text.padding(toLength: Self.cols, withPad: " ", startingAt: 0)
        let cells = padded.map { character in
            TerminalCell(character: character,
                         link: character == " " ? nil : link)
        }
        return TerminalLine(cells: cells, isWrapped: isWrapped)
    }

    @Test func aucunLienSurDuTexteOrdinaire() {
        #expect(TerminalLinks.link(in: [line("rien a voir ici")], row: 0, column: 2) == nil)
    }

    @Test func uneURLEnClairEstUnLien() {
        let found = TerminalLinks.link(in: [line("voir https://ex.com/a ici")], row: 0, column: 8)
        #expect(found?.target == "https://ex.com/a")
        #expect(found?.isExplicit == false)
        #expect(found?.segments == [TerminalLink.Segment(row: 0, columns: 5..<21)])
    }

    @Test func horsDeLURLIlNYARien() {
        #expect(TerminalLinks.link(in: [line("voir https://ex.com/a ici")], row: 0, column: 1) == nil)
    }

    @Test func unPayloadOSC8FaitUnLienSurUnLibelle() {
        let found = TerminalLinks.link(in: [line("Security guide", link: "https://docs.example/x")],
                                       row: 0, column: 3)
        #expect(found?.target == "https://docs.example/x")
        #expect(found?.isExplicit == true)
    }

    @Test func leLibelleOSC8PrimeSurLeTexteAffiche() {
        // The visible text is a URL, but the payload points elsewhere: the
        // payload is what the agent asked us to open.
        let found = TerminalLinks.link(in: [line("https://shown.example", link: "https://real.example")],
                                       row: 0, column: 4)
        #expect(found?.target == "https://real.example")
    }

    @Test func uneURLCoupeeParLeWrapResteUnSeulLien() {
        let lines = [line("texte https://ex.com/tre"),
                     line("s-long/chemin fin", isWrapped: true)]
        let found = TerminalLinks.link(in: lines, row: 0, column: 10)
        #expect(found?.target == "https://ex.com/tres-long/chemin")
        #expect(found?.segments == [TerminalLink.Segment(row: 0, columns: 6..<24),
                                    TerminalLink.Segment(row: 1, columns: 0..<13)])
    }

    @Test func onLaTrouveAussiEnCliquantSurSaSecondeMoitie() {
        let lines = [line("texte https://ex.com/tre"),
                     line("s-long/chemin fin", isWrapped: true)]
        #expect(TerminalLinks.link(in: lines, row: 1, column: 3)?.target
            == "https://ex.com/tres-long/chemin")
    }

    @Test func unWrapAbsentSepareLesDeuxLignes() {
        let lines = [line("texte https://ex.com/tre"),
                     line("s-long/chemin fin")]
        #expect(TerminalLinks.link(in: lines, row: 0, column: 10)?.target == "https://ex.com/tre")
    }

    @Test func unePositionHorsGrilleNeCrashePas() {
        let lines = [line("https://ex.com/a")]
        #expect(TerminalLinks.link(in: lines, row: 9, column: 0) == nil)
        #expect(TerminalLinks.link(in: lines, row: 0, column: 999) == nil)
    }
}
