# Suivi de consommation et coûts estimés — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un bouton `$` dans la barre du haut ouvre une feuille « Usage & estimated costs » calculée depuis tous les `.jsonl` claude locaux, avec un index incrémental persistant.

**Architecture:** Quatre seams purs testés (`ModelPricing`, `UsageLedger`, `UsageIndex`, `UsageReport`) puis une vue SwiftUI + Swift Charts qui ne fait qu'afficher. Le parsing JSONL vit dans LoomAgents à côté de `ClaudeNativeSessions`, l'index GRDB dans LoomPersistence sur `loom.sqlite`, les types purs et la tarification dans LoomCore pour rester testables (LoomApp est un exécutable, donc non testable).

**Tech Stack:** Swift 6.3 (tools 5.10, macOS 14), Swift Testing (`@Suite`/`@Test`/`#expect`), GRDB 7, SwiftUI, Swift Charts.

**Spec:** `docs/superpowers/specs/2026-09-02-usage-costs-design.md`

## Global Constraints

- Code et UI en anglais ; docs, messages de commit et commentaires de test en français (convention du projet depuis la v2).
- Chaque commit se termine par les deux trailers `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` et `Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE`.
- Aucun accès réseau. Table de prix embarquée datée `2026-09-02`.
- Montants en `Decimal`. Jours en calendrier local, clé `yyyy-MM-dd`.
- Dédoublonnage des lignes `assistant` sur `(message.id, requestId)`.
- Lancer les tests avec `swift test --filter <Suite>` ; suite complète `swift test` (131 tests verts avant ce plan).
- Ne jamais utiliser `git stash` nu (worktree partagé).

## Écart assumé par rapport à la spec

`UsageReport` et `DailyModelTotals` vont dans **LoomCore** (pas LoomApp) pour être testés. `UsageIndex` (LoomPersistence) dépend de `UsageLedger` (LoomAgents) : on ajoute `"LoomAgents"` aux dépendances de LoomPersistence dans `Package.swift` (LoomAgents ne dépend que de LoomCore, pas de cycle).

## Fichiers

| Fichier | Rôle |
|---|---|
| Create `Sources/LoomCore/ModelPricing.swift` | Table de prix, résolution de famille, coût d'un tour |
| Create `Sources/LoomCore/UsageTurn.swift` | `UsageTurn`, `DailyModelTotals`, `UsageDay` |
| Create `Sources/LoomCore/UsageReport.swift` | Agrégation fenêtrée et tarifée |
| Create `Sources/LoomAgents/UsageLedger.swift` | JSONL → `[UsageTurn]` dédoublonnés |
| Modify `Sources/LoomAgents/ClaudeNativeSessions.swift:47-66` | `usage(fromJSONL:)` réécrit sur `UsageLedger` |
| Create `Sources/LoomPersistence/UsageIndex.swift` | Index incrémental GRDB |
| Modify `Sources/LoomPersistence/SessionStore.swift:10,66` | `database` interne, migration `v6-usage` |
| Modify `Package.swift:27` | LoomPersistence dépend de LoomAgents |
| Create `Sources/LoomApp/UsageSheet.swift` | La feuille |
| Modify `Sources/LoomApp/ContentView.swift:94,184,264` | état, `.sheet`, bouton `$` |
| Modify `Sources/LoomApp/AppModel.swift:1260` | `usageIndex()` |
| Test `Tests/LoomCoreTests/ModelPricingTests.swift`, `UsageReportTests.swift` | |
| Test `Tests/LoomAgentsTests/UsageLedgerTests.swift`, `ClaudeCodeAdapterTests.swift:100-123` | |
| Test `Tests/LoomPersistenceTests/UsageIndexTests.swift` | |

---

### Task 1: ModelPricing (LoomCore)

**Files:**
- Create: `Sources/LoomCore/ModelPricing.swift`
- Test: `Tests/LoomCoreTests/ModelPricingTests.swift`

**Interfaces:**
- Produces: `ModelRates` (5 `Decimal` USD/MTok), `ModelPricing.asOf: String`, `ModelPricing.family(for:) -> String`, `ModelPricing.rates(for:) -> ModelRates?`, `ModelPricing.cost(input:cacheWrite5m:cacheWrite1h:cacheRead:output:modelID:) -> Decimal?`.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
// Tests/LoomCoreTests/ModelPricingTests.swift
import Testing
import LoomCore
import Foundation

// Seam : la table de prix publique (platform.claude.com, 2026-09-02) et la
// résolution des identifiants de modèle tels que claude les écrit.

@Suite("ModelPricing — tarifs publics")
struct ModelPricingTests {

    @Test("les identifiants datés et l'ordre ancien se ramènent à une famille")
    func familles() {
        #expect(ModelPricing.family(for: "claude-fable-5-1") == "fable-5-1")
        #expect(ModelPricing.family(for: "claude-opus-4-1-20250805") == "opus-4-1")
        #expect(ModelPricing.family(for: "claude-3-5-haiku-20241022") == "haiku-3-5")
        #expect(ModelPricing.family(for: "claude-sonnet-5") == "sonnet-5")
        #expect(ModelPricing.family(for: "Claude-Opus-5") == "opus-5", "insensible à la casse")
    }

    @Test("fable-5-1 lit le cache à 0.025×, fable-5 à 0.1× — la table n'est pas dérivée")
    func lectureCacheFable() {
        #expect(ModelPricing.rates(for: "claude-fable-5-1")?.cacheRead == Decimal(string: "0.25"))
        #expect(ModelPricing.rates(for: "claude-fable-5")?.cacheRead == Decimal(1))
        #expect(ModelPricing.rates(for: "claude-fable-5-1")?.output == Decimal(50))
    }

    @Test("coût d'un tour opus-5 calculé à la main")
    func coutTour() {
        // 1000 in × 5 + 2000 w5m × 6.25 + 500 w1h × 10 + 100000 read × 0.5 + 300 out × 25
        // = 5000 + 12500 + 5000 + 50000 + 7500 = 80000 / 1e6 = 0.08
        let cost = ModelPricing.cost(input: 1000, cacheWrite5m: 2000, cacheWrite1h: 500,
                                     cacheRead: 100_000, output: 300, modelID: "claude-opus-5")
        #expect(cost == Decimal(string: "0.08"))
    }

