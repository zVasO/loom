import Testing
import LoomCore
@testable import LoomPersistence
import Foundation

// Seam: SessionStore's public interface, on a real SQLite database in a
// temporary directory — migrations included (DAT-02: versioned from v1).

@Suite("SessionStore — GRDB persistence")
struct SessionStoreTests {

    private func makeStore() throws -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-db-\(UUID().uuidString.prefix(8)).sqlite")
        return try SessionStore(path: url.path)
    }

    @Test("a session persists and reads back intact (full round-trip)")
    func allerRetourSession() throws {
        let store = try makeStore()
        let id = SessionID()
        let record = SessionRecord(id: id, title: "Fix the cache", agentID: "claude-code",
                                   state: .working, branch: "loom/fix-cache",
                                   worktreePath: "/tmp/wt", createdAt: Date(timeIntervalSince1970: 1000))
        try store.insert(record)

        let fetched = try store.session(id: id)
        #expect(fetched == record)
        #expect(try store.allSessions().count == 1)
    }

    @Test("a session references at most one native conversation — the imposed one by default")
    func sessionNativeAllerRetour() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "t", agentID: "claude-code",
                                       state: .working, createdAt: Date()))
        let fresh = try #require(try store.session(id: id))
        #expect(fresh.nativeSessionID == nil, "nothing switched: the column stays NULL")
        #expect(fresh.resolvedNativeSessionID == id, "NULL resolves to the imposed UUID")

        let native = SessionID()
        try store.updateNativeSession(session: id, to: native)
        #expect(try store.session(id: id)?.nativeSessionID == native)
        #expect(try store.session(id: id)?.resolvedNativeSessionID == native)
        #expect(try store.allSessions().first?.nativeSessionID == native,
                "the list query carries it too")

        try store.updateNativeSession(session: id, to: nil)
        #expect(try store.session(id: id)?.nativeSessionID == nil,
                "nil restores the imposed conversation")

        let seeded = SessionRecord(id: SessionID(), title: "u", agentID: "claude-code",
                                   state: .interrupted, createdAt: Date(timeIntervalSince1970: 2000),
                                   nativeSessionID: native)
        try store.insert(seeded)
        #expect(try store.session(id: seeded.id) == seeded, "the record round-trips with its native id")
    }

    @Test("a session wears several badges, in assignment order, and reads them back")
    func plusieursBadges() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "t", agentID: "claude-code",
                                       state: .working, createdAt: Date(),
                                       badges: ["PR #42", "review"]))
        #expect(try store.session(id: id)?.badges == ["PR #42", "review"],
                "badges land with the insert and come back in order")
        #expect(try store.allSessions().first?.badges == ["PR #42", "review"],
                "the list query carries them too")

        try store.setBadges(session: id, badges: ["review", " urgent ", "review", ""])
        #expect(try store.session(id: id)?.badges == ["review", "urgent"],
                "a replacement keeps its order; duplicates and blanks never land")

        try store.setBadges(session: id, badges: [])
        #expect(try store.session(id: id)?.badges == [], "an empty list clears them")
    }

    @Test("each session reads only its own badges")
    func badgesParSession() throws {
        let store = try makeStore()
        let kept = SessionID(), other = SessionID()
        try store.insert(SessionRecord(id: kept, title: "kept", agentID: "claude-code",
                                       state: .working, createdAt: Date(), badges: ["wip"]))
        try store.insert(SessionRecord(id: other, title: "other", agentID: "claude-code",
                                       state: .working, createdAt: Date(), badges: ["wip", "urgent"]))
        #expect(try store.session(id: kept)?.badges == ["wip"],
                "each session reads only its own badges")
        #expect(try store.session(id: other)?.badges == ["wip", "urgent"])
    }

    @Test("the badge catalog starts with the built-ins, then belongs to the user (v8)")
    func catalogueDeBadges() throws {
        let store = try makeStore()
        #expect(try store.badgeDefinitions() == BadgeDefinition.builtIn,
                "a fresh database seeds the three built-ins, in order")

        try store.saveBadgeDefinitions([
            BadgeDefinition(name: "urgent", colorHex: "#E5646C"),
            BadgeDefinition(name: " perf ", colorHex: "#4CC38A"),
            BadgeDefinition(name: "urgent", colorHex: "#000000"),
            BadgeDefinition(name: "", colorHex: "#FFFFFF"),
        ])
        #expect(try store.badgeDefinitions().map(\.name) == ["urgent", "perf"],
                "a save replaces the catalog in the given order; blanks and repeats never land")
        #expect(try store.badgeDefinitions().first?.colorHex == "#E5646C",
                "the first occurrence of a name keeps its color")

        #expect(try store.addBadgeDefinition(BadgeDefinition(name: "docs", colorHex: "#A78BFA")),
                "a new name joins the catalog")
        #expect(try !store.addBadgeDefinition(BadgeDefinition(name: "docs", colorHex: "#111111")),
                "a taken name is refused")
        #expect(try store.badgeDefinitions().map(\.name) == ["urgent", "perf", "docs"],
                "an addition lands last, the refusal changes nothing")

        try store.saveBadgeDefinitions([])
        #expect(try store.badgeDefinitions().isEmpty, "the user may empty the catalog")
    }

    @Test("the transition journal keeps the history, source included (STA-06)")
    func journalDesTransitions() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "t", agentID: "claude-code",
                                       state: .starting, createdAt: Date()))

        try store.recordTransition(session: id, from: .starting, to: .working,
                                   source: .hook, at: Date(timeIntervalSince1970: 2000))
        try store.recordTransition(session: id, from: .working, to: .needsInput,
                                   source: .hook, at: Date(timeIntervalSince1970: 3000))

        let journal = try store.transitions(session: id)
        #expect(journal.count == 2)
        #expect(journal[0].to == .working)
        #expect(journal[1].to == .needsInput)
        #expect(journal[1].source == .hook, "the source of each transition is journaled")
    }

    @Test("on relaunch, live sessions become interrupted (NFR-R, UC-7)")
    func marquageInterruptedAuRelancement() throws {
        let store = try makeStore()
        let working = SessionID()
        let done = SessionID()
        try store.insert(SessionRecord(id: working, title: "live", agentID: "claude-code",
                                       state: .working, createdAt: Date()))
        try store.insert(SessionRecord(id: done, title: "finished", agentID: "claude-code",
                                       state: .completed, createdAt: Date()))

        let marked = try store.markLiveSessionsInterrupted()

        #expect(marked == 1, "only live sessions are marked")
        #expect(try store.session(id: working)?.state == .interrupted, "Resume candidate")
        #expect(try store.session(id: done)?.state == .completed, "terminal states do not move")
    }

    @Test("browser history: visits recorded, suggestions by prefix (WEB-01)")
    func historiqueNavigateur() throws {
        let store = try makeStore()
        try store.recordVisit(url: "https://github.com/vaso/loom/pulls", title: "Pull requests",
                              at: Date(timeIntervalSince1970: 1000))
        try store.recordVisit(url: "https://docs.swift.org/swift-book", title: "Swift Book",
                              at: Date(timeIntervalSince1970: 2000))
        try store.recordVisit(url: "https://github.com/vaso/loom", title: "loom",
                              at: Date(timeIntervalSince1970: 3000))

        let suggestions = try store.historySuggestions(prefix: "https://github.com")
        #expect(suggestions.map(\.url) == ["https://github.com/vaso/loom",
                                           "https://github.com/vaso/loom/pulls"],
                "prefix honored, most recent first")
        #expect(try store.historySuggestions(prefix: "https://example.org").isEmpty)
    }

    @Test("projects: insert, session attachment, archive without touching the folder (PRJ-01/03/06)")
    func projets() throws {
        let store = try makeStore()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-project-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let projectID = ProjectID()
        try store.insertProject(ProjectRecord(id: projectID, name: "loom",
                                              path: folder.path, defaultBranch: "main",
                                              createdAt: Date()))
        #expect(try store.activeProjects().map(\.id) == [projectID])

        let session = SessionID()
        try store.insert(SessionRecord(id: session, title: "t", agentID: "claude-code",
                                       state: .working, projectID: projectID, createdAt: Date()))
        #expect(try store.session(id: session)?.projectID == projectID,
                "the session knows its project (PRJ-03 grouping)")

        try store.archiveProject(projectID)
        #expect(try store.activeProjects().isEmpty, "archived: the project leaves the lists")
        #expect(FileManager.default.fileExists(atPath: folder.path),
                "PRJ-06: the app NEVER destroys the user's source folder")
    }

    @Test("renaming a session persists (SES-05)")
    func renommage() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "dbdd-a3f2", agentID: "claude-code",
                                       state: .working, createdAt: Date()))
        try store.rename(session: id, to: "Fix the Redis cache")
        #expect(try store.session(id: id)?.title == "Fix the Redis cache")
    }

    @Test("persisted state follows updates")
    func miseAJourDEtat() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "t", agentID: "claude-code",
                                       state: .starting, createdAt: Date()))
        try store.updateState(session: id, to: .completed, exitCode: 0, endedAt: Date())
        let fetched = try store.session(id: id)
        #expect(fetched?.state == .completed)
        #expect(fetched?.exitCode == 0)
        #expect(fetched?.endedAt != nil)
    }
}

