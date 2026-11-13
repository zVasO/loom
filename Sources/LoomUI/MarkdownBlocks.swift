import AppKit
import Foundation
import LoomCore
import SwiftUI

/// Block-level markdown for PR descriptions, review comments and what
/// claude answers in the chat view.
///
/// `AttributedString(markdown:)`'s full parser flattens lists and swallows
/// line breaks; its inline-only mode leaves `##`, `-` and `>` as literal
/// text. So: a small PURE block splitter (the tested seam), with the inline
/// mode still doing bold/code/links INSIDE each block.
public enum MarkdownBlocks {

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bullets(items: [ListItem])
        case ordered(start: Int, items: [ListItem])
        case quote(text: String)
        case code(text: String, language: String)
        case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
        case rule
    }

    /// One item of a list. A string literal is an item of the list itself
    /// with the list's own marker — what every item was before lists nested.
    public struct ListItem: Equatable, Sendable, ExpressibleByStringLiteral {
        public enum Marker: Equatable, Sendable {
            /// The list's own: a bullet in `.bullets`, the next number in `.ordered`.
            case plain
            /// A nested item says what it is: the list around it may be of the other kind.
            case bullet
            /// A nested numbered item, with the number it reads.
            case number(Int)
            /// "- [ ]" and "- [x]".
            case task(done: Bool)
        }

        public var text: String
        /// 0 for an item of the list itself, up to `maxNesting` under it.
        public var level: Int
        public var marker: Marker

        public init(_ text: String, level: Int = 0, marker: Marker = .plain) {
            self.text = text
            self.level = level
            self.marker = marker
        }

        public init(stringLiteral value: String) {
            self.init(value)
        }
    }

    public enum ColumnAlignment: Equatable, Sendable {
        case leading, center, trailing
    }

    /// How deep a list nests before deeper items stay at the last level.
    public static let maxNesting = 3

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var listIsOrdered = false
        var orderedStart = 1
        /// The indentation of each level open in the list being read, the list's own first.
        var listIndents: [Int] = []
        /// The next number of a nested numbered run, by level.
        var nestedNumbers: [Int: Int] = [:]
        /// A blank line was met inside the list: the list ends there unless
        /// what follows is indented under it.
        var listGap = false
        var quote: [String] = []
        var fence: [String]?
        var fenceLanguage = ""
        var fenceMarker: Character = "`"
        var fenceLength = 3
        var fenceIndent = 0

        /// Flushes every accumulator except `kept` — consecutive same-kind
        /// lines group into a single block.
        enum Accumulator { case paragraph, list, quote, none }
        func flush(keeping kept: Accumulator = .none) {
            if kept != .paragraph, !paragraph.isEmpty {
                blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if kept != .list, !list.isEmpty {
                if listIsOrdered {
                    blocks.append(.ordered(start: orderedStart, items: list))
                } else {
                    blocks.append(.bullets(items: list))
                }
                list = []
                listIndents = []
                nestedNumbers = [:]
            }
            if kept != .quote, !quote.isEmpty {
                blocks.append(.quote(text: quote.joined(separator: "\n")))
                quote = []
            }
        }

        let lines: [String] = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = fence {
                if closesFence(trimmed, marker: fenceMarker, length: fenceLength) {
                    blocks.append(.code(text: open.joined(separator: "\n"),
                                        language: fenceLanguage))
                    fence = nil
                } else {
                    open.append(droppingIndentation(line, columns: fenceIndent))
                    fence = open
                }
                continue
            }
            if trimmed.isEmpty {
                if list.isEmpty { flush() } else { listGap = true }
                continue
            }
            let indent = indentation(of: line)
            let afterGap = listGap
            if listGap {
                listGap = false
                if indent < (listIndents.first ?? 0) + 2 { flush() }
            }
            if let opening = fenceOpening(trimmed) {
                flush()
                fence = []
                fenceLanguage = opening.language
                fenceMarker = opening.marker
                fenceLength = opening.length
                // A fence under a list item is indented with it: its code is not.
                fenceIndent = indent
                continue
            }
            // A table is its header AND the row of dashes under it: pipes
            // alone are a sentence with pipes in it.
            if trimmed.contains("|"), index < lines.count {
                let header = tableCells(trimmed)
                if !header.isEmpty, let alignments = tableAlignments(lines[index]),
                   alignments.count == header.count {
                    flush()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard row.contains("|") else { break }
                        var cells = tableCells(row)
                        if cells.count > header.count { cells.removeLast(cells.count - header.count) }
                        while cells.count < header.count { cells.append("") }
                        rows.append(cells)
                        index += 1
                    }
                    blocks.append(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" })
            if (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " {
                flush()
                blocks.append(.heading(
                    level: hashes.count,
                    text: String(trimmed.dropFirst(hashes.count + 1))))
                continue
            }
            if let item = listItem(trimmed) {
                let isOrdered = item.number != nil
                var level = 0
                if list.isEmpty {
                    flush(keeping: .list)
                    listIndents = [indent]
                } else {
                    level = nestingLevel(of: indent, in: &listIndents)
                    // At the list's own level, the other kind of marker starts another list.
                    if level == 0, isOrdered != listIsOrdered {
                        flush()
                        listIndents = [indent]
                    }
                }
                if list.isEmpty {
                    listIsOrdered = isOrdered
                    orderedStart = item.number ?? 1
                }
                // A numbered run ends where an item above it begins.
                nestedNumbers = nestedNumbers.filter { $0.key <= level }
                var marker = ListItem.Marker.plain
                if let done = item.done {
                    marker = .task(done: done)
                    nestedNumbers[level] = nil
                } else if level > 0 {
                    if let number = item.number {
                        // Markdown reads the first number of a run and counts from it.
                        let next = nestedNumbers[level] ?? number
                        nestedNumbers[level] = next + 1
                        marker = .number(next)
                    } else {
                        nestedNumbers[level] = nil
                        marker = .bullet
                    }
                }
                list.append(ListItem(item.text, level: level, marker: marker))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush(keeping: .quote)
                quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
                continue
            }
            // Indented under an item, a line is the item's own.
            if !list.isEmpty, indent >= (listIndents.first ?? 0) + 2 {
                list[list.count - 1].text += (afterGap ? "\n\n" : "\n") + trimmed
                continue
            }
            flush(keeping: .paragraph)
            paragraph.append(trimmed)
        }
        if let open = fence {   // unclosed fence: honest, render what we have
            blocks.append(.code(text: open.joined(separator: "\n"), language: fenceLanguage))
        }
        flush()
        return blocks
    }

    /// Inline markdown, plus the links CommonMark leaves on the floor.
    ///
    /// Foundation's parser has no autolink extension and GitHub's flavour
    /// does, so a URL pasted bare into a PR body arrives here as dead text.
    public static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        autolink(&result)
        return result
    }

    private static func autolink(_ string: inout AttributedString) {
        for range in BareURL.ranges(in: string.characters) {
            guard string[range].link == nil,
                  let url = URL(string: String(string.characters[range]))
            else { continue }
            string[range].link = url
        }
    }

    /// Attributes set on the run itself, not on the enclosing `Text`: the
    /// blocks tint their whole body, which would otherwise swallow the link.
    public static func styled(_ string: AttributedString, accent: Color) -> AttributedString {
        var string = string
        for range in string.runs.filter({ $0.link != nil }).map(\.range) {
            string[range].foregroundColor = accent
            string[range].underlineStyle = .single
        }
        return string
    }

    /// The size of a text the charter sets at `charter` points beside a
    /// 12 pt body, when the body is `size`: the charter's own at 12, else in
    /// proportion, to the half point.
    public static func fontSize(_ charter: CGFloat, forBody size: CGFloat) -> CGFloat {
        guard size != 12 else { return charter }
        return (charter * size / 12 * 2).rounded() / 2
    }

    /// What each item of a list shows before its text: a bullet, its number
    /// with a dot, nothing for a task (a box is drawn there). `start` is the
    /// first number of a numbered list, nil for a bulleted one.
    public static func markerLabels(of items: [ListItem], start: Int?) -> [String] {
        var labels: [String] = []
        var next = start ?? 1
        for item in items {
            switch item.marker {
            case .plain:
                if start == nil {
                    labels.append("•")
                } else {
                    labels.append("\(next).")
                    next += 1
                }
            case .bullet:
                labels.append("•")
            case .number(let number):
                labels.append("\(number).")
            case .task:
                labels.append("")
            }
        }
        return labels
    }

    /// The cells of a table's row: cut at each pipe that is not escaped, the
    /// row's own outer pipes dropped.
    static func tableCells(_ row: String) -> [String] {
        let row = row.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var endsOnPipe = false
        for character in row {
            if escaped {
                // "\|" is a pipe in the cell; any other escape is the inline parser's.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
                endsOnPipe = false
            } else if character == "\\" {
                escaped = true
                endsOnPipe = false
            } else if character == "|" {
                cells.append(cell)
                cell = ""
                endsOnPipe = true
            } else {
                cell.append(character)
                endsOnPipe = false
            }
        }
        if escaped { cell.append("\\") }
        if !endsOnPipe { cells.append(cell) }
        if row.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The alignment of each column when `line` is the row of dashes under a
    /// table's header ("| --- | :-: | --: |"), nil when it is anything else.
    static func tableAlignments(_ line: String) -> [ColumnAlignment]? {
        let line = line.trimmingCharacters(in: .whitespaces)
        // Without a pipe, a row of dashes is a rule.
        guard line.contains("|") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [ColumnAlignment] = []
        for cell in cells {
            var dashes = Substring(cell)
            let leading = dashes.hasPrefix(":")
            if leading { dashes = dashes.dropFirst() }
            let trailing = dashes.hasSuffix(":")
            if trailing { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if leading && trailing {
                alignments.append(.center)
            } else if trailing {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    /// A list item's line without its marker: a bullet ("- ", "* ", "+ "),
    /// a task ("- [ ] ", "- [x] ") or a number ("3. ", "3) ").
    private static func listItem(_ line: String) -> (text: String, number: Int?, done: Bool?)? {
        if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
            let text = String(line.dropFirst(marker.count))
            if text.hasPrefix("[ ] ") {
                return (String(text.dropFirst(4)), nil, false)
            }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                return (String(text.dropFirst(4)), nil, true)
            }
            return (text, nil, nil)
        }
        if let item = orderedItem(line) {
            return (item.text, item.number, nil)
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(line[line.startIndex..<dot]) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.first == " " else { return nil }
        return (number, String(rest.dropFirst()))
    }

    /// The columns a line is indented by; a tab counts for four.
    private static func indentation(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return columns
    }

    /// `line` without the indentation of the fence it belongs to — never
    /// more than that: the code's own indentation stays.
    private static func droppingIndentation(_ line: String, columns: Int) -> String {
        guard columns > 0 else { return line }
        var remaining = columns
        var index = line.startIndex
        while remaining > 0, index < line.endIndex {
            let character = line[index]
            if character == " " {
                remaining -= 1
            } else if character == "\t" {
                remaining -= 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// How deep an item indented by `indent` columns sits in the list whose
    /// open levels are indented by `open`: two columns more than the level
    /// above open a new one, whatever the width people indent by (2, 3 under
    /// "1.", 4, a tab).
    private static func nestingLevel(of indent: Int, in open: inout [Int]) -> Int {
        while open.count > 1, indent < open[open.count - 1] {
            open.removeLast()
        }
        guard let innermost = open.last else {
            open = [indent]
            return 0
        }
        if indent >= innermost + 2, open.count <= maxNesting {
            open.append(indent)
        }
        return open.count - 1
    }

    /// The line that opens a fence: three or more backticks or tildes, then
    /// the language. CommonMark's rule for backticks keeps "```a``` and b"
    /// a sentence with inline code instead of a fence that never closes.
    private static func fenceOpening(_ line: String) -> (marker: Character, length: Int, language: String)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let run = line.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        let language = String(line.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        if marker == "`", language.contains("`") { return nil }
        return (marker, run.count, language)
    }

    /// A fence closes on its own character, at least as many as opened it
    /// and nothing else: a "~~~" block can then hold "```", and four
    /// backticks can hold three.
    private static func closesFence(_ line: String, marker: Character, length: Int) -> Bool {
        let run = line.prefix(while: { $0 == marker })
        return run.count >= length && run.count == line.count
    }
}

/// SwiftUI rebuilds `MarkdownBlockView` on every render of its parent, and both
/// the block split and `AttributedString(markdown:)` are pure functions of their
/// input. This bounded cache makes each distinct string pay for them once
/// instead of once per frame. Neither depends on the text size: the font is
/// the view's, so one entry serves every size.
private enum MarkdownCache {
    struct InlineKey: Hashable {
        let text: String
        let accent: Color
    }

    private static let lock = NSLock()
    private static var parsed: [String: [MarkdownBlocks.Block]] = [:]
    private static var rendered: [InlineKey: AttributedString] = [:]
    /// A full flush is cheaper than tracking recency, and the next render
    /// repopulates only what is actually on screen.
    private static let limit = 256

    static func blocks(for text: String) -> [MarkdownBlocks.Block] {
        lock.lock()
        if let hit = parsed[text] { lock.unlock(); return hit }
        lock.unlock()
        let value = MarkdownBlocks.parse(text)
        lock.lock()
        if parsed.count >= limit { parsed.removeAll(keepingCapacity: true) }
        parsed[text] = value
        lock.unlock()
        return value
    }

    static func inline(_ text: String, accent: Color) -> AttributedString {
        let key = InlineKey(text: text, accent: accent)
        lock.lock()
        if let hit = rendered[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = MarkdownBlocks.styled(MarkdownBlocks.inline(text), accent: accent)
        lock.lock()
        if rendered.count >= limit { rendered.removeAll(keepingCapacity: true) }
        rendered[key] = value
        lock.unlock()
        return value
    }
}

/// Renders parsed blocks with the theme's typography; bold/code/links inside
/// each block go through the inline AttributedString parser as before.
public struct MarkdownBlockView: View {
    private let blocks: [MarkdownBlocks.Block]
    private let size: CGFloat
    private var codeScrolls = false

    /// `size` is the body's: headings and code keep their proportion to it.
    public init(_ text: String, size: CGFloat = 12) {
        blocks = MarkdownCache.blocks(for: text)
        self.size = size
    }

    /// Code that scrolls sideways instead of wrapping its long lines — for
    /// the chat, where claude answers with code to read as it was written.
    /// A review comment keeps wrapping: its column is narrow and its code short.
    public func scrollingCode(_ scrolls: Bool = true) -> MarkdownBlockView {
        var view = self
        view.codeScrolls = scrolls
        return view
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        MarkdownCache.inline(text, accent: DefaultTheme.accentInk)
    }

    private func font(_ charter: CGFloat) -> CGFloat {
        MarkdownBlocks.fontSize(charter, forBody: size)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .themeFont(size: font(level == 1 ? 15 : level == 2 ? 13.5 : 12.5),
                           weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
                .padding(.top, DefaultTheme.space(4))
        case .paragraph(let text):
            Text(Self.inline(text))
                .themeFont(size: font(12))
                .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
        case .bullets(let items):
            list(items, start: nil)
        case .ordered(let start, let items):
            list(items, start: start)
        case .quote(let text):
            HStack(alignment: .top, spacing: DefaultTheme.space(8)) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DefaultTheme.accent.opacity(0.6))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .themeFont(size: font(12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text, let language):
            MarkdownCodeBlock(text: text, language: language,
                              fontSize: font(11.5), scrolls: codeScrolls)
        case .table(let header, let alignments, let rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows,
                          fontSize: font(12))
        case .rule:
            Rectangle().fill(DefaultTheme.cardBorder).frame(height: 1)
        }
    }

    private func list(_ items: [MarkdownBlocks.ListItem], start: Int?) -> some View {
        let labels: [String] = MarkdownBlocks.markerLabels(of: items, start: start)
        return VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: DefaultTheme.space(7)) {
                    marker(of: item, label: labels[index])
                    Text(Self.inline(item.text))
                        .themeFont(size: font(12))
                        .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
                }
                .padding(.leading, DefaultTheme.space(16) * CGFloat(item.level))
            }
        }
    }

    @ViewBuilder
    private func marker(of item: MarkdownBlocks.ListItem, label: String) -> some View {
        if case .task(let done) = item.marker {
            // A hidden bullet gives the box the height of the item's first
            // line: it sits on that line however far the text wraps.
            ZStack {
                Text("•")
                    .themeFont(size: font(12), weight: .semibold, design: .monospaced)
                    .hidden()
                MarkdownTaskBox(done: done, side: font(11))
            }
        } else {
            Text(label)
                .themeFont(size: font(12), weight: .semibold, design: .monospaced)
                .foregroundStyle(DefaultTheme.secondaryText)
        }
    }
}

/// The box of a task item: read-only, so it is drawn, not a control.
private struct MarkdownTaskBox: View {
    let done: Bool
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: DefaultTheme.radius(3))
            .strokeBorder(DefaultTheme.secondaryText.opacity(done ? 0.9 : 0.6), lineWidth: 1)
            .background(done ? DefaultTheme.wash2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(3)))
            .overlay {
                if done {
                    LucideIcon(.check, size: side - 2, lineWidth: 2.5)
                        .foregroundStyle(DefaultTheme.primaryText)
                }
            }
            .frame(width: side, height: side)
    }
}

/// A fenced block: its language and a Copy button on top, the code under.
private struct MarkdownCodeBlock: View {
    let text: String
    let language: String
    let fontSize: CGFloat
    let scrolls: Bool
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        // GitHub's appliable suggestions deserve to look like one.
        let isSuggestion = language == "suggestion"
        let showsHeader = !isSuggestion && !language.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            if isSuggestion {
                Text("SUGGESTED CHANGE")
                    .themeFont(size: 9, weight: .semibold, kerning: 0.7)
                    .foregroundStyle(DefaultTheme.groupHeader)
                    .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DefaultTheme.groupHeader.opacity(0.12))
            }
            if showsHeader {
                header
            }
            code(topInset: showsHeader ? DefaultTheme.space(2) : DefaultTheme.space(10),
                 fill: isSuggestion ? DefaultTheme.groupHeader.opacity(0.06) : DefaultTheme.surfaceRaised)
        }
        .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        // A block without a language has no header to hold the button: it
        // shows under the pointer, and a one-line block keeps its height.
        .overlay(alignment: .topTrailing) {
            if !showsHeader, hovered || copied {
                copyButton
                    .background(DefaultTheme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
                    .padding(DefaultTheme.space(4))
            }
        }
        .onHover { hovered = $0 }
    }

    private var header: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            Text(language)
                .themeFont(size: 10.5, design: .monospaced)
                .foregroundStyle(DefaultTheme.mutedText)
                .lineLimit(1)
            Spacer(minLength: 0)
            copyButton
        }
        .padding(.leading, DefaultTheme.space(10)).padding(.trailing, DefaultTheme.space(4))
        .frame(height: DefaultTheme.size(24))
        .background(DefaultTheme.surfaceRaised)
    }

    @ViewBuilder
    private func code(topInset: CGFloat, fill: Color) -> some View {
        let label = Text(text)
            .themeFont(size: fontSize, design: .monospaced)
            .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
            .padding(.horizontal, DefaultTheme.space(10))
            .padding(.top, topInset)
            .padding(.bottom, DefaultTheme.space(10))
        if scrolls {
            // The scroll view only when a line is too long: most blocks fit,
            // and a scroll view under the pointer is one more thing between
            // the wheel and the conversation.
            ViewThatFits(in: .horizontal) {
                label
                ScrollView(.horizontal) {
                    label.padding(.bottom, MarkdownScroller.room)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
        } else {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            AppIcon(copied ? "checkmark" : "doc.on.doc", size: 12)
                .foregroundStyle(copied ? DefaultTheme.accentInk : DefaultTheme.secondaryText)
                .frame(width: DefaultTheme.size(20), height: DefaultTheme.size(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            copied = false
        }
    }
}

/// With a mouse plugged in, macOS draws a scroll bar inside the view, over
/// its last line: what scrolls sideways leaves it room.
@MainActor
private enum MarkdownScroller {
    static var room: CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
}

/// A pipe table as a grid: a hairline under the header and between rows.
/// A cell wraps at `cellWidth`; a table wider than its place scrolls sideways
/// rather than squeeze its columns to a word each.
private struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownBlocks.ColumnAlignment]
    let rows: [[String]]
    let fontSize: CGFloat

    private static let cellWidth: CGFloat = 320

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Its columns as wide as their cells, not stretched to the place.
            grid.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                grid.padding(.bottom, MarkdownScroller.room)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                    cellView(text, column: column, isHeader: true)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Rectangle()
                    .fill(index == 0 ? DefaultTheme.line2 : DefaultTheme.line)
                    .frame(height: 1)
                    // The rule takes the grid's width: it does not ask for one.
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                        cellView(text, column: column, isHeader: false)
                    }
                }
            }
        }
    }

    private func cellView(_ text: String, column: Int, isHeader: Bool) -> some View {
        let alignment: MarkdownBlocks.ColumnAlignment = column < alignments.count ? alignments[column] : .leading
        let weight: Font.Weight? = isHeader ? Font.Weight.semibold : nil
        let ink: Color = isHeader ? DefaultTheme.primaryText : DefaultTheme.primaryText.opacity(0.85)
        return Text(MarkdownCache.inline(text, accent: DefaultTheme.accentInk))
            .themeFont(size: fontSize, weight: weight)
            .foregroundStyle(ink)
            .multilineTextAlignment(Self.textAlignment(alignment))
            .padding(.horizontal, DefaultTheme.space(10))
            .padding(.vertical, DefaultTheme.space(6))
            .frame(maxWidth: Self.cellWidth, alignment: Self.frameAlignment(alignment))
    }

    private static func textAlignment(_ alignment: MarkdownBlocks.ColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private static func frameAlignment(_ alignment: MarkdownBlocks.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}