    @Test("un modèle inconnu ne vaut pas zéro : nil, jamais un chiffre inventé")
    func modeleInconnu() {
        #expect(ModelPricing.rates(for: "claude-unicorn-9") == nil)
        #expect(ModelPricing.cost(input: 1, cacheWrite5m: 0, cacheWrite1h: 0,
                                  cacheRead: 0, output: 0, modelID: "claude-unicorn-9") == nil)
        #expect(ModelPricing.family(for: "claude-unicorn-9") == "unicorn-9")
    }

    @Test("la table est datée")
    func datee() {
        #expect(ModelPricing.asOf == "2026-09-02")
    }
}
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter ModelPricingTests`
Expected: erreur de compilation « cannot find 'ModelPricing' in scope ».

- [ ] **Step 3: Implémenter**

```swift
// Sources/LoomCore/ModelPricing.swift
import Foundation

/// Public list prices, USD per million tokens. Stored explicitly (not derived
/// from multipliers): Fable 5.1 reads its cache at 0.025× where every other
/// model uses 0.1×.
public struct ModelRates: Equatable, Sendable {
    public let input: Decimal
    public let cacheWrite5m: Decimal
    public let cacheWrite1h: Decimal
    public let cacheRead: Decimal
    public let output: Decimal

    public init(input: Decimal, cacheWrite5m: Decimal, cacheWrite1h: Decimal,
                cacheRead: Decimal, output: Decimal) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// Source: https://platform.claude.com/docs/en/about-claude/pricing, read on `asOf`.
public enum ModelPricing {

    public static let asOf = "2026-09-02"

    private static func rates(_ input: String, _ w5: String, _ w1h: String,
                              _ read: String, _ output: String) -> ModelRates {
        ModelRates(input: Decimal(string: input)!, cacheWrite5m: Decimal(string: w5)!,
                   cacheWrite1h: Decimal(string: w1h)!, cacheRead: Decimal(string: read)!,
                   output: Decimal(string: output)!)
    }

    private static let table: [String: ModelRates] = {
        var t: [String: ModelRates] = [:]
        let fable51 = rates("10", "12.50", "20", "0.25", "50")
        let fable5 = rates("10", "12.50", "20", "1", "50")
        let opus = rates("5", "6.25", "10", "0.50", "25")
        let opusLegacy = rates("15", "18.75", "30", "1.50", "75")
        let sonnet5 = rates("2", "2.50", "4", "0.20", "10")
        let sonnet = rates("3", "3.75", "6", "0.30", "15")
        let haiku45 = rates("1", "1.25", "2", "0.10", "5")
        let haiku35 = rates("0.80", "1", "1.60", "0.08", "4")
        for f in ["fable-5-1", "mythos-5-1"] { t[f] = fable51 }
        for f in ["fable-5", "mythos-5"] { t[f] = fable5 }
        for f in ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5"] { t[f] = opus }
        for f in ["opus-4-1", "opus-4"] { t[f] = opusLegacy }
        t["sonnet-5"] = sonnet5
        for f in ["sonnet-4-6", "sonnet-4-5", "sonnet-4"] { t[f] = sonnet }
        t["haiku-4-5"] = haiku45
        t["haiku-3-5"] = haiku35
        return t
    }()

    /// `claude-opus-4-1-20250805` → `opus-4-1`; `claude-3-5-haiku-20241022` → `haiku-3-5`.
    /// Unknown IDs come back normalised the same way (the UI lists them as unpriced).
    public static func family(for modelID: String) -> String {
        var id = modelID.lowercased()
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        // Pre-4 ordering put the version first ("3-5-haiku"): rotate the name to the front.
        if let nameIndex = parts.firstIndex(where: { !$0.allSatisfy(\.isNumber) }), nameIndex > 0 {
            let name = parts.remove(at: nameIndex)
            parts.insert(name, at: 0)
        }
        return parts.joined(separator: "-")
    }

    public static func rates(for modelID: String) -> ModelRates? {
        table[family(for: modelID)]
    }

