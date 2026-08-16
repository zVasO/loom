# Design C — `SessionRuntime`, optimisé pour l'appelant le plus courant

**Contrainte de design assumée.** Deux chemins doivent être triviaux, et tout le reste
est subordonné à eux :

- **(a) UC-1, `SessionManager`** — « créer le worktree → lancer l'agent avec le prompt
  initial → la carte passe à `working` ». Cible : **un appel** pour démarrer, **une
  boucle `for await`** pour tout ce qui remonte, **un appel** pour arrêter.
- **(b) UC-3, la vue terminal SwiftUI** — attacher/détacher au fil de la navigation,
  réattachement < 100 ms. Cible : **une ligne de cycle de vie** (`.task`), **aucun état
  vide** à rendre, **aucune `DispatchQueue` visible**.

Corollaire : le cas par défaut ne demande **aucune configuration** (pas de queue, pas
d'environnement, pas de chemin de transcript, pas d'adapters). Les cas rares — terminal
secondaire, arrêt immédiat, rendu par régions sales, snapshot hors-UI — ont droit d'être
verbeux, et le sont.

---

## 1. Interface

### 1.1 Ce que le module possède

`SessionRuntime` est le module qui possède tout ce qui est *vivant* dans une Session :
le process de l'Agent sur son PTY, le moteur terminal, le tee vers le Transcript,
l'échantillonnage vers la machine à états, et le snapshot d'écran pour le réattachement.
Il ne connaît ni Git, ni la base, ni les hooks, ni l'UI.

### 1.2 Types d'entrée

```swift
import Foundation

/// Identité stable d'un terminal dans une Session. `.primary` héberge l'Agent
/// (Terminal principal) ; les autres sont des Terminaux secondaires (SES-04).
public struct TerminalID: Hashable, Sendable, Codable {
    public static let primary = TerminalID(rawValue: 0)
    public let rawValue: Int
}

/// Ce qu'il faut exécuter. Produit par `AgentAdapter.launchCommand(for:)` (§6.2 du CdC).
public struct Command: Sendable {
    public var executable: String
    public var arguments: [String]
    /// **Overlay**, pas un environnement complet. Le runtime construit toujours une
    /// base contenant `TERM`, `COLORTERM`, `LANG`, `HOME`, `USER` et un `PATH`
    /// explicite résolu depuis le shell de login ; cet overlay est fusionné par-dessus.
    /// L'appelant n'a jamais à savoir que SwiftTerm omet `PATH`.
    public var environment: [String: String]

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:])
}

public struct TerminalGeometry: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    /// 120 × 32 — dimensionne le PTY avant qu'une vue existe, pour que l'Agent
    /// n'écrive jamais sur un écran de 80 × 24 qu'il faudra reflow ensuite.
    public static let `default` = TerminalGeometry(cols: 120, rows: 32)
}

/// Tout ce qu'il faut pour démarrer. Deux arguments obligatoires, le reste a un défaut.
public struct SessionLaunchPlan: Sendable {
    public var command: Command
    public var workingDirectory: URL          // le worktree, déjà créé par GitService
    /// Prompt initial. Le runtime le tape sur le PTY une fois l'enfant prêt à lire
    /// (cf. §3.7). `nil` = l'Agent est lancé sans saisie (le prompt est déjà en argv).
    public var initialInput: String?
    public var geometry: TerminalGeometry = .default
    /// `nil` → `~/Library/Application Support/Loom/transcripts/<session-id>/` (DAT-01).
    public var transcriptDirectory: URL?
    /// Cadence d'échantillonnage vers le `StateEngine`. Défaut 250 ms (STA-02).
    public var samplingInterval: Duration = .milliseconds(250)

    public init(command: Command,
                workingDirectory: URL,
                initialInput: String? = nil)
}
```

### 1.3 Le runtime

