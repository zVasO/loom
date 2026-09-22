import AppKit
import Foundation
import Highlightr
import LoomGit
import SwiftUI

/// Syntax colours for a diff's lines, keyed by file, side and line number —
/// what `SplitDiffView` looks up per row. A value: computed once, off the
/// main thread, after the diff itself; the view paints plain text until it
/// arrives and swaps the colours in.
public struct DiffHighlights: Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public let path: String
        public let isOld: Bool
        public let number: Int
        public init(path: String, isOld: Bool, number: Int) {
            self.path = path
            self.isOld = isOld
            self.number = number
        }
    }

    public var lines: [Key: AttributedString]
    public init(lines: [Key: AttributedString] = [:]) { self.lines = lines }

    public static let none = DiffHighlights()

    public func line(path: String, isOld: Bool, number: Int?) -> AttributedString? {
        guard let number else { return nil }
        return lines[Key(path: path, isOld: isOld, number: number)]
    }
}

/// highlight.js (through Highlightr's JavaScriptCore bridge) over the diff.
/// Each hunk is highlighted per SIDE as one document — old = context +
/// deletions, new = context + additions — so a multi-line comment or string
/// keeps its colour across lines; the result is split back into lines.
public enum DiffHighlighter {
    /// Past these a file paints plain: highlight.js is linear but not free,
    /// and a generated file is not what a reviewer reads.
    public static let maxLinesPerFile = 5000
    public static let maxBytesPerFile = 500_000

    /// One JavaScriptCore context per call. Call off the main thread; prefer
    /// `SharedHighlighters` when the same process highlights more than once.
    public static func highlight(_ files: [DiffParser.File], dark: Bool) -> DiffHighlights {
        guard let highlightr = Highlightr() else { return .none }
        return highlight(files, dark: dark, using: highlightr)
    }

    /// With a caller-owned instance. Highlightr is not thread-safe: the
    /// caller serialises its use.
    public static func highlight(_ files: [DiffParser.File], dark: Bool,
                                 using highlightr: Highlightr) -> DiffHighlights {
        highlightr.ignoreIllegals = true
        if !highlightr.setTheme(to: dark ? "atom-one-dark" : "atom-one-light") {
            _ = highlightr.setTheme(to: dark ? "github-dark" : "github")
        }
        let supported = Set(highlightr.supportedLanguages())
        var result = DiffHighlights()
        for file in files {
            guard let language = language(forPath: file.path), supported.contains(language),
                  fitsBudget(file) else { continue }
            for hunk in file.hunks {
                for isOld in [true, false] {
                    let lines = hunk.lines.filter { isOld ? $0.kind != .addition : $0.kind != .deletion }
                    guard !lines.isEmpty else { continue }
                    let code = lines.map(\.text).joined(separator: "\n")
                    guard let attributed = highlightr.highlight(code, as: language, fastRender: true),
                          let split = split(attributed, expectedLines: lines.count)
                    else { continue }
                    for (line, coloured) in zip(lines, split) {
                        guard let number = isOld ? line.oldNumber : line.newNumber else { continue }
                        result.lines[.init(path: file.path, isOld: isOld, number: number)] = coloured
                    }
                }
            }
        }
        return result
    }

