import SwiftUI

/// Block-level markdown for PR descriptions and comments.
///
/// `AttributedString(markdown:)`'s full parser flattens lists and swallows
/// line breaks; its inline-only mode leaves `##`, `-` and `>` as literal
/// text. So: a small PURE block splitter (the tested seam), with the inline
/// mode still doing bold/code/links INSIDE each block.
public enum MarkdownBlocks {

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bullets(items: [String])
        case ordered(start: Int, items: [String])
        case quote(text: String)
        case code(text: String, language: String)
        case rule
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var orderedStart = 1
        var quote: [String] = []
        var fence: [String]?
        var fenceLanguage = ""

        /// Flushes every accumulator except `kept` — consecutive same-kind
        /// lines group into a single block.
        enum Accumulator { case paragraph, bullets, ordered, quote, none }
        func flush(keeping kept: Accumulator = .none) {
            if kept != .paragraph, !paragraph.isEmpty {
                blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if kept != .bullets, !bullets.isEmpty {
                blocks.append(.bullets(items: bullets))
                bullets = []
            }
            if kept != .ordered, !ordered.isEmpty {
                blocks.append(.ordered(start: orderedStart, items: ordered))
                ordered = []
            }
            if kept != .quote, !quote.isEmpty {
                blocks.append(.quote(text: quote.joined(separator: "\n")))
                quote = []
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = fence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(text: open.joined(separator: "\n"),
                                        language: fenceLanguage))
                    fence = nil
                } else {
                    open.append(line)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                fence = []
                fenceLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty { flush(); continue }
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
            if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
                flush(keeping: .bullets)
                bullets.append(String(trimmed.dropFirst(marker.count)))
                continue
            }
            if let item = orderedItem(trimmed) {
                if ordered.isEmpty { flush(keeping: .ordered); orderedStart = item.number }
                ordered.append(item.text)
                continue
            }
            if trimmed.hasPrefix(">") {
                flush(keeping: .quote)
                quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
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

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(line[line.startIndex..<dot]) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.first == " " else { return nil }
        return (number, String(rest.dropFirst()))
    }
}

/// Renders parsed blocks with the theme's typography; bold/code/links inside
/// each block go through the inline AttributedString parser as before.
public struct MarkdownBlockView: View {
    private let blocks: [MarkdownBlocks.Block]

    public init(_ text: String) {
        blocks = MarkdownBlocks.parse(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5,
                              weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
        case .bullets(let items):
            list(items, marker: { _ in "•" })
        case .ordered(let start, let items):
            list(items, marker: { "\(start + $0)." })
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DefaultTheme.accent.opacity(0.6))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text, let language):
            // GitHub's appliable suggestions deserve to look like one.
            let isSuggestion = language == "suggestion"
            VStack(alignment: .leading, spacing: 0) {
                if isSuggestion {
                    Text("SUGGESTED CHANGE")
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.7)
                        .foregroundStyle(DefaultTheme.groupHeader)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DefaultTheme.groupHeader.opacity(0.12))
                }
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSuggestion ? DefaultTheme.groupHeader.opacity(0.06)
                                             : DefaultTheme.surfaceRaised)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        case .rule:
            Rectangle().fill(DefaultTheme.cardBorder).frame(height: 1)
        }
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 7) {
                    Text(marker(index))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text(Self.inline(item))
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
                }
            }
        }
    }
}
