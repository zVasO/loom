import Testing
import LoomCore
import LoomPersistence
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

    @Test("full-text search: titles AND transcripts, via FTS5 (SES-08)")
    func recherchePleinTexte() throws {
        let store = try makeStore()
        let cache = SessionID()
        let deploy = SessionID()
        try store.insert(SessionRecord(id: cache, title: "Fix the cache bug",
                                       agentID: "claude-code", state: .completed, createdAt: Date()))
        try store.insert(SessionRecord(id: deploy, title: "Deploy to staging",
                                       agentID: "claude-code", state: .completed, createdAt: Date()))
        try store.indexForSearch(session: cache, title: "Fix the cache bug",
                                 transcript: "TTL invalidation was too approximate")
        try store.indexForSearch(session: deploy, title: "Deploy to staging",
                                 transcript: "kubectl apply succeeded, pods green")

        #expect(try store.searchSessions(matching: "cache") == [cache], "match on the title")
        #expect(try store.searchSessions(matching: "kubectl") == [deploy], "match on the transcript")
        #expect(try store.searchSessions(matching: "invalidation") == [cache])
        #expect(try store.searchSessions(matching: "notfound-xyz").isEmpty)
        #expect(try store.searchSessions(matching: "\"quoted\" special*").isEmpty,
                "a query with special FTS characters never errors")
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
}
