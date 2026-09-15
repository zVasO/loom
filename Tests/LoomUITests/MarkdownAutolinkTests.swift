import Testing
import LoomUI
import Foundation

// Seam: what a PR body renders as a link. Foundation's CommonMark parser has
// no autolink extension, GitHub's flavour does — everything below is about
// closing that gap without breaking what the parser already got right.

@Suite("MarkdownBlocks — links inside a block")
struct MarkdownAutolinkTests {

    private func links(_ text: String) -> [String] {
        let string = MarkdownBlocks.inline(text)
        return string.runs.compactMap { $0.link?.absoluteString }
    }

    @Test func uneURLNueDevientUnLien() {
        #expect(links("voir https://example.com/a ici") == ["https://example.com/a"])
    }

    @Test func lesLiensMarkdownRestentIntacts() {
        #expect(links("voir [ici](https://example.com/a)") == ["https://example.com/a"])
    }

    @Test func leTexteDUnLienMarkdownNEstPasReLinkifie() {
        // The visible text is a URL and the target is another: re-detecting it
        // would silently retarget the link the author wrote.
        let found = links("[https://shown.example](https://real.example)")
        #expect(found == ["https://real.example"])
    }

    @Test func unNomDeFichierNEstPasUnLien() {
        #expect(links("regarde AppModel.swift ligne 12").isEmpty)
    }

    @Test func leTexteEstPreserve() {
        #expect(String(MarkdownBlocks.inline("voir https://example.com ici").characters)
            == "voir https://example.com ici")
    }
}
