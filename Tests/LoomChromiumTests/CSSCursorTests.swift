import Testing
import LoomChromium
import Foundation

// Seam: the page's computed `cursor` under the pointer → the NSCursor the
// panel shows (panel design §2, Cursor).

@Suite("CSSCursor — the page's cursor in the panel")
struct CSSCursorTests {

    @Test("the table's keywords")
    func motsCles() {
        let table: [(String, CursorKind)] = [
            ("pointer", .pointingHand), ("text", .iBeam), ("crosshair", .crosshair),
            ("not-allowed", .operationNotAllowed), ("no-drop", .operationNotAllowed),
            ("grab", .openHand), ("grabbing", .closedHand),
            ("ew-resize", .resizeLeftRight), ("col-resize", .resizeLeftRight),
            ("ns-resize", .resizeUpDown), ("row-resize", .resizeUpDown),
            ("copy", .dragCopy), ("alias", .dragLink), ("context-menu", .contextualMenu),
            ("default", .arrow), ("none", .arrow), ("wait", .arrow), ("zoom-in", .arrow),
        ]
        for (keyword, kind) in table {
            #expect(CSSCursor.kind(keyword: keyword) == kind, "\(keyword)")
        }
    }

    @Test("auto: an I-beam over an editable element, a hand over a link, else the arrow")
    func auto() {
        #expect(CSSCursor.kind(keyword: "auto", editable: true, link: false) == .iBeam)
        #expect(CSSCursor.kind(keyword: "auto", editable: false, link: true) == .pointingHand)
        #expect(CSSCursor.kind(keyword: "auto", editable: true, link: true) == .iBeam)
        #expect(CSSCursor.kind(keyword: "auto") == .arrow)
        #expect(CSSCursor.kind(keyword: "pointer", editable: true) == .pointingHand, "an explicit keyword wins")
    }

    @Test("an image cursor is not drawn: its fallback keyword is, else the arrow")
    func images() {
        #expect(CSSCursor.kind(keyword: "url(\"hand.png\")") == .arrow)
        #expect(CSSCursor.kind(keyword: "url(\"hand.png\") 4 12, pointer") == .pointingHand)
        #expect(CSSCursor.kind(keyword: "url(a.svg), url(\"b,c.png\"), auto", editable: true) == .iBeam)
    }

    @Test("case, whitespace and the -webkit- prefix do not matter")
    func normalisation() {
        #expect(CSSCursor.kind(keyword: "  Pointer ") == .pointingHand)
        #expect(CSSCursor.kind(keyword: "-webkit-grab") == .openHand)
        #expect(CSSCursor.kind(keyword: "") == .arrow)
    }

    @Test("every kind is reachable")
    func toutesLesSortes() {
        let keywords = ["auto", "pointer", "text", "crosshair", "not-allowed", "grab", "grabbing", "ew-resize",
                        "ns-resize", "copy", "alias", "context-menu"]
        let reached = Set(keywords.map { CSSCursor.kind(keyword: $0) })
        #expect(reached == Set(CursorKind.allCases))
    }
}
