import Testing
import LoomCore
import LoomPersistence
import Foundation

// Seam : l'interface publique de SessionStore, sur une vraie base SQLite en
// dossier temporaire — migrations comprises (DAT-02 : versionnées dès la v1).

@Suite("SessionStore — persistance GRDB")
struct SessionStoreTests {

    private func makeStore() throws -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-db-\(UUID().uuidString.prefix(8)).sqlite")
        return try SessionStore(path: url.path)
    }

    @Test("une session persiste et se relit intacte (aller-retour complet)")
    func allerRetourSession() throws {
        let store = try makeStore()
        let id = SessionID()
        let record = SessionRecord(id: id, title: "Corriger le cache", agentID: "claude-code",
                                   state: .working, branch: "loom/corrige-cache",
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

    @Test("l'historique navigateur : visites enregistrées, suggestions par préfixe (WEB-01)")
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
                "préfixe respecté, plus récent d'abord")
        #expect(try store.historySuggestions(prefix: "https://exemple.fr").isEmpty)
    }

    @Test("recherche plein texte : titres ET transcripts, via FTS5 (SES-08)")
    func recherchePleinTexte() throws {
        let store = try makeStore()
        let cache = SessionID()
        let deploy = SessionID()
        try store.insert(SessionRecord(id: cache, title: "Corriger le bug de cache",
                                       agentID: "claude-code", state: .completed, createdAt: Date()))
        try store.insert(SessionRecord(id: deploy, title: "Déployer en préproduction",
                                       agentID: "claude-code", state: .completed, createdAt: Date()))
        try store.indexForSearch(session: cache, title: "Corriger le bug de cache",
                                 transcript: "l'invalidation par TTL était approximative")
        try store.indexForSearch(session: deploy, title: "Déployer en préproduction",
                                 transcript: "kubectl apply réussi, pods verts")

        #expect(try store.searchSessions(matching: "cache") == [cache], "match sur le titre")
        #expect(try store.searchSessions(matching: "kubectl") == [deploy], "match sur le transcript")
        #expect(try store.searchSessions(matching: "invalidation") == [cache])
        #expect(try store.searchSessions(matching: "introuvable-xyz").isEmpty)
        #expect(try store.searchSessions(matching: "\"guillemets\" spéciaux*").isEmpty,
                "une requête avec caractères spéciaux FTS ne fait jamais d'erreur")
    }

    @Test("projets : insertion, rattachement des sessions, archivage sans toucher au dossier (PRJ-01/03/06)")
    func projets() throws {
        let store = try makeStore()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-projet-\(UUID().uuidString.prefix(8))")
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
                "la session connaît son projet (regroupement PRJ-03)")

        try store.archiveProject(projectID)
        #expect(try store.activeProjects().isEmpty, "archivé : le projet sort des listes")
        #expect(FileManager.default.fileExists(atPath: folder.path),
                "PRJ-06 : l'app ne détruit JAMAIS le dossier source de l'utilisateur")
    }

    @Test("renommer une session persiste (SES-05)")
    func renommage() throws {
        let store = try makeStore()
        let id = SessionID()
        try store.insert(SessionRecord(id: id, title: "dbdd-a3f2", agentID: "claude-code",
                                       state: .working, createdAt: Date()))
        try store.rename(session: id, to: "Corrige le cache Redis")
        #expect(try store.session(id: id)?.title == "Corrige le cache Redis")
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
