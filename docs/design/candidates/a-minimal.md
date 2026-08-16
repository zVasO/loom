# Design A — `SessionRuntime` : interface minimale

**Contrainte de ce candidat** : minimiser l'interface. Cible 1 à 3 points d'entrée, levier maximal par point d'entrée.

**Résultat** : **3 points d'entrée**, un seul constructeur, aucune propriété publique mutable sur le module.

```
SessionRuntime.start(_:in:)  → crée tout ce qui est vivant, rend le runtime + le flux d'événements
runtime.attach(_:)           → seul accès à un terminal vivant (snapshot, frames, entrée, resize)
runtime.stop(_:)             → arrêt gracieux escaladé, idempotent, rend l'issue finale
```

Tout le reste — la queue sérielle, le PTY, le moteur, le tee vers le Transcript, l'échantillonnage,
la course EOF/exit, le `PATH`, le double resize — est derrière le seam.

---

## 1. Interface

### 1.1 Le module

```swift
import Dispatch
import Foundation

/// Possède tout ce qui est vivant dans une session : le process de l'agent sur son PTY,
/// le moteur terminal, le tee vers le Transcript, l'échantillonnage vers la machine à états,
/// et le snapshot d'écran pour le réattachement de vue.
///
/// C'est un `actor` dont l'exécuteur sérial *est* la DispatchQueue de session (ADR-0007) :
/// le confinement n'est pas une convention, c'est l'isolation d'acteur.
public actor SessionRuntime {

    // ───────── Point d'entrée 1 : naissance ─────────

    /// Seul constructeur. À son retour : le PTY est ouvert, le process de l'agent est lancé,
    /// le moteur terminal existe, le tee vers le transcript est armé, l'échantillonnage tourne.
    ///
    /// Le flux d'événements est rendu **ici et une seule fois** : `AsyncStream` est mono-consommateur,
    /// le rendre à la naissance rend cette propriété structurelle plutôt que documentaire.
    /// L'appelant qui reçoit ce flux (SessionManager) en est le propriétaire et fait le fan-out.
    public static func start(
        _ plan: SessionPlan,
        in environment: RuntimeEnvironment = .live
    ) async throws(SessionRuntimeError) -> (runtime: SessionRuntime, events: AsyncStream<SessionEvent>)

    // ───────── Point d'entrée 2 : attachement d'une vue ─────────

    /// Seul accès à un terminal vivant. L'attachement rendu porte le snapshot initial,
    /// le flux de frames, l'envoi d'entrée et le resize.
    ///
    /// Relâcher l'attachement (ARC) détache : plus aucune frame n'est matérialisée pour lui.
    /// Le terminal, lui, continue de parser et d'alimenter le transcript (TRM-03).
    ///
    /// `.newShell` ouvre *et* attache un terminal secondaire (SES-04) : on n'ouvre jamais
    /// un shell libre sans vouloir le regarder.
    public func attach(_ target: TerminalTarget) throws(SessionRuntimeError) -> TerminalAttachment

    // ───────── Point d'entrée 3 : mort ─────────

    /// Arrêt escaladé (SES-06). Idempotent, sûr en concurrence, et valide après une sortie
    /// naturelle : tous les appelants reçoivent la même `SessionOutcome`.
    @discardableResult
    public func stop(_ policy: StopPolicy = .graceful) async -> SessionOutcome
}
```

### 1.2 Ce que l'appelant fournit

