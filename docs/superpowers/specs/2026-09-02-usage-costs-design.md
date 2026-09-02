# Suivi de consommation et coûts estimés (bouton `$`)

Date : 2026-09-02 · Statut : validé par l'utilisateur (périmètre, bouton, design)

## But

Un bouton `$` dans la barre du haut, entre `⌘K` et la roue crantée, ouvre une
feuille « Usage & estimated costs » sur le modèle de Xirp : trois tuiles
(aujourd'hui, 7 jours, 30 jours), un graphique journalier empilé par modèle,
une ventilation par modèle avec les tokens détaillés, et une mention claire
que les chiffres sont des estimations sur prix publics.

## Décisions prises

- **Périmètre : toutes les sessions claude locales** (`~/.claude/projects/**/*.jsonl`),
  pas seulement celles lancées par Loom. L'utilisateur veut sa consommation réelle.
- **Bouton : icône `$` seule.** Aucun calcul tant que la feuille n'est pas ouverte.
- **Aucun accès réseau.** Les prix sont une table embarquée, datée. Les données
  restent locales.
- **Aucun rescan complet à l'ouverture** : index incrémental persistant (238 Mo de
  `.jsonl` sur la machine de référence).

## Faits sur les données source (vérifiés)

Chaque ligne `{"type":"assistant"}` d'un `.jsonl` porte :
`timestamp` (ISO 8601 UTC), `sessionId`, `cwd`, `requestId`, et
`message.{id, model, usage}` avec `usage.input_tokens`,
`usage.cache_read_input_tokens`, `usage.cache_creation_input_tokens`,
`usage.cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`,
`usage.output_tokens`.

**Piège** : claude écrit une ligne `assistant` par bloc de contenu, chacune avec
la même `usage`. Mesuré : 14 lignes pour 7 messages. Clé de dédoublonnage :
`(message.id, requestId)`. Le compteur « Output total » existant de
`ClaudeNativeSessions.usage(fromJSONL:)` compte les doublons ; il est corrigé
au passage avec la même clé.

Les lignes sans `message.usage`, sans `model`, ou avec `model` `<synthetic>`
sont ignorées (aucun coût).

## Tarifs (USD / MTok, source platform.claude.com/docs/en/about-claude/pricing, 2026-09-02)

| Famille | Entrée | Cache 5 min | Cache 1 h | Lecture cache | Sortie |
|---|---|---|---|---|---|
| fable-5-1, mythos-5-1 | 10 | 12.50 | 20 | 0.25 | 50 |
| fable-5, mythos-5 | 10 | 12.50 | 20 | 1 | 50 |
| opus-5, opus-4-8, opus-4-7, opus-4-6, opus-4-5 | 5 | 6.25 | 10 | 0.50 | 25 |
| opus-4-1, opus-4 | 15 | 18.75 | 30 | 1.50 | 75 |
| sonnet-5 | 2 | 2.50 | 4 | 0.20 | 10 |
| sonnet-4-6, sonnet-4-5, sonnet-4 | 3 | 3.75 | 6 | 0.30 | 15 |
| haiku-4-5 | 1 | 1.25 | 2 | 0.10 | 5 |
| haiku-3-5 | 0.80 | 1 | 1.60 | 0.08 | 4 |

Règle générale : écriture 5 min = 1.25 × entrée, écriture 1 h = 2 × entrée,
lecture = 0.1 × entrée (0.025 × sur fable-5-1 / mythos-5-1). La table est
stockée explicitement, pas dérivée, pour absorber les exceptions.

