import SwiftUI
import Testing
@testable import LoomUI

// Seam: the SVG path reader behind LucideIcon — Lucide's own data in, a path
// whose geometry matches the 24-unit grid out.

@Suite("LucideIcon — SVG path data")
struct LucideIconTests {

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.05) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("numbers follow SVG's compact grammar: a sign or a second dot starts the next one")
    func compactNumbers() {
        #expect(SVGPathData.numbers(in: "a1 1 0 0 0-1-1") == [1, 1, 0, 0, 0, -1, -1])
        #expect(SVGPathData.numbers(in: "a.25.25 0 0 1-.48 0") == [0.25, 0.25, 0, 0, 1, -0.48, 0])
        #expect(SVGPathData.numbers(in: "h-7.9a2 2 0 0 1-1.69-.9") == [-7.9, 2, 2, 0, 0, 1, -1.69, -0.9])
        #expect(SVGPathData.numbers(in: "M1e2,3") == [100, 3])
    }

    @Test("pairs after a moveto are linetos (Lucide's polylines)")
    func implicitLineto() {
        let box = SVGPathData.path("M4 17 10 11 4 5").boundingRect
        #expect(close(box.minX, 4) && close(box.maxX, 10))
        #expect(close(box.minY, 5) && close(box.maxY, 17))
    }

    @Test("a relative quarter arc lands where the SVG says, and stays inside its corner")
    func quarterArc() {
        // The corner of git-pull-request: 13,6 → 16,6, quarter turn to 18,8, down to 18,13.
        let box = SVGPathData.path("M13 6h3a2 2 0 0 1 2 2v7").boundingRect
        #expect(close(box.minX, 13) && close(box.maxX, 18))
        #expect(close(box.minY, 6) && close(box.maxY, 13))
        var arcOnly = Path()
        arcOnly.move(to: CGPoint(x: 16, y: 6))
        SVGPathData.addArc(to: &arcOnly, from: CGPoint(x: 16, y: 6), to: CGPoint(x: 18, y: 8),
                           rx: 2, ry: 2, rotation: 0, largeArc: false, sweep: true)
        #expect(arcOnly.currentPoint.map { close($0.x, 18) && close($0.y, 8) } == true)
    }

    @Test("every glyph draws inside the 24-unit grid")
    func glyphsInGrid() {
        for glyph in LucideIcon.Glyph.allCases {
            let box = LucideShape.gridPath(glyph).boundingRect
            #expect(!box.isEmpty, "\(glyph) draws something")
            #expect(box.minX >= 1.9 && box.minY >= 1.9 && box.maxX <= 22.1 && box.maxY <= 22.1, "\(glyph): \(box)")
        }
    }

    @Test("the shape scales the grid to its rect")
    func scales() {
        let box = LucideShape(glyph: .layoutGrid).path(in: CGRect(x: 0, y: 0, width: 48, height: 48)).boundingRect
        #expect(close(box.minX, 6) && close(box.maxX, 42))
    }
}