```swift
/// Données de domaine uniquement. Aucun adapter ici.
public struct SessionPlan: Sendable {
    public var sessionID: SessionID
    public var command: LaunchCommand
    public var geometry: TerminalGeometry            // défaut : 120 × 32
    public var scrollback: ScrollbackPolicy          // défaut : .visible(10_000), .detached(2_000)
    public var sampling: SamplingPolicy              // défaut : .init(period: .milliseconds(500), tailLines: 24)
    public var maxSecondaryTerminals: Int            // défaut : 4
}

/// Binaire, arguments, répertoire de travail (worktree), variables *additionnelles*.
/// Le runtime construit lui-même `TERM`, `COLORTERM`, `LANG`, `HOME`… **et `PATH`**.
public struct LaunchCommand: Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL
    public var extraEnvironment: [String: String]    // fusionné par-dessus la base, gagne en cas de collision
}

public struct TerminalGeometry: Sendable, Equatable { public var cols: Int; public var rows: Int }

public enum TerminalTarget: Sendable {
    case agent                                       // terminal principal
    case terminal(TerminalID)                        // terminal secondaire déjà ouvert
    case newShell(ShellSpec = .loginShell)           // ouvre + attache (SES-04)
}

public struct StopPolicy: Sendable {
    public var interruptFirst: Bool                  // SIGINT au groupe de process
    public var graceBeforeTerminate: Duration        // puis SIGTERM
    public var graceBeforeKill: Duration             // puis SIGKILL
    public static let graceful = StopPolicy(interruptFirst: true,
                                            graceBeforeTerminate: .seconds(5),
                                            graceBeforeKill: .seconds(5))
    public static let immediate = StopPolicy(interruptFirst: false,
                                             graceBeforeTerminate: .zero,
                                             graceBeforeKill: .seconds(2))
}
```

### 1.3 L'attachement

```swift
/// Handle vivant sur un terminal. Sa durée de vie *est* la durée de l'attachement.
public final class TerminalAttachment: Sendable {

    public let terminalID: TerminalID
    public let kind: TerminalKind                    // .agent | .shell

    /// Écran visible au moment de l'attachement, déjà matérialisé : la vue peint
    /// sans attendre une première frame. C'est le chemin du « réattachement < 100 ms ».
    public let initialSnapshot: TerminalScreen

    /// Frames coalescées, **produites à la demande** : tant que le consommateur n'a pas
    /// consommé la précédente, aucune copie d'écran n'est faite. Pas d'attachement
    /// ⇒ pas de frame ⇒ pas de rendu pour les sessions non visibles (TRM-04, §6.3).
    public var frames: TerminalFrames { get }        // AsyncSequence<TerminalFrame, Never>

    public func send(_ text: String)
    public func send(bytes: [UInt8])

    /// Un seul appel côté appelant ; deux opérations côté implémentation
    /// (moteur + `TIOCSWINSZ` sur le PTY).
    public func resize(to geometry: TerminalGeometry)

    deinit  // détache
}

public struct TerminalFrame: Sendable {
    public let screen: TerminalScreen
    public let dirtyRows: Range<Int>                 // pour un repaint partiel
}

/// Écran **visible** uniquement — jamais le scrollback (piège documenté : recherche §1.4).
public struct TerminalScreen: Sendable, Equatable {
    public struct Cell: Sendable, Equatable { public var scalar: Character; public var style: CellStyle }
    public let cols: Int, rows: Int
    public let cells: [Cell]                         // rows × cols, indexé y * cols + x
    public let cursor: CursorPosition
    public let cursorVisible: Bool
    public let title: String?                        // OSC 0/2 → barre d'état TRM-08
    public let revision: UInt64                      // monotone par terminal
}
```

### 1.4 Ce que le module rend à ses appelants