    /// `nil` when the model is not in the table — never a silent zero.
    public static func cost(input: Int, cacheWrite5m: Int, cacheWrite1h: Int,
                            cacheRead: Int, output: Int, modelID: String) -> Decimal? {
        guard let r = rates(for: modelID) else { return nil }
        let total = Decimal(input) * r.input
            + Decimal(cacheWrite5m) * r.cacheWrite5m
            + Decimal(cacheWrite1h) * r.cacheWrite1h
            + Decimal(cacheRead) * r.cacheRead
            + Decimal(output) * r.output
        return total / 1_000_000
    }
}
```

- [ ] **Step 4: Vérifier le vert**

Run: `swift test --filter ModelPricingTests`
Expected: 5 tests passent.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoomCore/ModelPricing.swift Tests/LoomCoreTests/ModelPricingTests.swift
git commit -m "Tarifs publics par famille de modèle (ModelPricing, table datée 2026-09-02)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE"
```

---

### Task 2: UsageTurn + UsageLedger, et ClaudeNativeSessions dédoublonné

**Files:**
- Create: `Sources/LoomCore/UsageTurn.swift`
- Create: `Sources/LoomAgents/UsageLedger.swift`
- Modify: `Sources/LoomAgents/ClaudeNativeSessions.swift:47-66`
- Test: `Tests/LoomAgentsTests/UsageLedgerTests.swift`
- Modify test: `Tests/LoomAgentsTests/ClaudeCodeAdapterTests.swift:100-123`

**Interfaces:**
- Produces: `UsageTurn` (LoomCore), `DailyModelTotals` (LoomCore), `UsageDay.key(for:calendar:) -> String`, `UsageDay.date(forKey:calendar:) -> Date?`, `UsageLedger.turns(fromJSONL:) -> [UsageTurn]` (LoomAgents).

- [ ] **Step 1: Types purs dans LoomCore**

```swift
// Sources/LoomCore/UsageTurn.swift
import Foundation

/// One billed assistant turn as claude records it in its native .jsonl.
public struct UsageTurn: Equatable, Sendable {
    public let messageID: String
    public let requestID: String
    public let timestamp: Date
    public let model: String
    public let sessionID: String
    public let cwd: String?
    public let input: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    public let cacheRead: Int
    public let output: Int

    public init(messageID: String, requestID: String, timestamp: Date, model: String,
                sessionID: String, cwd: String?, input: Int, cacheWrite5m: Int,
                cacheWrite1h: Int, cacheRead: Int, output: Int) {
        self.messageID = messageID
        self.requestID = requestID
        self.timestamp = timestamp
        self.model = model
        self.sessionID = sessionID
        self.cwd = cwd
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    /// What "context" means for the next exchange: the whole input window.
    public var contextTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// Five counters summed over one local day for one model ID.
public struct DailyModelTotals: Equatable, Sendable {
    public let day: String
    public let model: String
    public let input: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    public let cacheRead: Int
    public let output: Int

    public init(day: String, model: String, input: Int, cacheWrite5m: Int,
                cacheWrite1h: Int, cacheRead: Int, output: Int) {
        self.day = day
        self.model = model
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

/// Day keys are `yyyy-MM-dd` in the given calendar — sortable as strings.
public enum UsageDay {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The `n` keys ending today, oldest first.
    public static func keys(lastDays n: Int, endingAt today: Date,
                            calendar: Calendar = .current) -> [String] {
        (0..<n).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { key(for: $0, calendar: calendar) }
        }
    }
}
```

- [ ] **Step 2: Écrire les tests du ledger qui échouent**

```swift
// Tests/LoomAgentsTests/UsageLedgerTests.swift
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
```

- [ ] **Step 3: Vérifier l'échec**

Run: `swift test --filter UsageLedgerTests`
Expected: « cannot find 'UsageLedger' in scope ».

- [ ] **Step 4: Implémenter le ledger**

```swift
// Sources/LoomAgents/UsageLedger.swift
import LoomCore
import Foundation

/// Parses claude's native JSONL into billed turns. Pure — the seam the tests
/// contract against.
///
/// claude writes one `assistant` line PER CONTENT BLOCK of a response, each
/// carrying the same `usage`: without deduplication on (message.id, requestId)
/// costs inflate up to 3×. First occurrence wins.
public enum UsageLedger {

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func turns(fromJSONL text: String) -> [UsageTurn] {
        var seen = Set<String>()
        var turns: [UsageTurn] = []
        for line in text.split(separator: "\n") {
            guard let turn = parse(line: line) else { continue }
            let key = turn.messageID + "|" + turn.requestID
            guard seen.insert(key).inserted else { continue }
            turns.append(turn)
        }
        return turns
    }

    private static func parse(line: Substring) -> UsageTurn? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let stamp = object["timestamp"] as? String,
              let timestamp = fractional.date(from: stamp) ?? plain.date(from: stamp)
        else { return nil }

        let messageID = message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let split = usage["cache_creation"] as? [String: Any]
        let write5m = split?["ephemeral_5m_input_tokens"] as? Int
        let write1h = split?["ephemeral_1h_input_tokens"] as? Int

        return UsageTurn(
            messageID: messageID,
            requestID: object["requestId"] as? String ?? "",
            timestamp: timestamp,
            model: model,
            sessionID: object["sessionId"] as? String ?? "",
            cwd: object["cwd"] as? String,
            input: usage["input_tokens"] as? Int ?? 0,
            cacheWrite5m: split == nil ? creation : (write5m ?? 0),
            cacheWrite1h: split == nil ? 0 : (write1h ?? 0),
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0)
    }
}
```

- [ ] **Step 5: Vérifier le vert du ledger**

Run: `swift test --filter UsageLedgerTests`
Expected: 6 tests passent.

- [ ] **Step 6: Mettre à jour les tests existants de ClaudeNativeSessions**

Dans `Tests/LoomAgentsTests/ClaudeCodeAdapterTests.swift`, la suite qui contient `usage(fromJSONL:)` (vers les lignes 100-123). Remplacer la fixture existante (deux lignes `assistant` sans `model`) par des lignes conformes aux vrais enregistrements, et ajouter le cas de dédoublonnage :

```swift
    @Test("context = the last turn's full window, output = accumulated across turns")
    func usageFromNativeRecords() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-02T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":50,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":10}}}
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","timestamp":"2026-09-02T10:01:00Z","requestId":"r2","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":30,"cache_read_input_tokens":160,"output_tokens":25}}}
        """
        let usage = ClaudeNativeSessions.usage(fromJSONL: jsonl)
        #expect(usage?.contextTokens == 195, "5 + 30 + 160 — the last turn's real window")
        #expect(usage?.outputTokens == 35, "10 + 25 accumulated")
    }

    @Test("one assistant line per content block: output is counted once per turn")
    func usageDeduplicated() {
        let line = #"{"type":"assistant","timestamp":"2026-09-02T10:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25}}}"#
        let usage = ClaudeNativeSessions.usage(fromJSONL: [line, line, line].joined(separator: "\n"))
        #expect(usage?.outputTokens == 25, "not 75")
    }
```

Garder le test `noUsage` tel quel. Adapter le nom du test existant si celui du fichier diffère : l'important est la fixture avec `timestamp`, `requestId`, `message.id`, `message.model`.

- [ ] **Step 7: Vérifier l'échec du nouveau cas**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: `usageDeduplicated` échoue (75 au lieu de 25).

- [ ] **Step 8: Réécrire `usage(fromJSONL:)` sur le ledger**

Dans `Sources/LoomAgents/ClaudeNativeSessions.swift`, remplacer le corps de `usage(fromJSONL:)` :

```swift
    /// Parses claude's native JSONL. Pure — the seam the tests contract against.
    /// Built on `UsageLedger`: duplicates (one line per content block) count once.
    public static func usage(fromJSONL text: String) -> SessionUsage? {
        let turns = UsageLedger.turns(fromJSONL: text)
        guard let last = turns.last else { return nil }
        return SessionUsage(contextTokens: last.contextTokens,
                            outputTokens: turns.reduce(0) { $0 + $1.output })
    }
```

- [ ] **Step 9: Vérifier le vert**

Run: `swift test --filter "ClaudeCodeAdapterTests|UsageLedgerTests"`
Expected: tout passe.

- [ ] **Step 10: Commit**

```bash
git add Sources/LoomCore/UsageTurn.swift Sources/LoomAgents/UsageLedger.swift Sources/LoomAgents/ClaudeNativeSessions.swift Tests/LoomAgentsTests/UsageLedgerTests.swift Tests/LoomAgentsTests/ClaudeCodeAdapterTests.swift
git commit -m "UsageLedger : tours facturés depuis le .jsonl natif, dédoublonnés sur (message.id, requestId)

Le compteur de sortie de ClaudeNativeSessions comptait chaque bloc de contenu
comme un tour ; il repose désormais sur le ledger.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE"
```

---

### Task 3: UsageIndex (LoomPersistence, GRDB incrémental)

**Files:**
- Modify: `Package.swift:27` (ajouter `"LoomAgents"` aux dépendances de LoomPersistence)
- Modify: `Sources/LoomPersistence/SessionStore.swift:10` (`private let database` → `let database`) et `:66` (migration `v6-usage` avant `try migrator.migrate(database)`)
- Create: `Sources/LoomPersistence/UsageIndex.swift`
- Test: `Tests/LoomPersistenceTests/UsageIndexTests.swift`

**Interfaces:**
- Consumes: `UsageLedger.turns(fromJSONL:)`, `UsageTurn`, `UsageDay.key(for:calendar:)`, `DailyModelTotals`.
- Produces: `UsageIndex(store:)`, `UsageIndex.RefreshSummary { filesScanned: Int; turnsAdded: Int }`, `refresh(projectsDirectory: URL, calendar: Calendar = .current) throws -> RefreshSummary`, `dailyTotals(fromDay: String) throws -> [DailyModelTotals]`.

- [ ] **Step 1: Dépendance et migration**

`Package.swift` ligne 27 :

```swift
        .target(name: "LoomPersistence", dependencies: ["LoomCore", "LoomTerminal", "LoomAgents", .product(name: "GRDB", package: "GRDB.swift")]),
```

`SessionStore.swift` ligne 10 : `let database: DatabaseQueue` (visibilité interne au module, pour `UsageIndex`).

`SessionStore.swift`, après la migration `v5-badge` et avant `try migrator.migrate(database)` :

```swift
        migrator.registerMigration("v6-usage") { db in
            // Usage & costs: an incremental index of claude's native .jsonl records.
            // usageFile remembers how far each file has been consumed.
            try db.create(table: "usageFile") { t in
                t.primaryKey("path", .text)
                t.column("bytesConsumed", .integer).notNull()
                t.column("modifiedAt", .double).notNull()
            }
            try db.create(table: "usageTurn") { t in
                t.column("messageID", .text).notNull()
                t.column("requestID", .text).notNull()
                t.column("at", .double).notNull()
                t.column("day", .text).notNull().indexed()
                t.column("model", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("cwd", .text)
                t.column("input", .integer).notNull()
                t.column("cacheWrite5m", .integer).notNull()
                t.column("cacheWrite1h", .integer).notNull()
                t.column("cacheRead", .integer).notNull()
                t.column("output", .integer).notNull()
                t.primaryKey(["messageID", "requestID"])
            }
        }
```

- [ ] **Step 2: Écrire les tests qui échouent**

```swift
// Tests/LoomPersistenceTests/UsageIndexTests.swift
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
        #expect(try index.dailyTotals(fromDay: "2026-09-01").first?.output == 20)
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
```

- [ ] **Step 3: Vérifier l'échec**

Run: `swift test --filter UsageIndexTests`
Expected: « cannot find 'UsageIndex' in scope ».

- [ ] **Step 4: Implémenter**

```swift
// Sources/LoomPersistence/UsageIndex.swift
import LoomCore
import LoomAgents
import Foundation
import GRDB

/// Incremental index of claude's native per-turn records, on loom.sqlite.
///
/// Each .jsonl is consumed once: `usageFile` remembers the byte offset already
/// parsed, so a refresh only reads what claude appended since. The offset stops
/// at the last newline — a line still being written is never parsed halfway.
public final class UsageIndex: Sendable {

    public struct RefreshSummary: Equatable, Sendable {
        public let filesScanned: Int
        public let turnsAdded: Int
    }

    private let database: DatabaseQueue

    public init(store: SessionStore) {
        database = store.database
    }

    public func refresh(projectsDirectory: URL, calendar: Calendar = .current) throws -> RefreshSummary {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: projectsDirectory,
                                                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else {
            return RefreshSummary(filesScanned: 0, turnsAdded: 0)
        }
        var scanned = 0
        var added = 0
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            scanned += 1
            added += try consume(file: file, size: UInt64(size),
                                 modifiedAt: modified.timeIntervalSince1970, calendar: calendar)
        }
        return RefreshSummary(filesScanned: scanned, turnsAdded: added)
    }

    private func consume(file: URL, size: UInt64, modifiedAt: Double, calendar: Calendar) throws -> Int {
        let path = file.path
        let known: (bytes: UInt64, modifiedAt: Double)? = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT bytesConsumed, modifiedAt FROM usageFile WHERE path = ?",
                             arguments: [path]).map { (UInt64($0["bytesConsumed"] as Int64), $0["modifiedAt"] as Double) }
        }
        if let known, known.bytes == size, known.modifiedAt == modifiedAt { return 0 }
        // A file that shrank was rewritten: start over (the primary key absorbs re-reads).
        let offset: UInt64 = (known.map { $0.bytes <= size ? $0.bytes : 0 }) ?? 0

        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd() else {
            try remember(path: path, bytes: offset, modifiedAt: modifiedAt)
            return 0
        }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            try remember(path: path, bytes: offset, modifiedAt: modifiedAt)
            return 0
        }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        let turns = UsageLedger.turns(fromJSONL: text)
        let consumed = offset + UInt64(complete.count)

        return try database.write { db in
            var inserted = 0
            for turn in turns {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO usageTurn
                    (messageID, requestID, at, day, model, sessionID, cwd,
                     input, cacheWrite5m, cacheWrite1h, cacheRead, output)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        turn.messageID, turn.requestID, turn.timestamp.timeIntervalSince1970,
                        UsageDay.key(for: turn.timestamp, calendar: calendar), turn.model,
                        turn.sessionID, turn.cwd, turn.input, turn.cacheWrite5m,
                        turn.cacheWrite1h, turn.cacheRead, turn.output,
                    ])
                inserted += db.changesCount
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO usageFile (path, bytesConsumed, modifiedAt) VALUES (?, ?, ?)
                """, arguments: [path, Int64(consumed), modifiedAt])
            return inserted
        }
    }

    private func remember(path: String, bytes: UInt64, modifiedAt: Double) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO usageFile (path, bytesConsumed, modifiedAt) VALUES (?, ?, ?)",
                           arguments: [path, Int64(bytes), modifiedAt])
        }
    }

    /// Per (day, model) sums from `fromDay` (inclusive, `yyyy-MM-dd`) onward, oldest first.
    public func dailyTotals(fromDay: String) throws -> [DailyModelTotals] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, model, SUM(input) AS input, SUM(cacheWrite5m) AS cacheWrite5m,
                       SUM(cacheWrite1h) AS cacheWrite1h, SUM(cacheRead) AS cacheRead, SUM(output) AS output
                FROM usageTurn WHERE day >= ? GROUP BY day, model ORDER BY day, model
                """, arguments: [fromDay]).map { row in
                DailyModelTotals(day: row["day"], model: row["model"], input: row["input"],
                                 cacheWrite5m: row["cacheWrite5m"], cacheWrite1h: row["cacheWrite1h"],
                                 cacheRead: row["cacheRead"], output: row["output"])
            }
        }
    }
}
```

Note : `data[data.startIndex...lastNewline]` est une `Data` slice ; `complete.count` est bien le nombre d'octets consommés.

- [ ] **Step 5: Vérifier le vert**

Run: `swift test --filter UsageIndexTests`
Expected: 7 tests passent. Puis `swift test --filter SessionStoreTests` reste vert (la migration v6 s'applique sans casser les anciennes).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/LoomPersistence/SessionStore.swift Sources/LoomPersistence/UsageIndex.swift Tests/LoomPersistenceTests/UsageIndexTests.swift
git commit -m "UsageIndex : index incrémental GRDB des tours facturés (migration v6-usage)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE"
```

---

### Task 4: UsageReport (LoomCore)

**Files:**
- Create: `Sources/LoomCore/UsageReport.swift`
- Test: `Tests/LoomCoreTests/UsageReportTests.swift`

**Interfaces:**
- Consumes: `DailyModelTotals`, `UsageDay.keys(lastDays:endingAt:calendar:)`, `ModelPricing.family(for:)`, `ModelPricing.cost(...)`.
- Produces: `UsageReport(totals:today:calendar:)`, `.today`, `.last7Days`, `.last30Days` (Decimal), `.points(lastDays:) -> [UsageReport.DayPoint]`, `.byModel(lastDays:) -> [UsageReport.ModelLine]`, `.total(lastDays:) -> Decimal`, `.unpricedModels: [String]`.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
// Tests/LoomCoreTests/UsageReportTests.swift
import Testing
import LoomCore
import Foundation

// Seam : l'agrégation fenêtrée et tarifée. Tout en UTC pour rester déterministe.

@Suite("UsageReport — fenêtres civiles et ventilation par modèle")
struct UsageReportTests {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // 2026-09-02 12:00 UTC
    private let today = Date(timeIntervalSince1970: 1_788_350_400)

    private func totals(_ day: String, _ model: String, output: Int) -> DailyModelTotals {
        DailyModelTotals(day: day, model: model, input: 0, cacheWrite5m: 0, cacheWrite1h: 0,
                         cacheRead: 0, output: output)
    }

    @Test("aujourd'hui, 7 jours et 30 jours sont des fenêtres civiles inclusives")
    func fenetres() {
        // opus-5 : 1M output = 25 $
        let report = UsageReport(totals: [
            totals("2026-09-02", "claude-opus-5", output: 1_000_000),   // aujourd'hui
            totals("2026-08-27", "claude-opus-5", output: 1_000_000),   // 7e jour inclus
            totals("2026-08-26", "claude-opus-5", output: 1_000_000),   // hors 7 j
            totals("2026-08-04", "claude-opus-5", output: 1_000_000),   // 30e jour inclus
            totals("2026-08-03", "claude-opus-5", output: 1_000_000),   // hors 30 j
        ], today: today, calendar: utc)
        #expect(report.today == Decimal(25))
        #expect(report.last7Days == Decimal(50))
        #expect(report.last30Days == Decimal(100))
        #expect(report.total(lastDays: 90) == Decimal(125))
    }

    @Test("byModel regroupe par famille, trié par coût décroissant, non tarifés en fin")
    func parModele() {
        let report = UsageReport(totals: [
            totals("2026-09-02", "claude-opus-5", output: 1_000_000),          // 25 $
            totals("2026-09-01", "claude-opus-4-8", output: 1_000_000),        // 25 $ → même famille ? non : opus-4-8
            totals("2026-09-02", "claude-fable-5-1", output: 1_000_000),       // 50 $
            totals("2026-09-02", "claude-unicorn-9", output: 5),               // unpriced
        ], today: today, calendar: utc)
        let lines = report.byModel(lastDays: 30)
        #expect(lines.map(\.family) == ["fable-5-1", "opus-5", "opus-4-8", "unicorn-9"])
        #expect(lines[0].cost == Decimal(50))
        #expect(lines[3].cost == nil)
        #expect(lines[3].output == 5)
        #expect(report.unpricedModels == ["unicorn-9"])
    }

    @Test("points : une entrée par (jour, famille) dans la fenêtre, coût et tokens")
    func points() {
        let report = UsageReport(totals: [
            DailyModelTotals(day: "2026-09-02", model: "claude-opus-5", input: 10, cacheWrite5m: 20,
                             cacheWrite1h: 30, cacheRead: 40, output: 1_000_000),
            totals("2026-08-26", "claude-opus-5", output: 1),
        ], today: today, calendar: utc)
        let points = report.points(lastDays: 7)
        #expect(points.count == 1)
        #expect(points.first?.day == "2026-09-02")
        #expect(points.first?.family == "opus-5")
        #expect(points.first?.tokens == 1_000_100)
        #expect(points.first?.cost == Decimal(string: "25.00095"))
    }
}
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter UsageReportTests`
Expected: « cannot find 'UsageReport' in scope ».

- [ ] **Step 3: Implémenter**

```swift
// Sources/LoomCore/UsageReport.swift
import Foundation

/// Windowed, priced view over daily totals. Pure: built once from the index's
/// rows, then queried by the sheet for each window the user picks.
public struct UsageReport: Equatable, Sendable {

    public struct DayPoint: Equatable, Sendable {
        public let day: String
        public let family: String
        public let cost: Decimal
        public let tokens: Int
    }

    public struct ModelLine: Equatable, Sendable {
        public let family: String
        public let cost: Decimal?      // nil = not in the price table
        public let input: Int
        public let cacheWrite5m: Int
        public let cacheWrite1h: Int
        public let cacheRead: Int
        public let output: Int
    }

    private struct Row: Equatable, Sendable {
        let day: String
        let family: String
        let cost: Decimal?
        let totals: DailyModelTotals
    }

    private let rows: [Row]
    private let today: Date
    private let calendar: Calendar

    public init(totals: [DailyModelTotals], today: Date = Date(), calendar: Calendar = .current) {
        self.today = today
        self.calendar = calendar
        rows = totals.map { t in
            Row(day: t.day, family: ModelPricing.family(for: t.model),
                cost: ModelPricing.cost(input: t.input, cacheWrite5m: t.cacheWrite5m,
                                        cacheWrite1h: t.cacheWrite1h, cacheRead: t.cacheRead,
                                        output: t.output, modelID: t.model),
                totals: t)
        }
    }

    public var today: Decimal { total(lastDays: 1) }
    public var last7Days: Decimal { total(lastDays: 7) }
    public var last30Days: Decimal { total(lastDays: 30) }

    public var unpricedModels: [String] {
        Array(Set(rows.filter { $0.cost == nil }.map(\.family))).sorted()
    }

    private func window(_ days: Int) -> Set<String> {
        Set(UsageDay.keys(lastDays: days, endingAt: today, calendar: calendar))
    }

    public func total(lastDays days: Int) -> Decimal {
        let keys = window(days)
        return rows.filter { keys.contains($0.day) }.reduce(Decimal(0)) { $0 + ($1.cost ?? 0) }
    }

    /// One point per (day, family), oldest day first. Unpriced models count 0 in cost.
    public func points(lastDays days: Int) -> [DayPoint] {
        let keys = window(days)
        var merged: [String: (cost: Decimal, tokens: Int)] = [:]
        var order: [String] = []
        for row in rows where keys.contains(row.day) {
            let key = row.day + "|" + row.family
            if merged[key] == nil { order.append(key) }
            var entry = merged[key] ?? (0, 0)
            entry.cost += row.cost ?? 0
            entry.tokens += row.totals.totalTokens
            merged[key] = entry
        }
        return order.sorted().map { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let entry = merged[key]!
            return DayPoint(day: parts[0], family: parts[1], cost: entry.cost, tokens: entry.tokens)
        }
    }

    /// Priced families by cost descending, then unpriced ones alphabetically.
    public func byModel(lastDays days: Int) -> [ModelLine] {
        let keys = window(days)
        var byFamily: [String: ModelLine] = [:]
        for row in rows where keys.contains(row.day) {
            let t = row.totals
            let previous = byFamily[row.family]
            let cost: Decimal? = {
                switch (previous?.cost, row.cost) {
                case (nil, nil): return nil
                case (let a?, nil): return a
                case (nil, let b?): return previous == nil ? b : nil
                case (let a?, let b?): return a + b
                }
            }()
            byFamily[row.family] = ModelLine(
                family: row.family, cost: cost,
                input: (previous?.input ?? 0) + t.input,
                cacheWrite5m: (previous?.cacheWrite5m ?? 0) + t.cacheWrite5m,
                cacheWrite1h: (previous?.cacheWrite1h ?? 0) + t.cacheWrite1h,
                cacheRead: (previous?.cacheRead ?? 0) + t.cacheRead,
                output: (previous?.output ?? 0) + t.output)
        }
        let priced = byFamily.values.filter { $0.cost != nil }
            .sorted { ($0.cost ?? 0) == ($1.cost ?? 0) ? $0.family < $1.family : ($0.cost ?? 0) > ($1.cost ?? 0) }
        let unpriced = byFamily.values.filter { $0.cost == nil }.sorted { $0.family < $1.family }
        return priced + unpriced
    }
}
```

Le `cost` d'une famille est `nil` seulement si aucune de ses lignes n'est tarifée ; une famille est tarifée ou non dans son ensemble (la table est par famille), donc les cas mixtes n'arrivent pas en pratique, le `switch` reste sûr.

- [ ] **Step 4: Vérifier le vert**

Run: `swift test --filter UsageReportTests`
Expected: 3 tests passent. Si `points().cost` échoue sur l'égalité `Decimal`, comparer avec `Decimal(string: "25.00095")` exactement comme dans le test : le calcul 10×5 + 20×6.25 + 30×10 + 40×0.5 + 1 000 000×25 = 25 000 950 / 1e6 = 25.00095, exact en `Decimal`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoomCore/UsageReport.swift Tests/LoomCoreTests/UsageReportTests.swift
git commit -m "UsageReport : fenêtres civiles, série journalière et ventilation par famille

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE"
```

---

### Task 5: Bouton `$` et feuille « Usage & estimated costs »

**Files:**
- Modify: `Sources/LoomApp/AppModel.swift:1260` (ajouter `usageIndex()`)
- Create: `Sources/LoomApp/UsageSheet.swift`
- Modify: `Sources/LoomApp/ContentView.swift:94` (état), `:184` (`.sheet`), `:264` (bouton après le `⌘K`, avant la roue crantée)

**Interfaces:**
- Consumes: `UsageIndex`, `UsageReport`, `ModelPricing.asOf`, `ClaudeNativeSessions.defaultProjectsDirectory`, `DefaultTheme.*`, `GhostButton`, `hoverBrightness`.
- Produces: `UsageSheet(model:onClose:)`.

- [ ] **Step 1: Exposer l'index depuis AppModel**

Dans `AppModel.swift`, près de `private var store: SessionStore?` (ligne 1260) :

```swift
    /// Usage & costs: the incremental index shares loom.sqlite with the store.
    public func usageIndex() -> UsageIndex? {
        store.map { UsageIndex(store: $0) }
    }
```

- [ ] **Step 2: La feuille**

```swift
// Sources/LoomApp/UsageSheet.swift
import Charts
import LoomAgents
import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// « Usage & estimated costs »: every claude session on this machine, priced
/// from the public list. Opens from the `$` in the navbar. All the work
/// (scan + aggregate) runs off the main actor; the sheet only displays.
struct UsageSheet: View {
    let model: AppModel
    let onClose: () -> Void

    enum Metric: String, CaseIterable { case cost = "Cost", tokens = "Tokens" }
    enum Window: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue)d" }
    }

