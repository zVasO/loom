import Testing
import LoomAgents
import LoomCore
import Foundation

// Seam : le parseur pur des .jsonl natifs de claude. Les fixtures reproduisent
// la forme réelle observée (une ligne assistant PAR BLOC de contenu, même usage).

@Suite("UsageLedger — tours facturés depuis le .jsonl natif")
struct UsageLedgerTests {

    private func line(id: String, request: String = "req-1", model: String = "claude-opus-5",
                      ts: String = "2026-09-02T18:13:08.073Z",
                      usage: String = #"{"input_tokens":2,"cache_creation_input_tokens":33041,"cache_read_input_tokens":26576,"output_tokens":260,"cache_creation":{"ephemeral_1h_input_tokens":33041,"ephemeral_5m_input_tokens":0}}"#) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"sess-1","cwd":"/tmp/wt","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":\#(usage)}}"#
    }

    @Test("une ligne par bloc de contenu : trois lignes, un seul tour")
    func dedoublonnage() {
        let jsonl = [line(id: "m1"), line(id: "m1"), line(id: "m1")].joined(separator: "\n")
        let turns = UsageLedger.turns(fromJSONL: jsonl)
        #expect(turns.count == 1)
        #expect(turns.first?.messageID == "m1")
        #expect(turns.first?.requestID == "req-1")
    }

    @Test("la ventilation 5 min / 1 h est lue quand elle existe")
    func ventilationCache() {
        let turn = UsageLedger.turns(fromJSONL: line(id: "m1")).first
        #expect(turn?.input == 2)
        #expect(turn?.cacheWrite1h == 33041)
        #expect(turn?.cacheWrite5m == 0)
        #expect(turn?.cacheRead == 26576)
        #expect(turn?.output == 260)
        #expect(turn?.model == "claude-opus-5")
        #expect(turn?.sessionID == "sess-1")
        #expect(turn?.cwd == "/tmp/wt")
    }

    @Test("sans ventilation, toute la création de cache compte en 5 min")
    func sansVentilation() {
        let usage = #"{"input_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":9}"#
        let turn = UsageLedger.turns(fromJSONL: line(id: "m2", usage: usage)).first
        #expect(turn?.cacheWrite5m == 500)
        #expect(turn?.cacheWrite1h == 0)
    }

    @Test("le timestamp ISO 8601 avec fractions est lu en UTC")
    func horodatage() {
        let turn = UsageLedger.turns(fromJSONL: line(id: "m1", ts: "2026-09-02T18:13:08.073Z")).first
        let expected = Date(timeIntervalSince1970: 1_788_372_788.073)
        #expect(abs((turn?.timestamp.timeIntervalSince1970 ?? 0) - expected.timeIntervalSince1970) < 0.001)
    }

    @Test("lignes ignorées : user, sans usage, sans modèle, synthétique, JSON cassé")
    func lignesIgnorees() {
        let jsonl = """
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","message":{"id":"x","model":"claude-opus-5"}}
        {"type":"assistant","message":{"id":"y","usage":{"output_tokens":1}}}
        {"type":"assistant","timestamp":"2026-09-02T18:13:08Z","message":{"id":"z","model":"<synthetic>","usage":{"output_tokens":1}}}
        not json at all
        \(line(id: "ok"))
        """
        let turns = UsageLedger.turns(fromJSONL: jsonl)
        #expect(turns.map(\.messageID) == ["ok"])
    }

    @Test("deux requêtes distinctes avec le même message.id restent deux tours")
    func memeIdRequetesDifferentes() {
        let jsonl = [line(id: "m1", request: "r1"), line(id: "m1", request: "r2")].joined(separator: "\n")
        #expect(UsageLedger.turns(fromJSONL: jsonl).count == 2)
    }
}
