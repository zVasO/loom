import Foundation

/// Bare URLs — the ones nothing marked up as a link. Shared by the terminal,
/// where output is raw text, and by Markdown rendering, where CommonMark has
/// no autolink extension and GitHub's does.
///
/// Anchored on the scheme ON PURPOSE. A detector that accepts bare hosts turns
/// `AppModel.swift`, `com.apple.dt` and `1.18.0` into links, and a click that
/// opens a browser on a file name is worse than a link nobody spotted.
public enum BareURL {
    private static let schemes = ["https://", "http://"]

    /// Characters that never belong to a URL, whatever the RFC allows: these
    /// are how prose and shells quote one.
    private static let excluded: Set<Character> = ["<", ">", "\"", "'", "`", "{", "}", "|", "\\", "^"]

    /// Trailing punctuation a sentence left behind — never part of the target.
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// Works on any character collection so one scanner serves `[Character]`
    /// cells, a `String`, and an `AttributedString.CharacterView`.
    public static func ranges<C: BidirectionalCollection>(in characters: C) -> [Range<C.Index>]
    where C.Element == Character {
        var result: [Range<C.Index>] = []
        var index = characters.startIndex
        while index < characters.endIndex {
            guard let afterScheme = matchScheme(in: characters, at: index) else {
                index = characters.index(after: index)
                continue
            }
            var end = afterScheme
            while end < characters.endIndex, isURLCharacter(characters[end]) {
                end = characters.index(after: end)
            }
            end = trimTrailing(in: characters, from: afterScheme, to: end)
            guard end > afterScheme else {
                index = afterScheme
                continue
            }
            result.append(index..<end)
            index = end
        }
        return result
    }

    private static func matchScheme<C: BidirectionalCollection>(in characters: C, at index: C.Index) -> C.Index?
    where C.Element == Character {
        for scheme in schemes {
            var cursor = index
            var matched = true
            for expected in scheme {
                guard cursor < characters.endIndex,
                      characters[cursor].lowercased() == String(expected)
                else { matched = false; break }
                cursor = characters.index(after: cursor)
            }
            if matched { return cursor }
        }
        return nil
    }

    private static func isURLCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
            && !excluded.contains(character) && character.asciiValue.map { $0 >= 0x20 } ?? true
    }

    /// Walks back over sentence punctuation, and over closing brackets that
    /// have no opener inside the URL — `(https://ex.com/a)` keeps `/a`, while
    /// `https://ex.com/a_(b)` keeps its own pair.
    private static func trimTrailing<C: BidirectionalCollection>(in characters: C,
                                                                from start: C.Index,
                                                                to end: C.Index) -> C.Index
    where C.Element == Character {
        var end = end
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while end > start {
            let last = characters.index(before: end)
            let character = characters[last]
            if trailing.contains(character) {
                end = last
                continue
            }
            guard let opener = closers[character] else { break }
            let body = characters[start..<last]
            let opened = body.filter { $0 == opener }.count
            let closed = body.filter { $0 == character }.count
            guard opened <= closed else { break }
            end = last
        }
        return end
    }
}