    @State private var report: UsageReport?
    @State private var refreshing = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var metric: Metric = .cost
    @State private var window: Window = .month

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Cost values are estimates based on public list prices (as of \(ModelPricing.asOf)). Usage data stays in your local database.")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(DefaultTheme.danger)
                    }
                    if let report {
                        tiles(report)
                        chartCard(report)
                        byModel(report)
                    } else if refreshing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Indexing local session records…")
                                .font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(24)
            }
            Divider().overlay(DefaultTheme.cardBorder)
            footer
        }
        .frame(width: 1000, height: 880)
        .background(DefaultTheme.surface)
        .preferredColorScheme(.dark)
        .task { await refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.accent)
            Text("Usage & Estimated Costs")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Spacer()
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                GhostButton(systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Rescan local session records")
            }
            GhostButton(systemImage: "xmark", action: onClose)
                .help("Close")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func tiles(_ report: UsageReport) -> some View {
        HStack(spacing: 14) {
            tile("Today", icon: "dollarsign", value: report.today)
            tile("Last 7 days", icon: "chart.line.uptrend.xyaxis", value: report.last7Days)
            tile("Last 30 days", icon: "calendar", value: report.last30Days)
        }
    }

    private func tile(_ title: String, icon: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
            Text(Self.money(value))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func chartCard(_ report: UsageReport) -> some View {
        let points = report.points(lastDays: window.rawValue)
        let families = Array(Set(points.map(\.family))).sorted()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric == .cost ? "DAILY COST" : "DAILY TOKENS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text(metric == .cost
                         ? "\(Self.money(report.total(lastDays: window.rawValue))) over \(window.rawValue) days"
                         : "\(Self.tokens(points.reduce(0) { $0 + $1.tokens })) tokens over \(window.rawValue) days")
                        .font(.system(size: 14))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                Spacer()
                segmented(Metric.allCases, selected: $metric, label: \.rawValue)
                segmented(Window.allCases, selected: $window, label: \.label)
            }
            HStack(spacing: 12) {
                ForEach(families, id: \.self) { family in
                    HStack(spacing: 5) {
                        Circle().fill(Self.color(for: family)).frame(width: 7, height: 7)
                        Text(family).font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
                    }
                }
            }
            Chart(points, id: \.self) { point in
                BarMark(x: .value("Day", UsageDay.date(forKey: point.day) ?? Date(), unit: .day),
                        y: .value(metric.rawValue, metric == .cost
                                  ? NSDecimalNumber(decimal: point.cost).doubleValue
                                  : Double(point.tokens)))
                    .foregroundStyle(by: .value("Model", point.family))
            }
            .chartForegroundStyleScale(domain: families, range: families.map(Self.color(for:)))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(DefaultTheme.cardBorder)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(metric == .cost ? "$\(Int(v))" : Self.tokens(Int(v)))
                                .font(.system(size: 10)).foregroundStyle(DefaultTheme.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: window == .week ? 1 : window == .month ? 5 : 15)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10)).foregroundStyle(DefaultTheme.secondaryText)
                }
            }
            .frame(height: 240)
        }
        .padding(16)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func byModel(_ report: UsageReport) -> some View {
        let lines = report.byModel(lastDays: window.rawValue)
        let max = lines.compactMap(\.cost).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COST BY MODEL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Spacer()
                Text(Self.money(report.total(lastDays: window.rawValue)))
                    .font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
            }
            if lines.isEmpty {
                Text("No usage records found under \(ClaudeNativeSessions.defaultProjectsDirectory.path)")
                    .font(.system(size: 12)).foregroundStyle(DefaultTheme.mutedText)
            }
            ForEach(lines, id: \.family) { line in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.family)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Text("\(Self.tokens(line.input)) in / \(Self.tokens(line.output)) out / \(Self.tokens(line.cacheWrite5m + line.cacheWrite1h)) cache-w / \(Self.tokens(line.cacheRead)) cache-r")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    Spacer()
                    if let cost = line.cost {
                        GeometryReader { geo in
                            Capsule().fill(Self.color(for: line.family))
                                .frame(width: max > 0 ? geo.size.width * CGFloat(NSDecimalNumber(decimal: cost / max).doubleValue) : 0)
                        }
                        .frame(width: 140, height: 6)
                        Text(Self.money(cost))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DefaultTheme.primaryText)
                            .frame(width: 80, alignment: .trailing)
                    } else {
                        Text("unpriced")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .frame(width: 228, alignment: .trailing)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(DefaultTheme.cardBorder)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text(updatedAt.map { "Data from local per-turn session records, updated \(Self.clock.string(from: $0))" }
                 ?? "Data from local per-turn session records")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.mutedText)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func segmented<T: Hashable>(_ options: [T], selected: Binding<T>,
                                        label: @escaping (T) -> String) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selected.wrappedValue = option } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: selected.wrappedValue == option ? .semibold : .regular))
                        .foregroundStyle(selected.wrappedValue == option ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected.wrappedValue == option ? DefaultTheme.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DefaultTheme.background, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Work

    private func refresh() async {
        guard let index = model.usageIndex() else {
            error = "The local database is not available."
            return
        }
        refreshing = true
        defer { refreshing = false }
        let projects = ClaudeNativeSessions.defaultProjectsDirectory
        let today = Date()
        let result: Result<UsageReport, Error> = await Task.detached(priority: .userInitiated) {
            do {
                _ = try index.refresh(projectsDirectory: projects)
                let since = UsageDay.keys(lastDays: 90, endingAt: today).first ?? "2000-01-01"
                let totals = try index.dailyTotals(fromDay: since)
                return .success(UsageReport(totals: totals, today: today))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let built):
            report = built
            error = nil
            updatedAt = Date()
        case .failure(let failure):
            error = "Could not read usage records: \(failure.localizedDescription)"
        }
    }

    // MARK: - Formatting

    static func money(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: number) ?? "$0.00"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: return String(format: "%.1fk", Double(count) / 1000)
        default: return "\(count)"
        }
    }

    static func color(for family: String) -> Color {
        if family.hasPrefix("fable") || family.hasPrefix("mythos") { return DefaultTheme.accent }
        if family.hasPrefix("opus") { return .orange }
        if family.hasPrefix("sonnet") { return .green }
        if family.hasPrefix("haiku") { return .gray }
        return DefaultTheme.mutedText
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
```

`UsageReport.DayPoint` doit être `Hashable` pour `Chart(points, id: \.self)` : ajouter `Hashable` à la déclaration de `DayPoint` dans `Sources/LoomCore/UsageReport.swift` (`public struct DayPoint: Equatable, Hashable, Sendable`).

- [ ] **Step 3: Brancher dans ContentView**

Ligne 94, à côté de `paletteShown` :

```swift
    @State private var usageShown = false
```

Ligne 184, après `.sheet(isPresented: $paletteShown) { palette }` :

```swift
        .sheet(isPresented: $usageShown) { UsageSheet(model: model) { usageShown = false } }
```

Ligne 264, entre le bouton `⌘K` (qui se termine par `.keyboardShortcut(KeyEquivalent(keyPalette.first ?? "k"), modifiers: .command)`) et le commentaire `// Settings: the gear toggles the in-app page.` :

```swift
            // Usage & estimated costs: every claude session on this machine.
            Button {
                usageShown = true
            } label: {
                Image(systemName: "dollarsign")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .hoverBrightness(0.1)
            }
            .buttonStyle(.plain)
            .help("Usage & estimated costs")
```

- [ ] **Step 4: Compiler et lancer la suite complète**

Run: `swift build 2>&1 | tail -20` puis `swift test 2>&1 | tail -5`
Expected: build sans erreur ni warning nouveau ; tous les tests verts (131 + 21 nouveaux).

Si `Chart(points, id: \.self)` ne compile pas avec `DayPoint`, utiliser `Chart(points, id: \.id)` avec `var id: String { day + "|" + family }` ajouté à `DayPoint`.

- [ ] **Step 5: Validation visuelle**

Lancer l'app (`swift run LoomApp` ou le script de lancement habituel du projet), cliquer `$` :
- première ouverture : spinner « Indexing local session records… » puis la feuille remplie ;
- fermer, rouvrir : quasi instantané ;
- `Cost | Tokens` et `7d | 30d | 90d` changent le graphique, la ligne « over N days » et la ventilation ;
- les familles listées correspondent aux modèles réellement utilisés (fable-5-1, opus-5…), aucune ligne `unpriced` inattendue ;
- le pied affiche l'heure de mise à jour.

Comparer les tuiles à celles de Xirp si Xirp est ouvert : les ordres de grandeur doivent coïncider (même source de données). Un écart sur les lectures cache fable-5-1 est attendu : Xirp peut utiliser 0.1× là où la liste officielle donne 0.025×.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoomApp/UsageSheet.swift Sources/LoomApp/ContentView.swift Sources/LoomApp/AppModel.swift Sources/LoomCore/UsageReport.swift
git commit -m "Bouton \$ : feuille Usage & estimated costs (tuiles, graphique journalier, ventilation par modèle)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018D473vZw7uBPjNmQwYfQuE"
```

---

## Auto-revue du plan

- **Couverture spec** : périmètre (Task 3 énumère tout `~/.claude/projects` récursivement), bouton `$` seul (Task 5), aucun réseau (table Task 1), index incrémental (Task 3), dédoublonnage + correction du compteur existant (Task 2), tarifs datés avec exception fable-5-1 (Task 1), `Decimal` (Tasks 1, 4), jours civils locaux (Task 2 `UsageDay`, Task 3 `calendar`), UI six sections (Task 5), erreurs : fichier illisible ignoré, dossier absent → vide, erreur GRDB → message (Tasks 3, 5). Hors périmètre respecté.
- **Placeholders** : aucun.
- **Cohérence des types** : `UsageIndex.refresh(projectsDirectory:calendar:)` et `dailyTotals(fromDay:)` identiques en Task 3 et Task 5 ; `UsageReport.points(lastDays:)`, `byModel(lastDays:)`, `total(lastDays:)` identiques en Task 4 et 5 ; `UsageDay.keys(lastDays:endingAt:calendar:)` défini Task 2, utilisé Tasks 4 et 5.
