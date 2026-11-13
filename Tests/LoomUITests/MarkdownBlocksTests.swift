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

    // MARK: What claude's answers lean on, beyond a PR description

    private typealias Item = MarkdownBlocks.ListItem

    @Test("a pipe table becomes a table: header, alignments, rows of raw cells")
    func table() {
        let blocks = MarkdownBlocks.parse("""
        Before

        | Name | Count | Note |
        |:-----|------:|:----:|
        | `a\\|b` | 1 | **x** |
        | c | 2 |
        after
        """)
        let expected: [MarkdownBlocks.Block] = [
            .paragraph(text: "Before"),
            .table(header: ["Name", "Count", "Note"],
                   alignments: [.leading, .trailing, .center],
                   rows: [["`a|b`", "1", "**x**"], ["c", "2", ""]]),
            .paragraph(text: "after"),
        ]
        #expect(blocks == expected, "a short row is padded, an escaped pipe stays in its cell")
    }

    @Test("a table needs no outer pipes")
    func tableWithoutOuterPipes() {
        let blocks = MarkdownBlocks.parse("Name | Count\n--- | ---\na | 1")
        let expected: [MarkdownBlocks.Block] = [
            .table(header: ["Name", "Count"], alignments: [.leading, .leading], rows: [["a", "1"]]),
        ]
        #expect(blocks == expected)
    }

    @Test("pipes without the row of dashes stay a sentence, and a bare --- stays a rule")
    func pipesAloneAreText() {
        let sentence: [MarkdownBlocks.Block] = [.paragraph(text: "a | b\nc | d")]
        #expect(MarkdownBlocks.parse("a | b\nc | d") == sentence)
        let ruled: [MarkdownBlocks.Block] = [.paragraph(text: "a | b"), .rule, .paragraph(text: "c")]
        #expect(MarkdownBlocks.parse("a | b\n---\nc") == ruled)
    }

    @Test("a row is cut at its pipes, the outer ones dropped and the escaped ones kept")
    func tableCells() {
        #expect(MarkdownBlocks.tableCells("| a | b |") == ["a", "b"])
        #expect(MarkdownBlocks.tableCells("a |  | c") == ["a", "", "c"])
        #expect(MarkdownBlocks.tableCells(#"| x \| y | \*z |"#) == ["x | y", #"\*z"#])
        let alignments: [MarkdownBlocks.ColumnAlignment]? = [.leading, .center, .trailing]
        #expect(MarkdownBlocks.tableAlignments("|---|:-:|--:|") == alignments)
        #expect(MarkdownBlocks.tableAlignments("---") == nil, "no pipe: a rule")
        #expect(MarkdownBlocks.tableAlignments("| a | b |") == nil)
    }

    @Test("an indented item keeps its level instead of flattening")
    func nestedBullets() {
        let expected: [MarkdownBlocks.Block] = [.bullets(items: [
            "a",
            Item("b", level: 1, marker: .bullet),
            Item("c", level: 2, marker: .bullet),
            Item("d", level: 1, marker: .bullet),
            "e",
        ])]
        #expect(MarkdownBlocks.parse("- a\n  - b\n    - c\n  - d\n- e") == expected)
        let tabbed: [MarkdownBlocks.Block] = [.bullets(items: [
            "a",
            Item("b", level: 1, marker: .bullet),
            Item("c", level: 2, marker: .bullet),
        ])]
        #expect(MarkdownBlocks.parse("- a\n\t- b\n\t\t- c") == tabbed, "a tab is a level")
    }

    @Test("a nested item says what it is: bullets under numbers, numbers counted from their first")
    func nestedKinds() {
        let underNumbers: [MarkdownBlocks.Block] = [.ordered(start: 1, items: [
            "one",
            Item("x", level: 1, marker: .bullet),
            Item("y", level: 1, marker: .bullet),
            "two",
            Item("p", level: 1, marker: .number(1)),
            Item("q", level: 1, marker: .number(2)),
        ])]
        #expect(MarkdownBlocks.parse("1. one\n   - x\n   - y\n2. two\n   1. p\n   2. q") == underNumbers)
        let underBullets: [MarkdownBlocks.Block] = [.bullets(items: [
            "a",
            Item("x", level: 1, marker: .number(3)),
            Item("y", level: 1, marker: .number(4)),
            Item("z", level: 1, marker: .bullet),
            Item("w", level: 1, marker: .number(1)),
        ])]
        #expect(MarkdownBlocks.parse("- a\n  3. x\n  7. y\n  - z\n  1. w") == underBullets,
                "a run counts from its first number, and a bullet ends the run")
    }

    @Test("nesting stops at three levels under the list")
    func nestingIsCapped() {
        let expected: [MarkdownBlocks.Block] = [.bullets(items: [
            "a",
            Item("b", level: 1, marker: .bullet),
            Item("c", level: 2, marker: .bullet),
            Item("d", level: 3, marker: .bullet),
            Item("e", level: 3, marker: .bullet),
            Item("f", level: 3, marker: .bullet),
        ])]
        #expect(MarkdownBlocks.parse("- a\n  - b\n    - c\n      - d\n        - e\n          - f") == expected)
    }

    @Test("a line indented under an item is the item's; one that is not ends the list")
    func continuationLines() {
        let expected: [MarkdownBlocks.Block] = [
            .bullets(items: ["a\nmore of a", "b"]),
            .paragraph(text: "not b"),
        ]
        #expect(MarkdownBlocks.parse("- a\n  more of a\n- b\nnot b") == expected)
    }

    @Test("after a blank line, only what is indented stays in the list")
    func looseLists() {
        let paragraphs: [MarkdownBlocks.Block] = [
            .ordered(start: 1, items: ["a\n\nabout a"]),
            .ordered(start: 2, items: ["b"]),
        ]
        #expect(MarkdownBlocks.parse("1. a\n\n   about a\n\n2. b") == paragraphs,
                "the second list keeps its number")
        let nested: [MarkdownBlocks.Block] = [
            .bullets(items: ["a", Item("b", level: 1, marker: .bullet)]),
            .bullets(items: ["c"]),
        ]
        #expect(MarkdownBlocks.parse("- a\n\n  - b\n\n- c") == nested)
    }

    @Test("the other kind of marker at the list's own level starts another list")
    func mixedMarkers() {
        let expected: [MarkdownBlocks.Block] = [
            .bullets(items: ["a"]),
            .ordered(start: 1, items: ["b", "c"]),
            .bullets(items: ["d"]),
        ]
        #expect(MarkdownBlocks.parse("- a\n1. b\n2. c\n- d") == expected)
    }

    @Test("task items carry their box, ticked or not, instead of literal brackets")
    func taskItems() {
        let expected: [MarkdownBlocks.Block] = [.bullets(items: [
            Item("todo", marker: .task(done: false)),
            Item("done", marker: .task(done: true)),
            Item("also done", marker: .task(done: true)),
            "plain",
            Item("nested", level: 1, marker: .task(done: false)),
        ])]
        #expect(MarkdownBlocks.parse("- [ ] todo\n- [x] done\n- [X] also done\n- plain\n  - [ ] nested") == expected)
    }

    @Test("each item shows a bullet, its number, or nothing where a box is drawn")
    func markerLabels() {
        let items: [Item] = [
            "one",
            Item("x", level: 1, marker: .bullet),
            "two",
            Item("p", level: 1, marker: .number(1)),
            Item("t", level: 1, marker: .task(done: true)),
        ]
        #expect(MarkdownBlocks.markerLabels(of: items, start: 3) == ["3.", "•", "4.", "1.", ""])
        #expect(MarkdownBlocks.markerLabels(of: items, start: nil) == ["•", "•", "•", "1.", ""])
    }

    @Test("a ~~~ fence holds backtick fences, and a longer fence holds a shorter one")
    func tildeAndLongFences() {
        let tilde: [MarkdownBlocks.Block] = [.code(text: "```swift\nlet a = 1\n```", language: "md")]
        #expect(MarkdownBlocks.parse("~~~md\n```swift\nlet a = 1\n```\n~~~") == tilde)
        let four: [MarkdownBlocks.Block] = [.code(text: "```\ninner\n```", language: "")]
        #expect(MarkdownBlocks.parse("````\n```\ninner\n```\n````") == four)
        let unclosed: [MarkdownBlocks.Block] = [.code(text: "code", language: "")]
        #expect(MarkdownBlocks.parse("~~~\ncode") == unclosed)
    }

    @Test("a fence under a list item gives its code back without the item's indentation")
    func indentedFence() {
        let expected: [MarkdownBlocks.Block] = [
            .ordered(start: 1, items: ["Run:"]),
            .code(text: "swift build\n  --flag", language: "sh"),
            .ordered(start: 2, items: ["Then"]),
        ]
        #expect(MarkdownBlocks.parse("1. Run:\n   ```sh\n   swift build\n     --flag\n   ```\n2. Then") == expected)
    }

    @Test("three backticks around inline code do not open a fence")
    func inlineBackticks() {
        let expected: [MarkdownBlocks.Block] = [.paragraph(text: "```a``` and b\nnext")]
        #expect(MarkdownBlocks.parse("```a``` and b\nnext") == expected)
    }

    @Test("sizes are the charter's at 12 and in proportion elsewhere, to the half point")
    func fontSizes() {
        #expect(MarkdownBlocks.fontSize(12, forBody: 12) == 12)
        #expect(MarkdownBlocks.fontSize(11.5, forBody: 12) == 11.5)
        #expect(MarkdownBlocks.fontSize(13.5, forBody: 12) == 13.5)
        #expect(MarkdownBlocks.fontSize(12, forBody: 13) == 13)
        #expect(MarkdownBlocks.fontSize(11.5, forBody: 13) == 12.5)
        #expect(MarkdownBlocks.fontSize(15, forBody: 13) == 16.5)
        #expect(MarkdownBlocks.fontSize(13.5, forBody: 13) == 14.5)
        #expect(MarkdownBlocks.fontSize(12.5, forBody: 13) == 13.5)
    }
}
