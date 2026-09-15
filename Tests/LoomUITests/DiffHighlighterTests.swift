import Testing
import AppKit
import SwiftUI
import LoomGit
@testable import LoomUI

// Syntax colours over the diff: the language comes from the path, the
// highlighted hunk is cut back into exactly its lines, and a file too big to
// be read by a human paints plain.
@Suite("DiffHighlighter — colours for the diff's lines")
struct DiffHighlighterTests {

    @Test("the language follows the extension, or a well-known file name")
    func languageDetection() {
        #expect(DiffHighlighter.language(forPath: "Sources/LoomUI/KeyInput.swift") == "swift")
        #expect(DiffHighlighter.language(forPath: "web/app.tsx") == "typescript")
        #expect(DiffHighlighter.language(forPath: "scripts/release.sh") == "bash")
        #expect(DiffHighlighter.language(forPath: "Package.swift") == "swift")
        #expect(DiffHighlighter.language(forPath: "Makefile") == "makefile")
        #expect(DiffHighlighter.language(forPath: "Dockerfile") == "dockerfile")
        #expect(DiffHighlighter.language(forPath: "config.YAML") == "yaml", "case does not matter")
        #expect(DiffHighlighter.language(forPath: "LICENSE") == nil, "no extension: plain")
        #expect(DiffHighlighter.language(forPath: "data.unknownext") == nil, "unknown: plain, never a guess")
    }

    @Test("a highlighted document is cut back into its lines, colours kept, text untouched")
    func splitKeepsLines() throws {
        let document = NSMutableAttributedString(string: "let a = 1\n// note\n\nend")
        document.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3))
        document.addAttribute(.foregroundColor, value: NSColor.green, range: NSRange(location: 10, length: 7))
        let lines = try #require(DiffHighlighter.split(document, expectedLines: 4))
        #expect(lines.map { String($0.characters) } == ["let a = 1", "// note", "", "end"])
        let keyword = try #require(lines[0].runs.first)
        #expect(keyword.swiftUI.foregroundColor != nil, "the keyword keeps its colour")
        #expect(String(lines[0][keyword.range].characters) == "let")
        #expect(lines[3].runs.first?.swiftUI.foregroundColor == nil, "uncoloured text carries no colour")
    }

    @Test("a line count that does not match the input means plain, not misaligned colours")
    func splitRefusesMismatch() {
        let document = NSAttributedString(string: "one\ntwo")
        #expect(DiffHighlighter.split(document, expectedLines: 3) == nil)
    }

    @Test("a file past the budget paints plain")
    func budget() {
        let long = (0..<(DiffHighlighter.maxLinesPerFile + 1)).map {
            DiffParser.Line(kind: .context, text: "x\($0)", oldNumber: $0, newNumber: $0)
        }
        let big = DiffParser.File(path: "a.swift", hunks: [DiffParser.Hunk(header: "@@", lines: long)])
        #expect(!DiffHighlighter.fitsBudget(big))
        let small = DiffParser.File(path: "a.swift",
                                    hunks: [DiffParser.Hunk(header: "@@", lines: Array(long.prefix(3)))])
        #expect(DiffHighlighter.fitsBudget(small))
    }

    @Test("a Swift hunk gets colours on both sides, keyed by the line numbers of each side")
    func highlightsASwiftHunk() {
        let lines = [
            DiffParser.Line(kind: .context, text: "import Foundation", oldNumber: 1, newNumber: 1),
            DiffParser.Line(kind: .deletion, text: "let old = \"a\"", oldNumber: 2, newNumber: nil),
            DiffParser.Line(kind: .addition, text: "let new = \"b\"", oldNumber: nil, newNumber: 2),
        ]
        let file = DiffParser.File(path: "A.swift", hunks: [DiffParser.Hunk(header: "@@", lines: lines)])
        let highlights = DiffHighlighter.highlight([file], dark: true)
        // highlight.js loads from the package's resources: absent (a stripped
        // test bundle), the result is empty and that is the plain fallback.
        guard !highlights.lines.isEmpty else { return }
        let deletion = highlights.line(path: "A.swift", isOld: true, number: 2)
        let addition = highlights.line(path: "A.swift", isOld: false, number: 2)
        #expect(deletion.map { String($0.characters) } == "let old = \"a\"")
        #expect(addition.map { String($0.characters) } == "let new = \"b\"")
        #expect(addition?.runs.contains { $0.swiftUI.foregroundColor != nil } == true, "a keyword is coloured")
        #expect(highlights.line(path: "A.swift", isOld: true, number: 3) == nil)
    }
}