```swift
public enum SessionEvent: Sendable {
    case terminalOpened(TerminalID, TerminalKind)    // .agent émis en premier, toujours
    case terminalClosed(TerminalID, exitCode: Int32?)
    case screenSampled(ScreenSample)                 // → StateEngine (heuristiques, STA-02)
    case exited(SessionOutcome)                      // dernier événement ; le flux finit après
}

/// Tout ce dont STA-02 a besoin, prélevé sur la queue de session : silence du flux,
/// motifs de fin d'écran, activité CPU du groupe de process.
public struct ScreenSample: Sendable {
    public let terminalID: TerminalID
    public let at: Date
    public let tailLines: [String]                   // N dernières lignes visibles, ANSI retiré
    public let bytesSinceLastSample: Int
    public let quietFor: Duration                    // depuis le dernier octet reçu
    public let cpu: CPUSample                        // proc_pid_rusage sur le groupe
}

public struct SessionOutcome: Sendable {
    public let exitCode: Int32?                      // nil si tué avant de pouvoir être moissonné
    public let reason: TerminationReason             // .processExited | .stoppedByUser(.sigint/.sigterm/.sigkill) | .launchFailure
    public let finalScreens: [TerminalID: TerminalScreen]   // pris **après** drainage de la queue
    public let endedAt: Date
}

public enum SessionRuntimeError: Error, Sendable {
    case executableNotFound(String)                  // exit 127 de l'enfant, ou introuvable dans le PATH construit
    case launchFailed(errno: Int32)                  // forkpty / execve
    case workingDirectoryUnreadable(URL)
    case unknownTerminal(TerminalID)
    case sessionEnded                                // attach après `.exited`
    case secondaryTerminalLimitReached(max: Int)
}
```

### 1.5 Invariants

1. **Confinement (ADR-0007)** — aucun appelant ne voit jamais une instance `Terminal`. Toute lecture
   ou mutation du moteur se fait sur l'exécuteur sérial de l'acteur, qui *est* la `DispatchSerialQueue`
   de la session. Ce qui traverse le seam est exclusivement des valeurs `Sendable` (`TerminalScreen`,
   `ScreenSample`, `SessionOutcome`).
2. **Un runtime = une session, du `start` au `.exited`.** Pas de réutilisation, pas de redémarrage
   en place. La Reprise (`claude --resume`) est un nouveau `start` avec une autre `LaunchCommand` —
   voir §2.
3. **La fin de session ne se détecte que par l'exit du process**, jamais par l'EOF du PTY
   (recherche §7.4). Les deux arrivent dans un ordre non garanti ; le runtime absorbe la course.
4. **`finalScreens` est pris après drainage** de la queue de session : le dernier lot d'octets est
   parsé avant le snapshot final.
5. **Le transcript reçoit les octets bruts avant le parsing.** Un crash à l'intérieur du moteur ne
   perd donc aucun octet déjà lu (NFR-R).
6. **Le scrollback n'est jamais dans un `TerminalScreen`.** Le transcript est la seule source
   d'historique intégral (DAT-01).
7. **Une géométrie faisant autorité par terminal.** Plusieurs attachements sont autorisés (fenêtres
   multiples) ; `resize` est *last-writer-wins*, et tous les attachements observent la nouvelle
   géométrie à leur frame suivante.

### 1.6 Contraintes d'ordre d'appel

- `start` d'abord ; il n'y a rien avant.
- `attach` à tout moment entre `start` et `.exited`. Après `.exited` → `.sessionEnded`.
- `stop` à tout moment, y compris concurremment avec lui-même et après une sortie naturelle.
- Les attachements peuvent survivre à `stop` : ils rendent la dernière frame puis leur flux finit.
  L'UI n'a pas à se détacher avant d'arrêter.
- Ordre des événements garanti : `.terminalOpened(agent)` en premier ; `.exited` en dernier ;
  le flux `finish()` juste après.

### 1.7 Modes d'erreur

