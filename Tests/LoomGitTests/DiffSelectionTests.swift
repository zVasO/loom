import Testing
import LoomGit

// Seam: turning "the user dragged from here to there" into the code that
// travels to claude or to a GitHub comment. Pure — the view only supplies
// two row identifiers.
@Suite("DiffSelection — from a dragged range to code")
struct DiffSelectionTests {

    private var files: [DiffFileRows] {
        DiffFileRows.compute(DiffParser.parse("""
        diff --git a/alpha.swift b/alpha.swift
        --- a/alpha.swift
        +++ b/alpha.swift
        @@ -1,3 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 20
        +let c = 3
        diff --git a/beta.swift b/beta.swift
        --- a/beta.swift
        +++ b/beta.swift
        @@ -10,2 +10,3 @@
         func run() {
        +    print("hi")
        """))
    }

    @Test("the fixture parses into two files")
    func fixture() {
        #expect(files.count == 2)
        #expect(files[0].file.path == "alpha.swift")
        #expect(files[1].file.path == "beta.swift")
    }

    @Test("a range inside one hunk yields one span with its real line numbers")
    func singleHunk() {
        let spans = DiffSelection.spans(
            in: files,
            from: DiffSelection.RowID(file: 0, hunk: 0, row: 0),
            to: DiffSelection.RowID(file: 0, hunk: 0, row: 1))
        #expect(spans.count == 1)
        #expect(spans[0].file == "alpha.swift")
        #expect(spans[0].code.contains("let a = 1"))
        #expect(spans[0].code.contains("- let b = 2"), "deletions keep their marker")
        #expect(spans[0].code.contains("+ let b = 20"))
    }

    @Test("a range spanning two files yields one span per file, in document order")
    func acrossFiles() {
        let spans = DiffSelection.spans(
            in: files,
            from: DiffSelection.RowID(file: 0, hunk: 0, row: 2),
            to: DiffSelection.RowID(file: 1, hunk: 0, row: 1))
        #expect(spans.map(\.file) == ["alpha.swift", "beta.swift"])
        #expect(spans[0].code.contains("let c = 3"))
        #expect(spans[1].code.contains("func run()"))
        #expect(spans[1].code.contains("print"))
        #expect(spans[1].firstLine == 10, "each file keeps its own numbering")
    }

    @Test("dragging upwards selects the same rows as dragging down")
    func reversedDrag() {
        let down = DiffSelection.spans(in: files,
                                       from: DiffSelection.RowID(file: 0, hunk: 0, row: 0),
                                       to: DiffSelection.RowID(file: 1, hunk: 0, row: 0))
        let up = DiffSelection.spans(in: files,
                                     from: DiffSelection.RowID(file: 1, hunk: 0, row: 0),
                                     to: DiffSelection.RowID(file: 0, hunk: 0, row: 0))
        #expect(down == up)
    }

    @Test("a collapsed file is skipped — its rows are not on screen to be dragged over")
    func collapsedFileSkipped() {
        let spans = DiffSelection.spans(
            in: files,
            from: DiffSelection.RowID(file: 0, hunk: 0, row: 0),
            to: DiffSelection.RowID(file: 1, hunk: 0, row: 1),
            skipping: ["alpha.swift"])
        #expect(spans.map(\.file) == ["beta.swift"])
    }

    @Test("row identifiers order like the document: file, then hunk, then row")
    func ordering() {
        let first = DiffSelection.RowID(file: 0, hunk: 1, row: 9)
        let second = DiffSelection.RowID(file: 1, hunk: 0, row: 0)
        #expect(first < second)
        #expect(DiffSelection.RowID(file: 0, hunk: 0, row: 1)
                < DiffSelection.RowID(file: 0, hunk: 1, row: 0))
    }

    @Test("an out-of-bounds identifier yields nothing instead of crashing")
    func outOfBounds() {
        let spans = DiffSelection.spans(in: files,
                                        from: DiffSelection.RowID(file: 0, hunk: 0, row: 0),
                                        to: DiffSelection.RowID(file: 9, hunk: 9, row: 99))
        #expect(spans.map(\.file) == ["alpha.swift", "beta.swift"], "clamped, not crashed")
    }
}