```swift
/// Une Session vivante. Non-`actor` délibérément : ADR-0007 impose une `DispatchQueue`
/// sérielle par session, et le chemin chaud de SwiftTerm livre les octets par
/// `dispatchQueue.sync { … }` — un contexte Dispatch ne peut pas entrer dans un acteur
/// de façon synchrone. L'état mutable est confiné à la queue de session ; d'où
/// `@unchecked Sendable`, avec le confinement pour preuve.
public final class SessionRuntime: @unchecked Sendable, Identifiable {

    public let id: SessionID

    // ── Cycle de vie ────────────────────────────────────────────────────────────

    /// Alloue le PTY, lance le process, démarre le parsing et le transcript.
    /// Retourne dès que l'enfant est forké — pas d'attente de « prêt ».
    public static func launch(_ plan: SessionLaunchPlan,
                              using dependencies: Dependencies = .live) async throws -> SessionRuntime

    /// Arrêt gracieux SES-06 : SIGINT au groupe de process → SIGTERM après 5 s →
    /// SIGKILL après 5 s de plus. Idempotent, ne jette jamais.
    @discardableResult
    public func stop(_ mode: StopMode = .graceful) async -> TerminationReport

    // ── Ce que SessionManager écoute ────────────────────────────────────────────

    /// **Consommateur unique.** Un seul `for await` par runtime ; un second appel
    /// renvoie un flux qui termine immédiatement (fault en debug).
    public var events: AsyncStream<Event> { get }

    // ── Ce que l'UI utilise ─────────────────────────────────────────────────────

    /// Projection `@Observable` pour le MainActor. Idempotent : le même `TerminalID`
    /// rend toujours la même instance, donc plusieurs vues peuvent la partager.
    @MainActor public func surface(_ terminal: TerminalID = .primary) -> TerminalSurface

    // ── Cas rares ───────────────────────────────────────────────────────────────

    /// Envoi sans vue attachée (« message rapide » SES-05).
    public func send(_ text: String, to terminal: TerminalID = .primary)

    /// Terminal secondaire : shell libre dans le même worktree (SES-04).
    /// `nil` → le shell de login de l'utilisateur.
    public func openShell(_ command: Command? = nil) async throws -> TerminalID
    public func closeShell(_ terminal: TerminalID) async

    /// Snapshot hors chemin UI (export, diagnostic). Coûteux : préférer `surface().screen`.
    public func snapshot(_ terminal: TerminalID = .primary) async -> TerminalScreen

    public var terminals: [TerminalID] { get }   // toujours `[.primary] + secondaires`
}

public enum StopMode: Sendable {
    case graceful                                   // SIGINT → 5 s → SIGTERM → 5 s → SIGKILL
    case immediate                                  // SIGKILL direct (quit d'urgence de l'app)
    case custom(escalation: [(Signal, Duration)])   // verbeux, rare
}
```

### 1.4 Les événements (le seul canal sortant)

```swift
extension SessionRuntime {
    public enum Event: Sendable {
        case started(pid: pid_t, at: Date)
        case activity(ActivitySample)
        case notice(Notice)                  // dégradation non fatale
        case terminated(TerminationReport)   // toujours le dernier ; le flux finit après
    }
}

/// Matière première du `StateEngine` pour le canal heuristique (STA-02).
/// Le runtime n'interprète rien : il mesure. La décision `working`/`needs_input`
/// appartient au `StateEngine`.
public struct ActivitySample: Sendable {
    public let terminal: TerminalID
    public let bytesSinceLastSample: Int
    public let silence: Duration              // depuis le dernier octet reçu
    public let cpuFraction: Double            // 0…1, groupe de process (proc_pid_rusage)
    public let visibleTail: [String]          // N dernières lignes non vides, ANSI retiré
    public let at: ContinuousClock.Instant
}

public struct TerminationReport: Sendable {
    public let exitCode: Int32?               // nil si tué par signal
    public let signal: Int32?
    public let escalation: StopEscalation     // .exitedOnItsOwn / .sigint / .sigterm / .sigkill
    public let finalScreen: TerminalScreen    // pris après drainage complet
    public let transcript: TranscriptHandle   // fichiers flushés et fermés
    public let at: Date
}

public struct Notice: Sendable {
    public enum Kind: Sendable {
        case transcriptUnavailable(any Error)   // la session continue sans transcript
        case inputBufferOverflow(droppedBytes: Int)
        case engineFedSlowerThanPTY(backlog: Int)
        case scrollbackCompacted(from: Int, to: Int)
    }
    public let kind: Kind
    public let terminal: TerminalID
    public let at: Date
}
```

### 1.5 La projection UI