Coût d'un tour =
`input × entrée + write5m × cache5 + write1h × cache1h + read × lecture + output × sortie`,
le tout / 1 000 000. Si `cache_creation` ventilé est absent, tout
`cache_creation_input_tokens` compte en 5 min (hypothèse la moins chère,
documentée dans l'UI par « estimation »).

Résolution d'identifiant : `claude-opus-4-1-20250805` → `opus-4-1`,
`claude-fable-5-1` → `fable-5-1`, `claude-3-5-haiku-20241022` → `haiku-3-5`.
Un identifiant inconnu donne un coût nul et est listé « unpriced » dans l'UI.

## Architecture

```
~/.claude/projects/**/*.jsonl
        │  (lecture incrémentale, hors main actor)
        ▼
UsageLedger (LoomAgents, pur)         ModelPricing (LoomCore, pur)
  jsonl → [UsageTurn] dédoublonnés      family(for: modelID), cost(of: turn)
        │                                       │
        ▼                                       │
UsageIndex (LoomPersistence, GRDB)              │
  usage_file(path, bytesConsumed, mtime)        │
  usage_turn(day, model, session, cwd, tokens…) │
  refresh(scanning:) · daily(from:to:) · byModel(from:to:)
        │                                       │
        └──────────────► UsageReport ◄──────────┘
                     (LoomApp, agrège + tarifie)
                              │
                              ▼
                        UsageSheet (SwiftUI + Swift Charts)
```

### UsageLedger (LoomAgents)

```swift
public struct UsageTurn: Equatable, Sendable {
    public let messageID: String; public let requestID: String
    public let timestamp: Date; public let model: String
    public let sessionID: String; public let cwd: String?
    public let input: Int; public let cacheWrite5m: Int; public let cacheWrite1h: Int
    public let cacheRead: Int; public let output: Int
}
public enum UsageLedger {
    /// Pur. Ignore les lignes non-assistant, sans usage, sans model, synthetic.
    /// Dédoublonne sur (messageID, requestID) — la première occurrence gagne.
    public static func turns(fromJSONL text: String) -> [UsageTurn]
}
```

`ClaudeNativeSessions.usage(fromJSONL:)` est réécrit par-dessus `UsageLedger`
(le contexte reste celui du dernier tour, la sortie devient la somme des tours
uniques). Ses tests existants doivent rester verts.

### ModelPricing (LoomCore)

```swift
public struct ModelRates: Equatable, Sendable { input, cacheWrite5m, cacheWrite1h, cacheRead, output: Decimal } // USD / MTok
public enum ModelPricing {
    public static let asOf: String  // "2026-09-02"
    public static func family(for modelID: String) -> String   // "fable-5-1", ou l'ID tel quel si inconnu
    public static func rates(for modelID: String) -> ModelRates?
    public static func cost(input:cacheWrite5m:cacheWrite1h:cacheRead:output:modelID:) -> Decimal?  // nil = unpriced
}
```

`Decimal` pour éviter les dérives d'arrondi en additionnant des milliers de
tours ; l'UI formate en `$0.00`.

### UsageIndex (LoomPersistence)

Migration GRDB `v6-usage` sur `loom.sqlite` :

```sql
CREATE TABLE usageFile (path TEXT PRIMARY KEY, bytesConsumed INTEGER NOT NULL, modifiedAt REAL NOT NULL);
CREATE TABLE usageTurn (
  messageID TEXT NOT NULL, requestID TEXT NOT NULL,
  at REAL NOT NULL, day TEXT NOT NULL,          -- day = yyyy-MM-dd en heure locale
  model TEXT NOT NULL, sessionID TEXT NOT NULL, cwd TEXT,
  input INTEGER NOT NULL, cacheWrite5m INTEGER NOT NULL, cacheWrite1h INTEGER NOT NULL,
  cacheRead INTEGER NOT NULL, output INTEGER NOT NULL,
  PRIMARY KEY (messageID, requestID)
);
CREATE INDEX usageTurn_day ON usageTurn(day);
```

API :

```swift
public final class UsageIndex {
    public init(store: SessionStore)   // partage la DatabaseQueue
    /// Parcourt projectsDirectory ; pour chaque .jsonl : si taille/mtime inchangés → skip ;
    /// si la taille a diminué (fichier réécrit) → offset 0 ; sinon lit depuis bytesConsumed,
    /// coupe à la dernière fin de ligne, INSERT OR IGNORE les tours, met à jour usageFile.
    public func refresh(projectsDirectory: URL) throws -> RefreshSummary   // files scanned, turns added
    public func dailyTotals(from: Date, to: Date) throws -> [DailyModelTotals]   // (day, model, 5 compteurs)
}
```

La lecture partielle s'arrête au dernier `\n` : une ligne en cours d'écriture
n'est jamais parsée à moitié, elle sera reprise au prochain rafraîchissement.
La clé primaire absorbe les doublons inter-fichiers (une sous-session copiée).

### UsageReport (LoomApp)

Struct pure construite depuis `[DailyModelTotals]` + `ModelPricing` :
`today`, `last7Days`, `last30Days` (Decimal), `series(window:)` pour le
graphique (jour × famille → coût ou tokens), `byModel` trié par coût décroissant
avec les cinq compteurs, `unpricedModels`. « Aujourd'hui » et les fenêtres sont
en jours civils locaux, comme Xirp.

### UsageSheet (LoomApp)

`.sheet` ouverte par `$` (GhostButton, `.help("Usage & estimated costs")`),
~1000 × 900, fond `DefaultTheme.surface`, `preferredColorScheme(.dark)` comme les
autres panneaux. Contenu de haut en bas :

1. En-tête : icône `$` accentuée, titre, bouton rafraîchir (relance
   `refresh` en tâche détachée, spinner pendant), bouton fermer.
2. Sous-titre : « Cost values are estimates based on public list prices
   (as of 2026-09-02). Usage data stays in your local database. »
3. Trois tuiles Today / Last 7 days / Last 30 days.
4. Carte « Daily cost » : total sur la fenêtre, segmentés Cost | Tokens et
   7d | 30d | 90d, légende par famille, `Chart` à barres empilées (Swift Charts),
   couleur par famille (fable = accent, opus = orange, sonnet = bleu, haiku = gris ;
   le vert prévu initialement se confondait avec l'accent lime du thème). Dans
   une famille, la version la plus récente a la teinte pleine, les autres s'estompent.
5. « Cost by model » : une ligne par famille, barre proportionnelle, coût, et
   dessous `in / out / cache-w / cache-r` en compact (866 / 326.8k / 2.8M / 171.1M).
   Les modèles non tarifés apparaissent en fin de liste avec « unpriced ».
6. Pied : « Data from local per-turn session records, updated HH:mm:ss ».

État : `@State report: UsageReport?`, `@State refreshing`. Au `.task` de la
feuille : `refresh` puis `dailyTotals` sur 90 jours, hors main actor, puis
construction du rapport. Un premier scan de 238 Mo affiche le spinner ; les
suivants sont quasi instantanés (delta seulement).

## Gestion des erreurs

- Fichier illisible ou ligne JSON invalide : ignoré, le scan continue.
- Dossier `~/.claude/projects` absent : rapport vide, feuille affiche « No usage
  records found » avec le chemin.
- Erreur GRDB : message dans la feuille, pas de crash ; les autres fonctions de
  l'app ne dépendent pas de l'index.

## Tests (TDD, seams purs)

- `UsageLedgerTests` : dédoublonnage (14 lignes → 7 tours), lignes ignorées,
  ventilation 5 min / 1 h, absence de `cache_creation` ventilé → tout en 5 min,
  timestamp parsé en UTC.
- `ClaudeNativeSessionsTests` (existants) : `usage(fromJSONL:)` garde le contexte
  du dernier tour et une sortie sans doublons (nouveau cas).
- `ModelPricingTests` : résolution des familles (dated IDs, fable-5 vs 5-1),
  coût d'un tour connu (calcul à la main), modèle inconnu → nil.
- `UsageIndexTests` : premier scan indexe tout ; fichier qui grossit → seuls les
  nouveaux tours ; fichier tronqué → réindexé depuis 0 ; ligne partielle sans `\n`
  non consommée ; `dailyTotals` agrège par jour local et modèle.
- `UsageReportTests` : fenêtres civiles (aujourd'hui / 7 / 30), tri par coût,
  liste des non tarifés.

Validation UI à l'œil dans l'app lancée (`swift build` + run).

## Hors périmètre

Filtre par projet Loom, coût par session dans l'info popover, export CSV,
tarifs batch / fast mode / inference_geo (Claude Code ne les émet pas dans
les `.jsonl`), rafraîchissement périodique en arrière-plan.
