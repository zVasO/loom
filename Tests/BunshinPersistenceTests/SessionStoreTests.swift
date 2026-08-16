import Testing
import BunshinCore
import BunshinPersistence
import Foundation

// Seam : l'interface publique de SessionStore, sur une vraie base SQLite en
// dossier temporaire — migrations comprises (DAT-02 : versionnées dès la v1).

@Suite("SessionStore — persistance GRDB")
struct SessionStoreTests {

    private func makeStore() throws -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-db-\(UUID().uuidString.prefix(8)).sqlite")
        return try SessionStore(path: url.path)
    }

    @Test("une session persiste et se relit intacte (aller-retour complet)")
    func allerRetourSession() throws {
        let store = try makeStore()
        let id = SessionID()
        let record = SessionRecord(id: id, title: "Corriger le cache", agentID: "claude-code",
                                   state: .working, branch: "bunshin/corrige-cache",
                                   worktreePath: "/tmp/wt", createdAt: Date(timeIntervalSince1970: 1000))
        try store.insert(record)

        let fetched = try store.session(id: id)
        #expect(fetched == record)
        #expect(try store.allSessions().count == 1)
    }

    @Test("le journal des transitions garde l'histoire, source comprise (STA-06)")
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
        #expect(journal[1].source == .hook, "la source de chaque transition est journalisée")
    }

    @Test("au relancement, les sessions vivantes deviennent interrupted (NFR-R, UC-7)")
    func marquageInterruptedAuRelancement() throws {
        let store = try makeStore()
        let working = SessionID()
        let done = SessionID()
        try store.insert(SessionRecord(id: working, title: "vivante", agentID: "claude-code",
                                       state: .working, createdAt: Date()))
        try store.insert(SessionRecord(id: done, title: "finie", agentID: "claude-code",
                                       state: .completed, createdAt: Date()))

        let marked = try store.markLiveSessionsInterrupted()

        #expect(marked == 1, "seules les sessions vivantes sont marquées")
        #expect(try store.session(id: working)?.state == .interrupted, "candidate à la Reprise")
        #expect(try store.session(id: done)?.state == .completed, "les états terminaux ne bougent pas")
    }

    @Test("l'état persisté suit les mises à jour")
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