@Suite("Full-text transcript search (v2)")
struct TranscriptSearchTests {

    /// On disk, like the app: a WAL pool, not the in-memory queue. The
    /// database (and its -wal/-shm) is removed once the body returns — these
    /// tests index megabytes, which used to accumulate in the temp folder.
    private func withStore(_ body: (SessionStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-fts-\(UUID().uuidString.prefix(8)).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        try body(try SessionStore(path: url.path))
    }

    @Test("a word in a transcript yields the session with a highlighted snippet")
    func snippetSearch() throws {
        let store = try SessionStore(path: ":memory:")
        let alpha = SessionID(), beta = SessionID()
        try store.insert(SessionRecord(id: alpha, title: "Fix payment bug", agentID: "claude-code",
                                       state: .completed, createdAt: Date()))
        try store.insert(SessionRecord(id: beta, title: "Refactor onboarding", agentID: "claude-code",
                                       state: .completed, createdAt: Date()))
        try store.indexForSearch(session: alpha, title: "Fix payment bug",
                                 transcript: "The stripe webhook retries were failing because of a stale signature")
        try store.indexForSearch(session: beta, title: "Refactor onboarding",
                                 transcript: "Moved the signup flow into its own module")
        let hits = try store.searchTranscripts(matching: "webhook")
        #expect(hits.count == 1)
        #expect(hits.first?.id == alpha)
        #expect(hits.first?.title == "Fix payment bug")
        #expect(hits.first?.snippet.contains("webhook") == true)
    }

    @Test("an empty or quote-only query yields nothing, never an FTS error")
    func sanitizedQuery() throws {
        let store = try SessionStore(path: ":memory:")
        #expect(try store.searchTranscripts(matching: "  \"\"  ").isEmpty)
    }

    // The startup pass compares the transcript on disk with what the FTS row
    // was built from, and re-indexes only on a change — replacing the row,
    // never doubling it.
    @Test("an index remembers its fingerprint, and a re-index replaces the FTS row")
    func empreinteDIndex() throws {
        try withStore { store in
            let id = SessionID()
            try store.insert(SessionRecord(id: id, title: "Payments", agentID: "claude-code",
                                           state: .completed, createdAt: Date()))
            #expect(try store.indexedFingerprint(session: id) == nil, "never indexed")

            let first = SessionStore.IndexFingerprint(bytes: 120, modifiedAt: 1_700_000_000)
            try store.indexForSearch(session: id, title: "Payments",
                                     transcript: "the webhook signature was stale", fingerprint: first)
            #expect(try store.indexedFingerprint(session: id) == first)

            let second = SessionStore.IndexFingerprint(bytes: 240, modifiedAt: 1_700_000_100)
            try store.indexForSearch(session: id, title: "Payments",
                                     transcript: "the webhook signature was stale, then rotated", fingerprint: second)
            #expect(try store.indexedFingerprint(session: id) == second)
            let hits = try store.searchTranscripts(matching: "webhook")
            #expect(hits.count == 1, "one FTS row per session, whatever the number of re-indexes")
            #expect(hits.first?.snippet.contains("rotated") == true, "the row is the latest transcript")
        }
    }

    // The property the on-disk store claims: a reader never queues behind
    // the writer. Proved by holding a write open and reading through it —
    // fifty reads racing five writes passed on a serial queue too.
    @Test("the on-disk store reads while a write is held open (a WAL pool, not one serial connection)")
    func lecturesPendantEcriture() throws {
        try withStore { store in
            let id = SessionID()
            try store.insert(SessionRecord(id: id, title: "Long", agentID: "claude-code",
                                           state: .completed, createdAt: Date()))
            let held = DispatchSemaphore(value: 0)      // the writer is parked inside its transaction
            let release = DispatchSemaphore(value: 0)   // the test lets it commit
            let writer = Thread {
                _ = try? store.database.write { _ in
                    held.signal()
                    release.wait()
                }
            }
            writer.start()
            defer {
                release.signal()
                while !writer.isFinished { Thread.sleep(forTimeInterval: 0.005) }
            }
            #expect(held.wait(timeout: .now() + 5) == .success, "the writer never entered its transaction")

            // On a WAL pool the read comes back at once, from a reader
            // connection; on a serial queue it would wait for the parked
            // writer — so it runs on its own thread, against a deadline.
            let read = ReadSlot()
            let done = DispatchSemaphore(value: 0)
            let reader = Thread {
                read.title = try? store.session(id: id)?.title
                done.signal()
            }
            reader.start()
            #expect(done.wait(timeout: .now() + 2) == .success,
                    "the read waited for the held write: one serial connection, not a WAL pool")
            #expect(read.title == "Long")
        }
    }
}

/// A slot a reader thread fills: a captured `var` cannot be written from a
/// `@Sendable` closure, a class can.
private final class ReadSlot: @unchecked Sendable {
    var title: String?
}