```swift
/// Vit sur le MainActor. Ne contient **aucune** référence au moteur terminal :
/// c'est une valeur recopiée depuis la queue de session, jamais une fenêtre dessus.
@MainActor @Observable
public final class TerminalSurface: Identifiable {

    public let id: TerminalID

    /// **Jamais optionnel, jamais vide.** Avant le premier attachement c'est un écran
    /// vierge à la bonne géométrie ; après un détachement c'est le dernier écran connu
    /// (`screen.isStale == true`) ; attaché, c'est l'écran courant. La vue n'a donc
    /// aucun état de chargement à rendre, ce qui rend la transition carte ↔ plein écran
    /// (UIX-03) correcte dès la première frame.
    public private(set) var screen: TerminalScreen

    public private(set) var isAttached: Bool
    public private(set) var isLive: Bool          // le process tourne encore
    public private(set) var title: String         // OSC 0/2, sinon le nom de l'exécutable

    /// **Le chemin normal.** Attache à l'entrée, détache à l'annulation.
    /// Conçu pour `.task { await surface.attached() }` : impossible d'oublier le détach.
    public func attached() async

    public func send(_ text: String)
    public func send(bytes: ArraySlice<UInt8>)

    /// Une seule opération pour l'appelant ; deux en interne (moteur + `TIOCSWINSZ`).
    /// Coalescé : seule la dernière valeur d'un cycle atteint le PTY.
    public func resize(cols: Int, rows: Int)

    // ── Cas rares ───────────────────────────────────────────────────────────────
    public func attach()                       // si le cycle de vie n'est pas structuré
    public func detach()
    /// Pour un renderer à redessin partiel. La plupart des vues lisent `screen` et
    /// comparent `screen.revision`.
    public private(set) var dirtyRows: IndexSet
}

public struct TerminalScreen: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    public let lines: [TerminalLine]           // **écran visible uniquement**, jamais le scrollback
    public let cursor: CursorPosition
    public let revision: UInt64                // monotone ; égal ⇒ rien à redessiner
    public let isStale: Bool                   // affiché avant l'arrivée du snapshot frais
    public static func blank(_ g: TerminalGeometry) -> TerminalScreen
}
```

### 1.6 Erreurs

`launch` est le **seul** point qui jette, et uniquement pour ce qui rend la Session
impossible :

```swift
public enum SessionRuntimeError: Error, Sendable {
    case executableNotFound(String)              // diagnostic guidé UIX-06
    case workingDirectoryUnavailable(URL, any Error)
    case ptyAllocationFailed(errno: Int32)
    case forkFailed(errno: Int32)
    case sessionLimitReached(active: Int, limit: Int)   // SES-09
}
```

Tout le reste est **non fatal et non jetant**, par choix : un transcript qui ne s'ouvre
pas, un buffer d'entrée qui déborde, un scrollback compacté remontent en `.notice`. Le
chemin courant n'a donc qu'un seul `try`, à la création. `send`, `resize` et `stop` ne
jettent jamais — la vue terminal n'a pas de `do/catch` sur la frappe clavier.

### 1.7 Invariants

1. **Confinement (ADR-0007).** Une `DispatchQueue` sérielle par Session, partagée par
   ses terminaux. Toute interaction avec le moteur — `feed`, `resize`, snapshot, lecture
   de buffer — est marshalée dessus, sans exception. Aucune API publique n'expose cette
   queue ; il est structurellement impossible pour un appelant de toucher le moteur.
2. **Rien par-chunk sur le MainActor.** Le MainActor ne reçoit que des `TerminalScreen`
   déjà construits, au plus un par rafraîchissement d'écran et uniquement pour les
   surfaces attachées.
3. **Détaché ≠ mort.** Une surface détachée ne produit aucune frame et aucun snapshot ;
   le parsing, le transcript et l'échantillonnage continuent à plein régime (TRM-03).
4. **`screen` n'est jamais vide.** Voir §1.5.
5. **`.terminated` est le dernier événement** et n'est émis qu'après : arrêt de la
   lecture PTY, **drainage complet de la queue de session**, snapshot final, flush et
   fermeture du transcript. Quand un appelant le reçoit, le transcript sur disque est
   complet et `finalScreen` contient les derniers octets. Le flux `events` termine
   immédiatement après.
6. **La fin de session vient de l'exit, jamais de l'EOF du PTY.** Les deux événements
   arrivent dans un ordre non garanti ; l'EOF ne conclut rien.
7. **`stop()` est idempotent** et sûr après une sortie naturelle : il rend alors le
   `TerminationReport` mémorisé, sans envoyer de signal.
8. **`surface(_:)` est idempotent** : une instance par `TerminalID`, partagée. Les
   attachements sont comptés ; le détachement effectif a lieu au dernier `detach`.

### 1.8 Contraintes d'ordre d'appel

| Ordre | Règle |
|---|---|
| `launch` avant tout le reste | Garanti par le type : on ne peut pas obtenir un `SessionRuntime` autrement. |
| `attach` / `detach` | Doivent s'équilibrer. `attached()` le fait pour vous — c'est la raison de son existence. |
| `resize` avant attachement | Autorisé. Dernière valeur gagnante. |
| `send` avant `.started` | Autorisé : bufferisé (64 Ko). Au-delà, les octets les plus anciens sont abandonnés avec un `.notice`. |
| `events` non consommé | Toléré : tampon de 256 événements ; les `.activity` sont abandonnés les plus anciens d'abord, **`.started`, `.notice` et `.terminated` ne sont jamais abandonnés**. |
| `openShell` | Uniquement tant que `isLive`. Après `.terminated`, jette. |
| Relâchement de la dernière référence | **Appeler `stop()` d'abord.** Le `deinit` ferme les I/O mais **n'envoie aucun signal** (le `deinit` de `LocalProcess` ne fait pas de SIGTERM) : oublier `stop()` laisse un Agent orphelin. Un fault est levé en debug. |

