import Testing
import LoomCore
import LoomPersistence
import Foundation

// Seam : l'index incrémental sur un vrai SQLite temporaire et un faux
// ~/.claude/projects. Le contrat : ne jamais relire ce qui a déjà été consommé,
// ne jamais consommer une ligne à moitié écrite.

@Suite("UsageIndex — index incrémental des .jsonl")
struct UsageIndexTests {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func makeWorld() throws -> (UsageIndex, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-usage-\(UUID().uuidString.prefix(8))")
        let projects = root.appendingPathComponent("projects/-Users-me-app")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let store = try SessionStore(path: root.appendingPathComponent("loom.sqlite").path)
        return (UsageIndex(store: store), root.appendingPathComponent("projects"))
    }

    private func line(id: String, ts: String = "2026-09-02T18:13:08Z", model: String = "claude-opus-5",
                      output: Int = 10) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"s","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":\#(output)}}}"#
    }

    @Test("premier scan : tout est indexé, y compris les sous-dossiers")
    func premierScan() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        try (line(id: "m1") + "\n" + line(id: "m2") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let sub = projects.appendingPathComponent("-Users-me-app/a/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (line(id: "m3") + "\n").write(to: sub.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        let summary = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(summary.filesScanned == 2)
        #expect(summary.turnsAdded == 3)
    }

    @Test("un fichier qui grossit : seuls les nouveaux tours sont ajoutés")
    func fichierQuiGrossit() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        try (line(id: "m1") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try index.refresh(projectsDirectory: projects, calendar: utc)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(id: "m2") + "\n").utf8))
        try handle.close()

        let second = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(second.turnsAdded == 1)
        #expect(try index.dailyTotals(fromDay: "2026-09-01").first?.output == 20)
    }

    @Test("un fichier inchangé n'est pas relu")
    func fichierInchange() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        try (line(id: "m1") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try index.refresh(projectsDirectory: projects, calendar: utc)
        let second = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(second.turnsAdded == 0)
    }

    @Test("une ligne sans retour à la ligne final n'est pas consommée")
    func lignePartielle() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        let full = line(id: "m1") + "\n"
        let partial = String(line(id: "m2").prefix(40))
        try (full + partial).write(to: file, atomically: true, encoding: .utf8)
        let first = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(first.turnsAdded == 1)

        try (full + line(id: "m2") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let second = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(second.turnsAdded == 1, "la ligne complétée est lue au scan suivant")
    }

    @Test("un fichier tronqué est réindexé depuis le début sans doublon")
    func fichierTronque() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        try (line(id: "m1") + "\n" + line(id: "m2") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try index.refresh(projectsDirectory: projects, calendar: utc)
        try (line(id: "m1") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let second = try index.refresh(projectsDirectory: projects, calendar: utc)
        #expect(second.turnsAdded == 0, "m1 est déjà connu : INSERT OR IGNORE")
        #expect(try index.dailyTotals(fromDay: "2026-09-01").first?.output == 20,
                "m2 reste : l'index n'efface jamais un tour (compromis accepté par la spec)")
    }

    @Test("dailyTotals agrège par jour du calendrier donné et par modèle")
    func totauxJournaliers() throws {
        let (index, projects) = try makeWorld()
        let file = projects.appendingPathComponent("-Users-me-app/a.jsonl")
        try [
            line(id: "m1", ts: "2026-09-01T23:30:00Z", model: "claude-opus-5", output: 5),
            line(id: "m2", ts: "2026-09-02T00:30:00Z", model: "claude-opus-5", output: 7),
            line(id: "m3", ts: "2026-09-02T12:00:00Z", model: "claude-fable-5-1", output: 11),
        ].map { $0 + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
        _ = try index.refresh(projectsDirectory: projects, calendar: utc)

        let totals = try index.dailyTotals(fromDay: "2026-09-02")
        #expect(totals.count == 2, "le 1er septembre est exclu")
        #expect(totals.contains(DailyModelTotals(day: "2026-09-02", model: "claude-opus-5",
                                                  input: 1, cacheWrite5m: 2, cacheWrite1h: 0,
                                                  cacheRead: 3, output: 7)))
        #expect(totals.contains(DailyModelTotals(day: "2026-09-02", model: "claude-fable-5-1",
                                                  input: 1, cacheWrite5m: 2, cacheWrite1h: 0,
                                                  cacheRead: 3, output: 11)))
    }

    @Test("dossier absent : rapport vide, pas d'erreur")
    func dossierAbsent() throws {
        let (index, projects) = try makeWorld()
        let summary = try index.refresh(projectsDirectory: projects.appendingPathComponent("nope"), calendar: utc)
        #expect(summary.filesScanned == 0)
        #expect(try index.dailyTotals(fromDay: "2000-01-01").isEmpty)
    }
}
