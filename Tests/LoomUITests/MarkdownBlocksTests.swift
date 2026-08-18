import Testing
@testable import LoomUI

// Seam: the pure block parser behind PR descriptions/comments — headings,
// lists, quotes and code fences must become structure, not literal ## and -.
@Suite("MarkdownBlocks — block-level parsing")
struct MarkdownBlocksTests {

    @Test("headings, paragraphs and bullet lists are split into blocks")
    func headingsAndLists() {
        let blocks = MarkdownBlocks.parse("""
        ## What

        A disposable PR.

        ## Covers

        - first item
        - second item
        """)
        #expect(blocks == [
            .heading(level: 2, text: "What"),
            .paragraph(text: "A disposable PR."),
            .heading(level: 2, text: "Covers"),
            .bullets(items: ["first item", "second item"]),
        ])
    }

    @Test("ordered lists keep their starting number")
    func orderedList() {
        let blocks = MarkdownBlocks.parse("""
        1. open the tab
        2. pick this PR
        3. start a review
        """)
        #expect(blocks == [.ordered(start: 1,
                                    items: ["open the tab", "pick this PR", "start a review"])])
    }

    @Test("quotes group and code fences keep their content verbatim")
    func quotesAndFences() {
        let blocks = MarkdownBlocks.parse("""
        > Close without merging
        > when done.

        ```sh
        swift build -c release
        ```
        """)
        #expect(blocks == [
            .quote(text: "Close without merging\nwhen done."),
            .code(text: "swift build -c release", language: "sh"),
        ])
    }

    @Test("consecutive paragraph lines stay one block, preserving line breaks")
    func paragraphLineBreaks() {
        let blocks = MarkdownBlocks.parse("line one\nline two\n\nother paragraph")
        #expect(blocks == [
            .paragraph(text: "line one\nline two"),
            .paragraph(text: "other paragraph"),
        ])
    }

    @Test("a horizontal rule becomes a rule block")
    func rule() {
        #expect(MarkdownBlocks.parse("above\n\n---\n\nbelow") == [
            .paragraph(text: "above"), .rule, .paragraph(text: "below"),
        ])
    }
}