### 1.9 Caractéristiques de performance

| Chemin | Caractéristique |
|---|---|
| PTY → moteur | ≥ 20 Mo/s soutenu, sans allocation par chunk (l'`ArraySlice` de `DispatchIO` va au `feed` sans copie). Backpressure implicite : la boucle de lecture ne se réarme qu'après le `feed`, donc le kernel bloque l'enfant en `write()` — comme n'importe quel terminal. |
| Frappe → écho | ≤ 16 ms ajoutées. `send` est non bloquant, non `async`, non jetant. |
| Attachement | **0 ms de contenu** (l'écran de détachement est déjà en mémoire sur le MainActor, `isStale == true`), snapshot frais typiquement en une frame, **p99 < 100 ms** (TRM-03). |
| Snapshot | O(cols × rows) sur l'écran visible. **Jamais** un dump du buffer complet — le scrollback n'y est pas. |
| Frames | Au plus une par rafraîchissement d'écran (60–120 Hz), et **seulement si `revision` a changé** et la surface est attachée. Zéro frame pour une session non visible. |
| Échantillonnage | ≤ 4 Hz par terminal, indépendant du débit ; `visibleTail` borné à 12 lignes. |
| Mémoire | Scrollback 10 000 lignes attaché ; compacté à 1 000 après 30 s de détachement, restauré à l'attachement (NFR-M), avec un `.notice`. Cache d'images Kitty plafonné à 16 Mo par session, pas les 320 Mo par défaut. |
| Arrêt | `stop(.graceful)` rend la main en ≤ 10 s dans le pire cas (5 s + 5 s), typiquement < 200 ms. |

---

## 2. Exemple d'usage

### 2.1 UC-1 — `SessionManager` crée une Session

```swift
extension SessionManager {

    func startSession(_ spec: SessionSpec) async throws -> SessionID {
        let worktree = try await git.createWorktree(for: spec)          // GIT-01
        let command  = adapter(for: spec.agentID).launchCommand(for: spec)

        // Le seul appel. Aucune queue, aucun environnement, aucun chemin de transcript,
        // aucun adapter à fournir.
        let runtime = try await SessionRuntime.launch(
            SessionLaunchPlan(command: command,
                              workingDirectory: worktree.url,
                              initialInput: spec.initialPrompt)
        )

        runtimes[runtime.id] = runtime
        try await store.insert(SessionRecord(id: runtime.id, state: .starting, …))
        pumps[runtime.id] = Task { await pump(runtime) }
        return runtime.id
    }

    /// Une seule boucle pour tout ce qui remonte d'une Session vivante.
    private func pump(_ runtime: SessionRuntime) async {
        for await event in runtime.events {
            switch event {
            case .started(let pid, let at):
                await stateEngine.apply(.processStarted(pid), to: runtime.id,
                                        source: .process, at: at)   // → working, la carte s'anime

            case .activity(let sample):
                await stateEngine.observe(sample, for: runtime.id)  // canal heuristique STA-02

            case .notice(let notice):
                logger.warning("session \(runtime.id): \(notice.kind)")

            case .terminated(let report):
                // Le transcript est complet sur disque, `finalScreen` est à jour :
                // aucune course à gérer ici.
                await stateEngine.apply(.processExited(report.exitCode), to: runtime.id,
                                        source: .process, at: report.at)   // → completed / failed
                await store.finish(runtime.id, exitCode: report.exitCode, endedAt: report.at)
                runtimes[runtime.id] = nil
            }
        }
    }
}
```

### 2.2 SES-06 — arrêt, et fermeture de l'app

```swift
func stopSession(_ id: SessionID) async {
    guard let runtime = runtimes[id] else { return }
    let report = await runtime.stop()          // SIGINT → 5 s → SIGTERM → SIGKILL
    logger.info("session \(id) arrêtée par \(report.escalation)")
    // `.terminated` arrive aussi dans `pump` ; les deux voient le même rapport.
}

func applicationWillTerminate() async {
    await withTaskGroup(of: Void.self) { group in
        for runtime in runtimes.values {
            group.addTask { await runtime.stop() }   // en parallèle : chaque session a sa queue
        }
    }
}
```

### 2.3 UC-3 — la vue SwiftUI attache et détache

```swift
struct SessionTerminalView: View {
    @State private var surface: TerminalSurface

    init(runtime: SessionRuntime) {
        _surface = State(initialValue: runtime.surface())   // .primary par défaut
    }

    var body: some View {
        TerminalCanvas(screen: surface.screen)              // jamais nil, jamais vide
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                let cells = TerminalMetrics.cells(fitting: size)
                surface.resize(cols: cells.cols, rows: cells.rows)
            }
            .task { await surface.attached() }              // ← tout le cycle de vie
            .onKeyPress { surface.send($0.characters); return .handled }
            .navigationTitle(surface.title)
    }
}
```

Une carte de session qui veut un aperçu de la dernière sortie (SES-03) sans jamais
attacher lit simplement `runtime.surface().screen` : elle obtient le dernier écran connu,
`isStale == true`, sans coût de rendu ni frame produite.

### 2.4 Cas rare — terminal secondaire (SES-04)

```swift
let shell = try await runtime.openShell()          // shell de login, même worktree
let shellSurface = await runtime.surface(shell)    // même API, même cycle de vie
```

### 2.5 Un test, à travers la même interface

```swift
@Test func laSessionPasseAWorkingPuisCompleted() async throws {
    let pty = ScriptedPTYHost()
    let runtime = try await SessionRuntime.launch(
        SessionLaunchPlan(command: .init(executable: "/fake/claude"),
                          workingDirectory: .fakeWorktree,
                          initialInput: "corrige le bug"),
        using: .fake(ptyHost: pty, clock: testClock))

    var events = runtime.events.makeAsyncIterator()
    #expect(await events.next() ~= .started)
    #expect(pty.writtenText.contains("corrige le bug"))

    pty.emit("Analyse du dépôt…\r\n")
    pty.exit(code: 0)

    guard case .terminated(let report) = await events.next() else { return #expect(Bool(false)) }
    #expect(report.exitCode == 0)
    #expect(report.finalScreen.lines[0].text == "Analyse du dépôt…")   // drainé avant l'exit
    #expect(report.transcript.rawBytes.contains("Analyse"))
}
```

Le test franchit exactement le même seam que `SessionManager`. Aucun accès à la queue,
au moteur ou au tee.

---

## 3. Ce que l'implémentation cache derrière le seam

Chaque point ci-dessous est un piège documenté par la recherche ou une exigence du
cahier des charges. Il est résolu **une fois**, ici — c'est la localité que le module achète.

1. **La queue sérielle par session** (ADR-0007) et tout le marshalling : `feed`, `resize`,
   snapshot, lecture de buffer. Aucun appelant ne voit une `DispatchQueue`, donc aucun
   appelant ne peut violer le confinement.
2. **Le piège de la queue par défaut** : `HeadlessTerminal`/`LocalProcess` livrent sur la
   **main queue** quand aucune queue n'est fournie — la doc DocC affirme le contraire.
   Le runtime passe toujours une queue sérielle explicite.
3. **La fausse thread-safety de SwiftTerm.** Le moteur n'a aucune primitive de
   synchronisation ; le contrat réel est du thread-confinement. Le module l'applique,
   et rend l'invariant inatteignable depuis l'extérieur.
4. **`PATH` absent de l'environnement par défaut** (SwiftTerm le commente explicitement).
   Le runtime compose `TERM`/`COLORTERM`/`LANG`/`HOME`/`USER` + un `PATH` résolu depuis
   le shell de login, puis applique l'overlay de l'appelant. Sans ça, `bash -c` échoue en
   « command not found » sur des binaires présents.
5. **Resize = deux opérations** : `terminal.resize(cols:rows:)` **et**
   `PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)` — `HeadlessTerminal`
   ne fait pas le second. Coalescé pour ne pas inonder le PTY pendant un drag de fenêtre.
6. **La course EOF / exit.** L'EOF du PTY passe `running` à `false` sans notifier ; seul
   `NOTE_EXIT` porte le code de sortie, et il n'est délivré **qu'une fois** (le handler
   doit être posé avant `activate()`). Le runtime attend l'exit, puis drainer la queue,
   puis snapshot, puis flush, puis `.terminated`.
7. **Le timing du prompt initial.** Taper immédiatement dans le PTY d'un TUI qui n'a pas
   fini de s'initialiser perd la saisie. Le runtime attend le premier octet de sortie
   suivi d'une accalmie courte, avec un plancher et un plafond, avant d'injecter
   `initialInput`.
8. **Le tee.** Un même `ArraySlice` alimente trois consommateurs sur la queue de session :
   `TranscriptSink` (batché 250 ms, flux brut + version dé-ANSI-isée pour FTS5, rotation
   10 Mo — DAT-01), `TerminalEngine.feed`, et l'échantillonneur.
9. **L'échantillonnage.** Fenêtre de silence, octets par intervalle, CPU du groupe de
   process via `proc_pid_rusage`, et queue visible dé-ANSI-isée — mesuré à cadence fixe,
   jamais par chunk. Le runtime ne décide d'aucun état : il fournit la matière au `StateEngine`.
10. **La politique de snapshot.** Écran visible via `getLine(row:)` borné à `rows`, **pas**
    `getBufferAsData()` qui inclut le scrollback. Compteur de révision, régions sales,
    coalescence à la cadence d'affichage, zéro production quand détaché.
11. **La compaction mémoire** : `changeScrollback` à la baisse après 30 s de détachement,
    restauration à l'attachement, plafond du cache d'images Kitty (NFR-M).
12. **L'escalade de signaux** sur le **groupe de process** (`killpg`), pas seulement le pid,
    pour atteindre les descendants de l'Agent (TRM-02, SES-06), avec les temporisations
    portées par une horloge injectée.
13. **Le nettoyage du descripteur** : ne jamais `close()` un fd encore détenu par un
    `DispatchIO` (crash EV_VANISHED) ; fermeture dans le `cleanupHandler`, et `terminate()`
    toujours appelé.
14. **La cartographie terminaux → une seule queue de session**, avec la sérialisation des
    snapshots qui en découle (deux terminaux d'une même Session ne peuvent pas produire des
    écrans incohérents entre eux).

**Test de suppression.** Si l'on supprime `SessionRuntime`, ces quatorze points
réapparaissent chez ses appelants : `SessionManager` devrait posséder la queue, l'ordre
EOF/exit et l'escalade de signaux ; chaque vue terminal devrait connaître le confinement,
la double opération de resize et la politique de snapshot. Le module n'est pas un
pass-through.

---

## 4. Stratégie de dépendances et adapters

Les seams ci-dessous sont **internes** : ils sont des paramètres avec défaut, pas des
concepts que l'appelant courant rencontre.

```swift
extension SessionRuntime {
    public struct Dependencies: Sendable {
        public var ptyHost: any PTYHost
        public var makeEngine: @Sendable (TerminalGeometry, DispatchQueue) -> any TerminalEngine
        public var makeTranscript: @Sendable (SessionID, TerminalID) throws -> any TranscriptSink
        public var clock: any Clock<Duration>
        public var environment: EnvironmentResolver

        public static let live: Dependencies
        public static func fake(ptyHost: ScriptedPTYHost = .init(),
                                clock: TestClock = .init()) -> Dependencies
    }
}
```

### 4.1 PTY / process — **local-substitutable, seam réel (2 adapters)**

```swift
public protocol PTYHost: Sendable {
    func start(_ command: Command, in directory: URL,
               geometry: TerminalGeometry, deliveringOn queue: DispatchQueue) throws -> PTYChannel
}

public protocol PTYChannel: Sendable {
    var pid: pid_t { get }
    func write(_ bytes: ArraySlice<UInt8>)
    func setWindowSize(_ geometry: TerminalGeometry)
    func signalProcessGroup(_ signal: Signal)
    func cpuFraction() -> Double                     // proc_pid_rusage, replié ici : le
                                                     // channel possède déjà le pid
    var onData: (@Sendable (ArraySlice<UInt8>) -> Void)? { get set }   // sur `queue`
    var onExit: (@Sendable (Int32?, Int32?) -> Void)? { get set }      // exitCode, signal
    func close()
}
```

- **Prod — `ForkPTYHost`.** `forkpty` (donc `openpty` + `fork` + `login_tty` : nouvelle
  session et terminal de contrôle sans `setsid` manuel), boucle `DispatchIO` de lecture,
  `DispatchSource.makeProcessSource(.exit)` avec handler posé **avant** `activate()`,
  `ioctl(TIOCSWINSZ)`, `killpg`, fermeture du fd dans le `cleanupHandler`.
- **Test — `ScriptedPTYHost`.** Alimenté par des octets en mémoire ou un fichier de
  script/`.cast` ; `emit(_:)`, `exit(code:)`, `exit(signal:)`, `writtenText` pour vérifier
  ce que le runtime a tapé, `cpuFraction` programmable. Aucun process réel, donc les tests
  d'endurance (créer/détruire 100 sessions, NFR-M) tournent en CI sans forker.

Deux adapters justifient le seam : ce n'est pas de l'indirection hypothétique. Il porte
aussi la trajectoire v2 (backend tmux) annoncée en §6.4 du cahier — mais ce n'est pas ce
qui le justifie aujourd'hui.

### 4.2 Moteur terminal — **in-process tiers, seam réel (2 adapters)**

```swift
public protocol TerminalEngine: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    func snapshot() -> TerminalScreen        // écran visible ; incrémente `revision`
    func takeDirtyRows() -> IndexSet
    func setScrollback(_ lines: Int?)
    var title: String { get }
    var delegate: TerminalEngineDelegate? { get set }   // send(source:data:), bell, titre
}
```

Élargissement volontaire par rapport au contrat §6.2 du cahier : `snapshot()`,
`takeDirtyRows()` et `setScrollback(_:)` y sont ajoutés, parce que sans eux la politique
de snapshot et la compaction mémoire fuiraient chez l'appelant. **Toutes** les méthodes
sont appelées sur la queue de session.

- **Prod — `SwiftTermEngine`.** `Terminal` (pas `HeadlessTerminal` : le runtime possède
  déjà le PTY, il ne veut que le moteur), délégué headless minimal — une seule méthode est
  réellement obligatoire, `send(source:data:)`. Version SPM épinglée en
  `.upToNextMinor(from: "1.18.0")` : cadence de release rapide et refonte annoncée de la
  couche I/O.
- **Test — `LineEngine`.** Buffer de lignes, pas d'ANSI hors `\r\n` et effacement d'écran,
  snapshot déterministe. Rend les assertions sur l'écran lisibles et robustes.

Le seam a un second usage réel : c'est le point d'ancrage de la migration libghostty
prévue par TRM-01 — sous réserve du trade-off de §5.4.

### 4.3 Transcript / disque — **local-substitutable, seam réel (2 adapters)**

```swift
public protocol TranscriptSink: Sendable {
    func append(_ bytes: ArraySlice<UInt8>)   // sur la queue de session, batché en interne
    func flush() async
    func close() async -> TranscriptHandle
}
```

- **Prod — `FileTranscriptSink`.** Deux flux (brut + texte dé-ANSI-isé pour FTS5), batch
  250 ms, rotation à 10 Mo, écritures atomiques (NFR-R), sous
  `~/Library/Application Support/Loom/transcripts/<session-id>/`.
- **Test — `MemoryTranscriptSink`.** Octets en mémoire, plus un mode `failing` pour
  vérifier que l'ouverture impossible produit un `.notice` et **non** un échec de `launch`.

### 4.4 Horloge — **in-process, seam réel (2 adapters)**

`any Clock<Duration>` porte les 5 s de SES-06, les fenêtres de silence, la cadence
d'échantillonnage et le délai de compaction. `ContinuousClock` en prod, `TestClock` en
test : l'escalade SIGINT → SIGTERM → SIGKILL se vérifie en millisecondes.

### 4.5 Environnement — **in-process**

`EnvironmentResolver` compose la base (`TERM`, `COLORTERM`, `LANG`, `HOME`, `USER`) et
résout `PATH` depuis le shell de login. Un seul adapter en prod, une valeur figée en test :
pas un seam, juste une valeur injectable — conforme à la discipline « un seul adapter =
seam hypothétique ».

### 4.6 Ce qui reste dehors

Hooks IPC, GRDB, GitService, machine à états, notifications. Le runtime **mesure** et
**transmet** ; il n'interprète pas. `needs_input` n'existe pas dans son vocabulaire.

### 4.7 Stratégie de test : remplacer, pas empiler

L'interface est la surface de test. Aucun test ne franchit la queue ni ne touche le
moteur. Trois familles :

1. **Cycle de vie** — `launch` → `.started` → `.terminated`, ordre garanti, transcript
   complet à `.terminated`, escalade des signaux sous `TestClock`.
2. **Attachement** — `screen` non vide avant attachement, `isStale` qui bascule, absence
   totale de frames quand détaché, réattachement sous les 100 ms, compaction du scrollback.
3. **Débit** — `ScriptedPTYHost` injectant 200 Mo, sous Thread Sanitizer, en ciblant le
   mode DEC 2026 (seul endroit où le moteur touche la main queue de lui-même) ; build
   Release, charge ≥ 10 Mo, runs appariés.

---

## 5. Trade-offs

### 5.1 Où le levier est fort

- **UC-1 tient en un appel et une boucle.** `SessionManager` n'apprend que
  `launch`/`events`/`stop` — trois éléments — et obtient PTY, parsing, transcript,
  échantillonnage, escalade de signaux et ordonnancement de fin. C'est le meilleur rapport
  comportement/interface du module.
- **UC-3 tient en une ligne.** `.task { await surface.attached() }` rend la faute
  classique — attacher dans `onAppear`, oublier `onDisappear`, laisser une session
  invisible produire des frames — **non représentable**. Le cycle de vie suit l'annulation
  structurée de SwiftUI.
- **`screen` non optionnel supprime un état de l'UI.** Pas de skeleton, pas de spinner, pas
  de branche « pas encore chargé » dans la vue terminal ni dans la carte de session. C'est
  aussi ce qui rend la transition animée UIX-03 correcte dès la première frame, sans
  synchroniser l'animation sur l'arrivée des données.
- **La garantie d'ordonnancement de `.terminated`** retire une classe entière de bugs à
  *tous* les appelants : personne n'a à se demander si le transcript est complet, si le
  dernier chunk est parsé, ou si l'EOF précède l'exit.
- **Un seul flux sortant** au lieu de trois délégués (données, état, terminaison) : une
  boucle, un `switch`, un point d'annulation.
- **Les quatorze pièges de §3 sont corrigés une fois.** Ajouter un troisième agent ou une
  seconde vue terminal ne les rouvre pas.

### 5.2 Où le levier est mince

- **Le coût des frames en valeur.** `TerminalScreen` est un type valeur recopié vers le
  MainActor. Sur une fenêtre large (240 × 70 ≈ 17 000 cellules) à 120 Hz, ce n'est pas
  gratuit. Atténuations : au plus une frame par rafraîchissement, uniquement si
  `revision` change, uniquement pour les surfaces attachées (typiquement une seule),
  et `dirtyRows` en échappatoire. Mais si le profil dit non, il faudra une représentation
  partagée immuable — changement **interne**, invisible des appelants, ce qui est
  précisément l'assurance que le seam achète.
- **`isStale` est un mensonge assumé.** Une session qui a beaucoup produit pendant son
  détachement affiche brièvement un écran périmé. Sous les 100 ms visés, mais visible si
  on le cherche. Le prix payé pour supprimer l'état vide.
- **Flux à consommateur unique.** Le panneau de diagnostic STA-06 veut aussi voir les
  transitions ; il devra passer par une rediffusion faite par `SessionManager`. Un flux
  multi-abonnés aurait rendu l'API plus permissive et le cas courant plus compliqué (choisir
  une politique de tampon par abonné). Choix : le cas courant gagne, le cas rare paie.
- **Une queue par Session, partagée par ses terminaux** (fidèle à ADR-0007). Un shell
  secondaire qui inonde sa sortie ralentit le parsing du terminal de l'Agent **de la même
  Session**. Rayon d'action borné et connu ; une queue par terminal serait plus isolante
  mais casserait la cohérence temporelle des snapshots entre terminaux d'une même Session
  et s'écarterait de l'ADR.
- **Les défauts sont opinionnés, et calibrés sur Claude Code** : 120 × 32, 250 ms
  d'échantillonnage, 12 lignes de queue visible, 10 000/1 000 lignes de scrollback. Un agent
  au comportement différent (Codex, Gemini) devra passer par le chemin verbeux de
  `SessionLaunchPlan`, et ces défauts devront peut-être devenir des valeurs par
  `AgentAdapter` — auquel cas la simplicité du cas par défaut se déplacerait d'un cran.
- **`stop()` avant relâchement est une obligation non typée.** C'est la seule règle
  d'ordre que le compilateur ne fait pas respecter, et son oubli laisse un Agent orphelin.
  Une API à portée (`withSessionRuntime { … }`) la rendrait sûre, mais une Session survit à
  toute portée lexicale par nature — le confort du cas courant l'emporte, au prix d'un
  fault en debug.

### 5.3 Ce que le design refuse explicitement

- **D'exposer le moteur.** Aucun `getTerminal()`, aucune queue, aucun `Terminal`. C'est ce
  qui rend le confinement d'ADR-0007 structurel plutôt que disciplinaire.
- **De décider d'un état de Session.** Le runtime n'émet jamais `working` ni `needs_input` ;
  il émet des mesures. La frontière `idle`/`needs_input` appartient au `StateEngine`, qui
  arbitre Hook contre Heuristique (STA-03).
- **De créer ou détruire un worktree.** Il reçoit un répertoire de travail existant.

### 5.4 Le risque principal

L'interface est **orientée snapshot** : elle suppose que Loom dessine lui-même le
terminal à partir de valeurs, conformément au chemin chaud décrit en §6.3 du cahier. Si la
v1.x adopte un renderer tiers qui exige de posséder son propre moteur et sa propre vue —
`TerminalView` de SwiftTerm, ou libghostty via TRM-01 — alors `TerminalSurface` est de la
mauvaise forme : il faudrait percer un trou (« donne-moi la vue native ») qui ferait fuir
le moteur hors du seam et ruinerait l'invariant n°1. La parade n'est pas dans l'interface
mais dans la décision : **valider tôt, par un prototype de rendu à 120 Hz sur une session
en streaming continu, que le rendu depuis snapshots tient les objectifs de NFR-P.** Si ce
n'est pas le cas, c'est ce design qu'il faut revoir, pas ses appelants.