| Situation | Comportement |
|---|---|
| Binaire introuvable / `execve` échoue | `start` lève `.executableNotFound` (l'enfant sort en 127, le runtime le traduit) |
| Worktree supprimé sous les pieds | `.workingDirectoryUnreadable` au `start` ; en cours de session, le shell le gère, pas le runtime |
| PTY saturé | Aucune erreur : contre-pression implicite (§1.8), l'enfant bloque en `write()` |
| Le sink de transcript lève | Journalisé, session **non** interrompue ; un `SessionEvent` de diagnostic n'existe pas volontairement — le transcript est best-effort face à la survie de la session |
| Process tué hors de l'app (`kill -9` externe) | `.exited` avec `reason: .processExited`, `exitCode: nil` |
| `attach` sur un TerminalID inconnu ou fermé | `.unknownTerminal` |
| Crash de l'UI | Le runtime ne dépend d'aucun attachement ; parsing et transcript continuent |

### 1.8 Caractéristiques de performance

- **Débit** — la lecture PTY se fait en `DispatchIO` ; `feed` s'exécute *synchronement* depuis la
  chaîne de lecture, sur la queue de session. La contre-pression est donc implicite et sans file
  non bornée : si le parsing prend du retard, la lecture ne se ré-arme pas, le buffer PTY du kernel
  se remplit, l'enfant bloque en `write()` — exactement comme un terminal ordinaire. Aucune
  croissance mémoire non bornée n'est possible (recherche §4.2). Cible ≥ 20 Mo/s (NFR-P).
- **Coût du réattachement** — un saut sur la queue de session + une copie O(rows × cols),
  **indépendante du scrollback**. La queue est par session : une session qui inonde ne peut
  retarder que son propre `attach`. Budget < 100 ms (TRM-03).
- **Coût quand personne ne regarde** — zéro copie d'écran, zéro frame. Seuls tournent le parsing,
  le tee transcript, et l'échantillonnage (2 Hz par défaut, qui lit ~24 lignes). Le scrollback est
  compacté à `ScrollbackPolicy.detached` dès le dernier détachement (NFR-M).
- **Latence d'entrée** — `send` fait un hop sur la queue puis un `DispatchIO.write`. Budget
  < 16 ms d'ajout par l'app (NFR-P).
- **Contrat imposé au `TranscriptSink`** — `append` est appelé **sur la queue de session** et doit
  retourner vite (copier et déléguer). Le runtime ne tamponne pas à sa place ; un sink qui bloque
  bloque le parsing de sa session (et d'elle seule).
- **Granularité de queue** — tous les terminaux d'une session partagent une queue. Un shell
  secondaire qui inonde retarde donc le parsing de l'agent. Voir §5.

---

## 2. Exemple d'usage

### 2.1 SessionManager crée une session

```swift
actor SessionManager {
    private var runtimes: [SessionID: SessionRuntime] = [:]

    func launch(_ spec: SessionSpec) async throws {
        let worktree = try await git.createWorktree(for: spec)
        let command  = agents.adapter(for: spec.agentID).launchCommand(for: spec)

        let plan = SessionPlan(
            sessionID: spec.id,
            command: LaunchCommand(executable: command.executable,
                                   arguments: command.arguments,
                                   workingDirectory: worktree.url,
                                   extraEnvironment: command.environment)
        )

        let (runtime, events) = try await SessionRuntime.start(plan)
        runtimes[spec.id] = runtime

        Task { [weak self] in
            for await event in events { await self?.route(event, for: spec.id) }
            await self?.finish(spec.id)          // le flux ne finit qu'après `.exited`
        }
    }

    private func route(_ event: SessionEvent, for id: SessionID) async {
        switch event {
        case .terminalOpened(let tid, let kind):
            await projections.addTerminal(tid, kind: kind, to: id)     // → @Observable, MainActor
        case .terminalClosed(let tid, _):
            await projections.removeTerminal(tid, from: id)
        case .screenSampled(let sample):
            await stateEngine.observe(sample, session: id)             // heuristiques, STA-02
        case .exited(let outcome):
            await stateEngine.processExited(outcome, session: id)      // → completed / failed, STA-05
            await store.recordOutcome(outcome, session: id)
        }
    }
}
```

### 2.2 SessionManager arrête une session

```swift
func stop(_ id: SessionID, confirmedByUser: Bool) async throws {
    guard let runtime = runtimes[id] else { return }
    if await projections.state(of: id) == .working && !confirmedByUser {
        throw SessionManagerError.confirmationRequired          // SES-06
    }
    let outcome = await runtime.stop(.graceful)                 // SIGINT → 5 s → SIGTERM → 5 s → SIGKILL
    await store.recordOutcome(outcome, session: id)
    runtimes[id] = nil
}
```

### 2.3 Reprise — aucun point d'entrée supplémentaire

```swift
func resume(_ record: SessionRecord) async throws {
    let command = agents.adapter(for: record.agentID).resumeCommand(for: record)   // claude --resume <native>
    try await launch(SessionSpec(resuming: record, command: command))
}
```

On ne restaure pas un PTY, on relance l'agent sur sa session native : la Reprise est un `start`
comme un autre. C'est le principal gain de levier du point d'entrée 1.

### 2.4 L'UI attache et détache une vue

```swift
@MainActor
final class TerminalViewModel {
    private var attachment: TerminalAttachment?     // relâcher = détacher
    private var pump: Task<Void, Never>?
    @Published private(set) var screen: TerminalScreen

    func attach(to runtime: SessionRuntime, target: TerminalTarget) async throws {
        let attachment = try await runtime.attach(target)
        self.screen = attachment.initialSnapshot     // peinture immédiate, < 100 ms
        self.attachment = attachment
        self.pump = Task { @MainActor [weak self] in
            for await frame in attachment.frames {   // production à la demande = coalescence naturelle
                self?.screen = frame.screen
            }
        }
    }

    func detach() {
        pump?.cancel(); pump = nil
        attachment = nil                             // le terminal continue de vivre (TRM-03)
    }

    func keyDown(_ text: String)                { attachment?.send(text) }
    func viewResized(_ g: TerminalGeometry)     { attachment?.resize(to: g) }
}
```

### 2.5 Message rapide sans ouvrir le terminal (SES-05)

```swift
let a = try await runtime.attach(.agent)
a.send("continue\r")
// `a` est relâché ici : aucune frame n'a jamais été matérialisée, car personne n'a lu `frames`.
```

### 2.6 Ouvrir un terminal secondaire (SES-04)

```swift
let shell = try await runtime.attach(.newShell())    // ouvre + attache en un geste
// Détacher plus tard laisse le shell vivant ; on y revient par .terminal(shell.terminalID),
// dont l'UI a appris l'existence via `.terminalOpened` sur le flux d'événements.
```

---

## 3. Ce que l'implémentation cache derrière le seam

Le test de suppression : si l'on retire `SessionRuntime`, chacun des points suivants ressurgit
dans `SessionManager`, dans l'UI, ou dans les deux.

**Concurrence et confinement**
- La `DispatchSerialQueue` par session, installée comme exécuteur de l'acteur : le confinement
  ADR-0007 devient une propriété de type, pas une discipline.
- Le piège de la queue par défaut de SwiftTerm (`dispatchQueue ?? .main`, recherche §3.6) : une
  session construite sans queue explicite ne recevrait jamais un octet dans un contexte sans run
  loop main. Le runtime passe toujours une queue.
- La ré-entrée depuis la chaîne `DispatchIO` : le callback de lecture est déjà sur la queue de
  session, donc l'ingestion s'y fait par `assumeIsolated` — pas de saut, pas de copie intermédiaire.
- La sérialisation naturelle du `feed` : le contrat de SwiftTerm est du *thread-confinement*, pas
  de la thread-safety (recherche §2.2). L'appelant n'a pas à le savoir.

**Cycle de vie du process**
- La course EOF-du-PTY / `NOTE_EXIT` : l'EOF ne conclut rien, seul l'exit fait foi (recherche §7.4).
- L'ordre « poser le handler avant `activate()` » du `DispatchSourceProcess`, sans quoi un enfant
  qui sort vite n'est jamais moissonné (recherche §3.5).
- L'ordre de fermeture du fd : `DispatchIO.cleanupHandler` ferme, jamais un `close()` direct
  (crash `EV_VANISHED`).
- L'escalade de signaux au **groupe de process** (`kill(-pgid, …)`), possible parce que `forkpty`
  fait `setsid` : SIGINT, 5 s, SIGTERM, 5 s, SIGKILL, avec annulation de l'escalade si l'exit arrive.
- Le drainage de la queue avant le snapshot final.
- Le fait que `terminate()` doit être appelé explicitement — un `deinit` n'envoie pas SIGTERM.

**Environnement et géométrie**
- La construction du `PATH` : `getEnvironmentVariables` de SwiftTerm l'omet volontairement
  (recherche §7.3), ce qui casse toute invocation non-login. Le runtime le fournit toujours.
- `TERM`, `COLORTERM`, `LANG`, et la fusion avec les variables additionnelles de la session.
- Le resize en **deux** opérations : `terminal.resize(cols:rows:)` *et*
  `PseudoTerminalHelpers.setWinSize(…)`. `HeadlessTerminal` ne fait pas la seconde (recherche §1.3).
  L'appelant voit un seul `resize(to:)`.

**Rendu et mémoire**
- La coalescence : une frame en vol au maximum par attachement, matérialisée seulement quand le
  consommateur est prêt. C'est le `pendingDisplay` de SwiftTerm, mais piloté par la demande plutôt
  que par un timer, donc naturellement adapté au 120 Hz comme au 60 Hz.
- L'absence totale de rendu sans attachement, et la compaction du scrollback au dernier détachement.
- Le réglage explicite de `scrollback` et de `kittyImageCacheLimitBytes` (défauts pensés pour une
  app mono-session : 500 lignes, 320 Mo — recherche §4.3).
- La distinction écran visible / buffer complet : `TerminalScreen` ne peut pas contenir de
  scrollback, donc l'appelant ne peut pas commettre l'erreur.
- La conversion cellules → `TerminalScreen` `Sendable`, faite sur la queue.

**Tee et échantillonnage**
- L'ordre du tee : octets bruts → transcript, puis → moteur, puis réémission vers le PTY des
  réponses du terminal (attributs d'appareil, DSR).
- La cadence d'échantillonnage, le retrait ANSI sur les lignes de queue, la mesure de silence,
  et `proc_pid_rusage` sur le groupe — l'appelant reçoit un `ScreenSample` prêt à consommer.

---

## 4. Stratégie de dépendances et adapters

Le `RuntimeEnvironment` est **un seam interne exposé délibérément**, uniquement pour la
substitution en test. Il porte une valeur par défaut, donc aucun appelant de production ne le nomme.

```swift
public struct RuntimeEnvironment: Sendable {
    public var pty: any PTYHost
    public var engine: any TerminalEngineFactory
    public var transcript: any TranscriptSink
    public var clock: any Clock<Duration>
    public static let live = RuntimeEnvironment(pty: ForkPTYHost(),
                                                engine: SwiftTermEngineFactory(),
                                                transcript: FileTranscriptSink.shared,
                                                clock: ContinuousClock())
}
```

### 4.1 PTY + process — *local-substitutable*, seam réel à deux adapters

```swift
public protocol PTYHost: Sendable {
    /// Livre les octets et l'exit **sur `queue`**. Le contrat d'ordre est explicitement
    /// « aucun » entre `onOutput`-EOF et `onExit` : les adapters ont le droit de les inverser.
    func spawn(_ command: LaunchCommand,
               geometry: TerminalGeometry,
               on queue: DispatchSerialQueue,
               onOutput: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
               onEOF: @escaping @Sendable () -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> any PTYChannel
}

public protocol PTYChannel: Sendable {
    var processGroup: pid_t { get }
    func write(_ bytes: [UInt8])
    func setWindowSize(_ geometry: TerminalGeometry)   // TIOCSWINSZ
    func signal(_ signal: Int32)                        // au groupe : kill(-pgid, …)
    func close()
    func cpuUsage() -> CPUSample                        // proc_pid_rusage
}
```

| Adapter | Rôle |
|---|---|
| `ForkPTYHost` | Production. `PseudoTerminalHelpers.fork` + `DispatchIO`, handler avant `activate()`, `cleanupHandler` pour le `close`, `PATH` injecté. |
| `ScriptedPTYHost` | Test. Alimenté par un script (`.sh` de fixture) **ou** par des octets en mémoire. Contrôle explicite du code de sortie, du délai avant exit, de la réaction aux signaux (« ignore SIGINT »), et — crucial — de **l'ordre EOF/exit**, seul moyen d'atteindre la course de la recherche §7.4 en test déterministe. |

C'est le seam qui justifie à lui seul l'exposition de `RuntimeEnvironment` : sans lui, aucun test
du module ne tourne en CI sans lancer de vrais process, et la course EOF/exit reste intestable.

### 4.2 Moteur terminal — *in-process tiers* derrière `TerminalEngine`

```swift
public protocol TerminalEngineFactory: Sendable {
    func makeEngine(geometry: TerminalGeometry, scrollback: Int) -> any TerminalEngine
}

/// Volontairement **non** `Sendable` : le type dit le confinement.
public protocol TerminalEngine: AnyObject {
    /// Rend les octets que le terminal veut renvoyer en amont (réponses DA/DSR).
    /// Cette forme évite un délégué, donc un cycle de références et un seam de plus.
    @discardableResult func feed(_ bytes: ArraySlice<UInt8>) -> [UInt8]
    func resize(cols: Int, rows: Int)
    func snapshot() -> TerminalScreen        // écran visible seulement
    func tailLines(_ n: Int) -> [String]     // pour l'échantillonnage, sans construire un écran
    var revision: UInt64 { get }             // permet de ne rien matérialiser si rien n'a bougé
    func compactScrollback(to lines: Int)
}
```

| Adapter | Rôle |
|---|---|
| `SwiftTermEngine` | Production. `HeadlessTerminal`-like, construit avec la queue de session, version SPM épinglée `.upToNextMinor(from: "1.18.0")` (refonte I/O annoncée en amont). |
| `GridEngine` | Test. Grille en clair, applique les octets littéralement plus une poignée de séquences (CR, LF, CUP, ED). Les tests du runtime assertent sur du contenu d'écran sans dépendre du parseur d'un tiers. |

La frontière est déjà exigée par TRM-01 et ADR-0001 (réversibilité vers libghostty). Ce design
n'en ajoute pas : il resserre la version de §6.2 (`snapshot()` au lieu d'une propriété, retour de
`feed` au lieu d'un délégué, `tailLines` pour éviter une copie d'écran par échantillon).

### 4.3 Disque (transcript) — *local-substitutable*

```swift
public protocol TranscriptSink: Sendable {
    /// Appelé sur la queue de session. Doit copier et rendre la main. Ne lève jamais.
    func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID)
    func finish(terminal: TerminalID)
}
```

| Adapter | Rôle |
|---|---|
| `FileTranscriptSink` | Production. Batch 250 ms, rotation à 10 Mo, flux brut + flux nettoyé pour la FTS, écritures atomiques, propre queue d'écriture (DAT-01, NFR-R). |
| `InMemoryTranscriptSink` | Test. Assertions sur les octets exacts vus, y compris l'invariant « le transcript reçoit avant le parsing ». |

### 4.4 Horloge — *in-process*

`any Clock<Duration>` de la bibliothèque standard. Pas de protocole maison : les tests utilisent une
horloge de test pour vérifier l'escalade SES-06 (5 s) et la cadence d'échantillonnage sans dormir.
Une dépendance in-process ne mérite pas un adapter maison.

### 4.5 Ce qui n'est **pas** une dépendance du module

`StateEngine`, `TranscriptWriter` (le service), `GitService`, la persistance, l'UI. Le runtime ne
les connaît pas : il pousse des octets dans un `TranscriptSink` et des valeurs dans un
`AsyncStream`. Le sens de la dépendance ne s'inverse jamais.

---

## 5. Trade-offs

### Là où le levier est fort

- **La Reprise est gratuite.** Elle ne demande aucun point d'entrée : c'est un `start` avec une
  autre `LaunchCommand`. Un design qui aurait exposé `restart()` ou `resume()` aurait dû répondre à
  « que devient le moteur ? que devient le transcript ? » — ici la question ne se pose pas, parce
  qu'un runtime ne survit pas à son process.
- **`attach` porte six besoins pour un concept.** Snapshot instantané, flux de frames, entrée
  clavier, resize, ouverture de shell secondaire, message rapide sans vue. Et la durée de vie de
  l'objet *est* la durée de l'attachement, donc « détacher » n'est pas une opération qu'on peut
  oublier d'appeler : c'est ARC. La règle TRM-03 « pas de vue ⇒ pas de rendu, mais parsing et
  transcript continuent » devient structurelle plutôt que conventionnelle.
- **`RuntimeEnvironment` unique.** Un test substitue quatre dépendances en une ligne. C'est le
  levier de test le plus dense du design : la totalité du module est exerçable sans un seul vrai
  process, y compris la course EOF/exit et l'escalade de signaux.
- **Suppression du module ⇒ ressurgissement massif.** Queue sérielle, piège de la main queue,
  double resize, `PATH`, ordre handler/activate, `cleanupHandler`, course EOF/exit, drainage avant
  snapshot final, coalescence : neuf pièges dont chacun est un bug de production, tous localisés en
  un point.
- **Le flux d'événements rendu par `start`** rend la propriété « mono-consommateur » structurelle.
  Un `var events` en propriété aurait invité deux consommateurs et un bug de perte d'événements.
- **Stabilité sous refonte.** Passer à une queue par terminal, ou remplacer SwiftTerm par
  libghostty, ne change aucune des trois signatures.

### Là où le levier est mince, et ce que ça coûte

- **« 3 points d'entrée » est un compte honnête du *module*, pas de la surface totale.**
  `TerminalAttachment` est une seconde interface, avec cinq membres. La surface réelle à apprendre
  est « 3 + 5 ». Le déplacement se défend — il lie une durée de vie à un objet, ce qui est du
  comportement et pas de la cosmétique — mais il ne faut pas prétendre avoir supprimé cinq méthodes.
- **`attach(.newShell)` mélange création et attachement.** C'est le compromis le plus discutable du
  design : il économise un quatrième point d'entrée en tordant légèrement le sens du mot « attach ».
  Un lecteur qui découvre l'interface peut ne pas deviner qu'un shell naît là. Un
  `openShell() -> TerminalAttachment` séparé serait plus lisible pour un point d'entrée de plus.
- **Asymétrie push / pull assumée.** Le transcript est poussé dans un sink injecté (chemin chaud,
  20 Mo/s, pas de saut d'acteur), les événements sont tirés d'un `AsyncStream` (bas débit). C'est
  justifié par la perf, mais l'appelant doit apprendre deux mécanismes de sortie au lieu d'un.
- **Un seam interne exposé.** `RuntimeEnvironment` viole la règle « ne pas exposer un seam interne
  parce que les tests l'utilisent ». Je l'assume : le seam PTY est un vrai seam à deux adapters, et
  il n'existe aucun autre moyen de tester le module. Le coût réel : `PTYHost`, `TerminalEngine` et
  `TranscriptSink` deviennent du vocabulaire public, donc du contrat à ne pas casser.
- **Une queue par session, pas par terminal.** Un shell secondaire qui inonde retarde le parsing de
  l'agent de la même session. Le cas est plausible (`yes`, un build verbeux dans « Term 2 »).
  Correctif possible sans changer l'interface, à mesurer au jalon M1.
- **Le module est gros.** PTY, moteur, tee, échantillonnage, snapshot, signaux. Il porte le risque
  de devenir le god-module de Loom. Le garde-fou est la liste de §4.5 : tout ce qui *interprète*
  (états, heuristiques, hooks, git) est dehors, définitivement. Le runtime observe et transporte,
  il ne décide de rien — sauf de quand un process meurt.
- **`stop` rend `SessionOutcome` et non l'état de session.** Le mapping exit 0 → `completed`,
  exit ≠ 0 → `failed` appartient au `StateEngine` (STA-05). C'est correct en couches, mais ça
  oblige tout appelant à faire ce petit pas — une friction acceptée pour ne pas faire entrer le
  vocabulaire d'état dans un module qui ne le possède pas.