    static func fitsBudget(_ file: DiffParser.File) -> Bool {
        let lines = file.hunks.reduce(0) { $0 + $1.lines.count }
        guard lines <= maxLinesPerFile else { return false }
        let bytes = file.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.text.utf8.count } }
        return bytes <= maxBytesPerFile
    }

    /// highlight.js language for a path, by extension or well-known name.
    /// nil = paint plain: a wrong guess colours keywords that are not.
    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let known = byName[name] { return known }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return byExtension[ext]
    }

    private static let byName: [String: String] = [
        "makefile": "makefile", "dockerfile": "dockerfile", "cmakelists.txt": "cmake",
        "package.swift": "swift", "podfile": "ruby", "gemfile": "ruby", "rakefile": "ruby",
        "brewfile": "ruby", ".zshrc": "bash", ".bashrc": "bash", ".bash_profile": "bash",
        ".gitignore": "plaintext", "cargo.lock": "toml", "go.mod": "go", "justfile": "makefile",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift", "m": "objectivec", "mm": "objectivec", "h": "objectivec",
        "c": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "py": "python", "pyi": "python", "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "kts": "kotlin", "scala": "scala", "cs": "csharp", "fs": "fsharp",
        "php": "php", "pl": "perl", "pm": "perl", "lua": "lua", "dart": "dart", "ex": "elixir",
        "exs": "elixir", "erl": "erlang", "hs": "haskell", "clj": "clojure", "ml": "ocaml",
        "r": "r", "jl": "julia", "zig": "zig", "nim": "nim", "groovy": "groovy",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ps1": "powershell",
        "sql": "sql", "graphql": "graphql", "gql": "graphql", "proto": "protobuf",
        "json": "json", "jsonc": "json", "json5": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "env": "bash", "properties": "ini",
        "xml": "xml", "plist": "xml", "xib": "xml", "storyboard": "xml", "svg": "xml",
        "html": "xml", "htm": "xml", "vue": "xml", "svelte": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "md": "markdown", "markdown": "markdown", "rst": "plaintext", "txt": "plaintext",
        "diff": "diff", "patch": "diff", "cmake": "cmake", "mk": "makefile", "gradle": "gradle",
        "tf": "hcl", "hcl": "hcl", "nix": "nix", "vim": "vim", "tex": "latex", "bib": "latex",
        "strings": "ini", "entitlements": "xml", "pbxproj": "plaintext", "metal": "cpp",
    ]

    /// The highlighted document cut back into its lines, colours only — the
    /// view owns font and size. nil when the count does not match the input
    /// (a trailing newline eaten, an unterminated construct): plain then.
    static func split(_ attributed: NSAttributedString, expectedLines: Int) -> [AttributedString]? {
        let text = attributed.string
        var lines: [AttributedString] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        func flush(_ end: String.Index) {
            let range = NSRange(lineStart..<end, in: text)
            lines.append(colours(of: attributed, in: range))
        }
        while index < text.endIndex {
            if text[index] == "\n" {
                flush(index)
                lineStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        flush(text.endIndex)
        guard lines.count == expectedLines else { return nil }
        return lines
    }

    /// Foreground colours of a range, as SwiftUI attributes; the text itself
    /// is the diff's, untouched.
    private static func colours(of attributed: NSAttributedString, in range: NSRange) -> AttributedString {
        var result = AttributedString()
        attributed.enumerateAttribute(.foregroundColor, in: range) { value, runRange, _ in
            var run = AttributedString(attributed.attributedSubstring(from: runRange).string)
            if let color = value as? NSColor {
                run.swiftUI.foregroundColor = Color(nsColor: color)
            }
            result.append(run)
        }
        return result
    }
}

/// One Highlightr per colour scheme, reused for every diff: a JSContext and
/// a highlight.js load per call cost 100-300 ms per PR tab (audit 2026-09-22,
/// hot path 8). Highlightr is not thread-safe, so a highlight holds the lock
/// for its duration — calls from different tasks queue, never overlap.
public final class SharedHighlighters: @unchecked Sendable {
    public static let shared = SharedHighlighters()

    private let lock = NSLock()
    private var instances: [Bool: Highlightr] = [:]

    public func highlight(_ files: [DiffParser.File], dark: Bool) -> DiffHighlights {
        lock.lock()
        defer { lock.unlock() }
        if instances[dark] == nil { instances[dark] = Highlightr() }
        guard let highlightr = instances[dark] else { return .none }
        return DiffHighlighter.highlight(files, dark: dark, using: highlightr)
    }
}
