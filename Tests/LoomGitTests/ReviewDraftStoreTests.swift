import Testing
import Foundation
@testable import LoomGit

// A review is written comment by comment and sent once: the drafts wait on
// disk, keyed by PR, and leave together with the verdict.
@Suite("ReviewDraft — comments that wait for the verdict")
struct ReviewDraftStoreTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-review-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a draft comes back with its comments, its head, and its order")
    func roundTrip() throws {
        let directory = try makeDirectory()
        let store = ReviewDraftStore(directory: directory)
        let first = DraftComment(path: "a.swift", firstLine: 3, lastLine: 5, body: "Why?")
        let second = DraftComment(path: "b.swift", firstLine: 9, lastLine: 9, side: "LEFT",
                                  body: "```suggestion\nx\n```")
        store.save(["p#1": ReviewDraft(headSHA: "abc", comments: [first, second])])

        let loaded = try #require(ReviewDraftStore(directory: directory).load()["p#1"])
        #expect(loaded.headSHA == "abc")
        #expect(loaded.comments.map(\.id) == [first.id, second.id])
        #expect(loaded.comments.map(\.path) == ["a.swift", "b.swift"])
        #expect(loaded.comments[1].side == "LEFT")
        #expect(loaded.comments[1].isSuggestion)
        #expect(!loaded.comments[0].isSuggestion)
    }

    @Test("an emptied draft is not written back — the file holds only live reviews")
    func emptyDraftsDropped() throws {
        let directory = try makeDirectory()
        let store = ReviewDraftStore(directory: directory)
        store.save(["p#1": ReviewDraft(headSHA: "abc", comments: []),
                    "p#2": ReviewDraft(headSHA: "abc", comments: [
                        DraftComment(path: "a", firstLine: 1, lastLine: 1, body: "x")])])
        #expect(store.load().keys.sorted() == ["p#2"])
    }

    @Test("adding and removing keep the head; a range never ends before it starts")
    func editing() {
        let comment = DraftComment(path: "a", firstLine: 8, lastLine: 2, body: "x")
        #expect(comment.firstLine == 8 && comment.lastLine == 8)
        let draft = ReviewDraft(headSHA: "h").adding(comment)
        #expect(draft.comments.count == 1)
        #expect(draft.removing(comment.id).isEmpty)
        #expect(draft.removing(UUID()).comments.count == 1)
    }

    @Test("comments are found by the line they hang under, on their side")
    func anchoring() {
        let a = DraftComment(path: "a", firstLine: 3, lastLine: 5, body: "x")
        let b = DraftComment(path: "a", firstLine: 5, lastLine: 5, side: "LEFT", body: "y")
        let draft = ReviewDraft(headSHA: "h", comments: [a, b])
        #expect(draft.comments(path: "a", line: 5, side: "RIGHT") == [a])
        #expect(draft.comments(path: "a", line: 5, side: "LEFT") == [b])
        #expect(draft.comments(path: "a", line: 3, side: "RIGHT").isEmpty)
        #expect(draft.comments(path: "b", line: 5, side: "RIGHT").isEmpty)
    }

    @Test("a missing or corrupt file is no draft, not a failure")
    func disposable() throws {
        let directory = try makeDirectory()
        #expect(ReviewDraftStore(directory: directory).load().isEmpty)
        try Data("nope".utf8).write(to: directory.appendingPathComponent("pr-review-drafts.json"))
        #expect(ReviewDraftStore(directory: directory).load().isEmpty)
    }
}
