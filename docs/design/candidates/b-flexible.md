# Candidat B — `SessionRuntime` : seams composables et flux multi-observateurs

> **Contrainte de design de ce candidat : maximiser la flexibilité et l'extension.**
> Le pari : le chemin chaud d'une session (PTY → parsing → transcript → état → écran)
> est stable, mais *qui* l'écoute et *qui* le produit ne le sont pas. On fige donc le
> flux et on ouvre trois seams — la source (`PTYHost`), le moteur (`TerminalEngine`),
> et les consommateurs (`StreamObserver`) — pour que le backend tmux (v2), la migration
> libghostty, les terminaux secondaires et de futurs observateurs (recherche live,
> réplication iOS §12) entrent sans refonte.

`SessionRuntime` est le module qui possède tout ce qui est **vivant** dans une session :
le process de l'agent sur son PTY, le moteur terminal, le tee vers le Transcript,
l'échantillonnage vers la machine à états, et le snapshot d'écran pour le réattachement.
Ses appelants sont `SessionManager` (création / arrêt / reprise) et la couche UI
(attacher / détacher une vue) ; `TranscriptWriter` et `StateEngine` ne l'appellent pas —
ils sont branchés dessus comme observateurs.

---

## 1. Interface

### 1.0 Forme générale

Un `SessionRuntime` par Session. Il contient N runtimes de terminal (`TerminalKind.agent`
pour le **terminal principal**, `.shell` pour les **terminaux secondaires**, SES-04),
tous confinés sur **une seule `DispatchQueue` sérielle de session** (ADR-0007). La queue
est une propriété de la session, pas du terminal : deux terminaux d'une même session ne
se parallélisent pas, mais deux sessions sont isolées l'une de l'autre — c'est exactement
la granularité que l'ADR demande, et elle borne le nombre de threads à ~1 par session.

```
                       ┌─────────── queue sérielle de session (ADR-0007) ───────────┐
                       │                                                            │
 PTYHost ─ PTYEvent ──▶│  ring buffer ──▶ fan-out                                    │
 (forkpty | tmux |     │                    ├──▶ observateurs .rawBytes              │
  scripted)            │                    │      (TranscriptTap, réplication…)     │
                       │                    ├──▶ TerminalEngine.feed()               │
                       │                    │      (SwiftTerm | libghostty | fake)   │
                       │                    └──▶ observateurs .parsedScreen          │
                       │                           (StateSampleTap, RenderTap,       │
                       │                            recherche live…)                 │
                       └────────────────────────────────────────────────────────────┘
                                                     │ RenderTap seulement si attaché
                                                     ▼
                                        RenderPacer ──▶ MainActor ──▶ vue
```

### 1.1 Identité et description

```swift
public struct SessionID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TerminalID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Terminal principal (héberge l'agent) vs terminal secondaire (shell libre) — SES-04.
public enum TerminalKind: String, Sendable, Codable {
    case agent
    case shell
}

public struct TerminalSize: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int)
}

public struct TerminalSpec: Sendable, Equatable {
    public var kind: TerminalKind
    public var executable: String            // chemin absolu résolu par l'appelant
    public var arguments: [String]
    public var workingDirectory: URL         // worktree de la session
    public var environment: ChildEnvironment // PATH garanti — voir §1.2
    public var initialSize: TerminalSize
    public var scrollback: Int               // explicite : le défaut SwiftTerm (500) est mono-session
    public var label: String?                // « Term 2 »
}

/// Ce que l'appelant connaît d'un terminal ouvert. Valeur, jamais une poignée vivante.
public struct TerminalDescriptor: Sendable, Equatable {
    public let id: TerminalID
    public let kind: TerminalKind
    public let label: String?
    public let size: TerminalSize
    public let openedAt: ContinuousClock.Instant
    public let isPrimary: Bool               // premier terminal .agent de la session
}
```

### 1.2 Environnement enfant — la lacune `PATH` fermée par construction

```swift
/// Construction pure de l'environnement du process enfant.
/// INVARIANT : `PATH` est toujours présent. SwiftTerm l'omet
/// (`getEnvironmentVariables` le commente explicitement — recherche §7.3), ce qui
/// casse toute invocation non-login. Ce type interdit d'oublier.
public struct ChildEnvironment: Sendable, Equatable {
    public static func standard(
        termName: String = "xterm-256color",
        trueColor: Bool = true,
        loginPATH: String,                       // résolu depuis le shell de login (cf. GIT-06)
        inheriting host: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]            // variables additionnelles de la session (SES-02)
    ) -> ChildEnvironment

    /// Représentation `["K=V", …]` attendue par les adapters PTY.
    public var strings: [String] { get }
    public subscript(key: String) -> String? { get set }
}
```

### 1.3 Seam 1 — `PTYHost` : d'où viennent les octets

Deux adapters de production justifient ce seam (forkpty en v1, tmux en v2, ADR-0006), plus
un adapter de test. Le contrat est délibérément **sans descripteur de fichier** : un
backend tmux n'en a pas à offrir. `resize` et `signal` sont des opérations du canal, pas
des ioctl de l'appelant.

```swift
public protocol PTYHost: Sendable {
    /// Ouvre un canal. `sink` N'EST appelé QUE sur `queue`, et jamais après `close()`.
    func open(
        _ spec: TerminalSpec,
        deliveringOn queue: DispatchQueue,       // la queue sérielle de session
        sink: @escaping @Sendable (PTYEvent) -> Void
    ) throws -> any PTYChannel
}

public enum PTYEvent: Sendable {
    case bytes(ArraySlice<UInt8>)   // slice valide uniquement pendant l'appel — copier pour conserver
    case endOfFile                  // informatif : NE termine JAMAIS une session (recherche §7.4)
    case terminated(ExitStatus)     // seule vérité sur la fin et le code de sortie
}

public protocol PTYChannel: AnyObject, Sendable {
    func write(_ bytes: ArraySlice<UInt8>)
    func resize(to size: TerminalSize)          // TIOCSWINSZ ici (forkpty) / refresh-client (tmux)
    func signal(_ signal: PTYSignal)            // au process group dédié (TRM-02)
    func close()                                // idempotent ; ne délivre plus rien après retour
    var capabilities: PTYCapabilities { get }
    var processGroup: pid_t? { get }            // nil pour tmux ; alimente l'heuristique CPU (STA-02)
}

public enum PTYSignal: Sendable { case interrupt, terminate, kill }

public struct PTYCapabilities: OptionSet, Sendable {
    public static let signals        = PTYCapabilities(rawValue: 1 << 0) // process group joignable
    public static let survivesHost   = PTYCapabilities(rawValue: 1 << 1) // vraie persistance (tmux, v2)
    public static let cpuSampling    = PTYCapabilities(rawValue: 1 << 2) // proc_pid_rusage possible
}

public struct ExitStatus: Sendable, Equatable {
    public let code: Int32?      // nil si tué par signal
    public let signal: Int32?
    public var isSuccess: Bool { code == 0 }    // → completed / failed (STA-05)
}
```

### 1.4 Seam 2 — `TerminalEngine` : ce qui parse

Contrat d'ADR-0001 / §6.2, étendu du strict nécessaire (fabrique + régions sales). Deux
adapters : SwiftTerm en v1, un moteur factice en test ; libghostty s'ajoute en troisième.

```swift
public protocol TerminalEngine: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    var screenSnapshot: TerminalScreen { get }
    var delegate: TerminalEngineDelegate? { get set }

    /// Régions modifiées depuis le dernier appel, et remise à zéro du marqueur.
    func takeDirtyRegions() -> DirtyRegions
    /// Réduit l'empreinte d'un terminal non visible (NFR-M) sans perdre le transcript.
    func compactScrollback(to lines: Int)
}

public protocol TerminalEngineFactory: Sendable {
    /// La queue est passée telle quelle à `HeadlessTerminal(queue:)` côté SwiftTerm.
    func makeEngine(size: TerminalSize, scrollback: Int, confinedTo queue: DispatchQueue) -> any TerminalEngine
}

/// Écran visible uniquement — pas le scrollback (recherche §1.4). Value type Sendable :
/// il traverse la frontière queue → MainActor sans partage de référence.
public struct TerminalScreen: Sendable, Equatable {
    public let size: TerminalSize
    public let cells: [TerminalCell]
    public let cursor: CursorPosition
    public let title: String?
    public let takenAt: ContinuousClock.Instant
}

public struct DirtyRegions: Sendable, Equatable {
    public let rows: IndexSet
    public let cursorMoved: Bool
    public var isEmpty: Bool { rows.isEmpty && !cursorMoved }
}
```

### 1.5 Seam 3 — `StreamObserver` : qui écoute (le cœur de l'extensibilité)

C'est le point d'extension du candidat. Transcript, échantillonnage d'état et rendu ne
sont pas des cas particuliers câblés dans le runtime : ce sont **trois observateurs
parmi N**. Ajouter la recherche live ou la réplication iOS (§12) est alors une fabrique
d'observateur, sans une ligne modifiée dans `SessionRuntime`.

```swift
public struct ObserverInterest: OptionSet, Sendable {
    public static let rawBytes     = ObserverInterest(rawValue: 1 << 0) // avant parsing
    public static let parsedScreen = ObserverInterest(rawValue: 1 << 1) // après feed
    public static let lifecycle    = ObserverInterest(rawValue: 1 << 2) // start / resize / exit
}

public enum StreamEvent: Sendable {
    case started(TerminalDescriptor)
    case bytes(ArraySlice<UInt8>)                 // .rawBytes — slice valide pendant l'appel
    case parsed(DirtyRegions)                     // .parsedScreen — le moteur a déjà digéré
    case resized(TerminalSize)
    case terminated(ExitStatus)
}

/// Accès au moteur pendant l'appel, sur la queue de session. Ne JAMAIS le capturer.
public struct ObserverContext {
    public let sessionID: SessionID
    public let terminal: TerminalDescriptor
    public let engine: any TerminalEngine
    public let clock: any RuntimeClock
}

public protocol StreamObserver: AnyObject {
    var interest: ObserverInterest { get }
    /// Appelé sur la queue sérielle de session, jamais en concurrence avec lui-même.
    /// CONTRAT DE COÛT : < 50 µs par appel en régime nominal. Toute I/O est différée
    /// (accumuler ici, écrire ailleurs) — un observateur lent plafonne le débit de SA session.
    func observe(_ event: StreamEvent, context: ObserverContext) throws
    /// Barrière : arrêt, détachement, rotation périodique. Doit rendre l'état durable.
    func flush() throws
}

public protocol StreamObserverFactory: Sendable {
    /// `nil` = pas intéressé par ce terminal (ex. StateSampleTap ignore les `.shell`).
    func makeObserver(for terminal: TerminalDescriptor, session: SessionID) -> (any StreamObserver)?
}

public struct ObserverToken: Hashable, Sendable {}
```

Observateurs fournis par le module (aucun n'est privilégié dans le code du runtime) :

| Observateur | Intérêt | Rôle |
|---|---|---|
| `TranscriptTap` | `.rawBytes`, `.lifecycle` | tee vers `TranscriptWriter`, batché 250 ms (DAT-01) |
| `StateSampleTap` | `.parsedScreen`, `.lifecycle` | échantillonne vers `StateEngine` (silence, motifs de prompt, exit) |
| `RenderTap` | `.parsedScreen` | installé par `attach`, retiré par `detach` |

### 1.6 Temps et cadence — deux seams pour rendre les tests déterministes

```swift
public protocol RuntimeClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

/// Coalescence du rendu (TRM-04). Adapter prod : CVDisplayLink. Adapter test : tick manuel.
public protocol RenderPacer: Sendable {
    func startTicking(_ body: @escaping @Sendable () -> Void) -> any RuntimeCancellable
}

public protocol RuntimeCancellable: Sendable { func cancel() }
```

### 1.7 Arrêt gracieux — l'escalade est une valeur, pas du code

```swift
public struct ShutdownLadder: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let signal: PTYSignal
        public let grace: Duration
    }
    public var steps: [Step]

    /// SES-06 : SIGINT, puis SIGTERM après 5 s, puis SIGKILL.
    public static let graceful = ShutdownLadder(steps: [
        .init(signal: .interrupt, grace: .seconds(5)),
        .init(signal: .terminate, grace: .seconds(5)),
        .init(signal: .kill,      grace: .seconds(1)),
    ])
    public static let immediate = ShutdownLadder(steps: [.init(signal: .kill, grace: .seconds(1))])
}
```

### 1.8 Composition — `RuntimeEnvironment`

Un seul point d'assemblage. Changer de backend PTY, de moteur, d'horloge ou d'ensemble
d'observateurs se fait ici, jamais dans `SessionRuntime`.

```swift
public struct RuntimeEnvironment: Sendable {
    public var ptyHost: any PTYHost
    public var engineFactory: any TerminalEngineFactory
    public var observerFactories: [any StreamObserverFactory]
    public var pacer: any RenderPacer
    public var clock: any RuntimeClock
    /// Fabrique la queue sérielle de session (ADR-0007). Injectable pour les tests d'endurance.
    public var makeSessionQueue: @Sendable (SessionID) -> DispatchQueue

    public static func live(transcripts: TranscriptWriter, state: StateEngine, loginPATH: String) -> RuntimeEnvironment
    public static func test(script: PTYScript = .empty) -> RuntimeEnvironment
}
```

### 1.9 Le module

```swift
public actor SessionRuntime {
    public init(sessionID: SessionID, environment: RuntimeEnvironment)
    public nonisolated var id: SessionID { get }

    // ── Cycle de vie des terminaux ───────────────────────────────────────────
    @discardableResult
    public func openTerminal(_ spec: TerminalSpec) throws -> TerminalDescriptor
    public func terminals() -> [TerminalDescriptor]
    @discardableResult
    public func close(_ terminalID: TerminalID, using ladder: ShutdownLadder) async throws -> ExitStatus
    /// Ferme tous les terminaux (secondaires d'abord, principal ensuite), draine, flush.
    public func shutdown(using ladder: ShutdownLadder) async -> [TerminalID: ExitStatus]

    // ── Chemin chaud ─────────────────────────────────────────────────────────
    public func write(_ bytes: ArraySlice<UInt8>, to terminalID: TerminalID) throws
    public func resize(_ terminalID: TerminalID, to size: TerminalSize) throws
    public func snapshot(of terminalID: TerminalID) throws -> TerminalScreen

    // ── Extension à chaud ────────────────────────────────────────────────────
    public func addObserver(_ factory: any StreamObserverFactory) -> ObserverToken
    public func removeObserver(_ token: ObserverToken)

    // ── Vue ──────────────────────────────────────────────────────────────────
    public func attach(_ terminalID: TerminalID,
                       to sink: any TerminalViewSink,
                       pacing: RenderPacing = .display) async throws -> Attachment

    // ── Événements ───────────────────────────────────────────────────────────
    /// Multicast : chaque appel rend un flux indépendant, `.bufferingNewest(256)`.
    public nonisolated func events() -> AsyncStream<RuntimeEvent>
}

public enum RenderPacing: Sendable {
    case display                    // CVDisplayLink, 60–120 Hz (TRM-04)
    case paced(any RenderPacer)     // cadence imposée (tests, aperçu de carte basse fréquence)
    case snapshotOnly               // un seul `present`, aucun delta (vignette, aperçu SES-03)
}

@MainActor
public protocol TerminalViewSink: AnyObject {
    func present(_ screen: TerminalScreen)          // écran complet (attache / resize)
    func apply(_ delta: ScreenDelta)                // incrément coalescé
}

public struct Attachment: Sendable {
    public let terminalID: TerminalID
    /// Idempotent. Au retour, plus aucune frame ne sera délivrée au sink.
    public func detach() async
}

public enum RuntimeEvent: Sendable {
    case terminalOpened(TerminalDescriptor)
    case terminalTerminated(TerminalID, ExitStatus)
    /// Le terminal principal s'est terminé, après drainage et flush : la Session se termine
    /// en `completed` (exit 0) ou `failed` (exit ≠ 0) — STA-05.
    case sessionEnded(ExitStatus)
    /// Un observateur a été mis en quarantaine après échecs répétés ; le flux continue.
    case observerQuarantined(TerminalID, reason: RuntimeError)
    case diagnostic(RuntimeDiagnostic)   // débits, drops, latences — alimente STA-06
}

public enum RuntimeError: Error, Sendable, Equatable {
    case unknownTerminal(TerminalID)
    case terminalAlreadyTerminated(TerminalID)
    case runtimeShuttingDown
    case ptyOpenFailed(spec: TerminalSpec, underlying: String)
    case executableNotFound(path: String, pathSearched: String)
    case terminalLimitReached(limit: Int)
    case observerFailed(label: String, underlying: String)
    case backpressureOverflow(TerminalID, droppedBytes: Int)
}
```

### 1.10 Invariants

1. **Confinement (ADR-0007).** Toute interaction avec un `TerminalEngine` — `feed`,
   `resize`, snapshot, lecture de buffer — s'exécute sur la queue sérielle de la session.
   Aucune méthode publique ne rend une référence de moteur qui survive à l'appel :
   `ObserverContext.engine` n'est valide que pendant `observe`. Un `dispatchPrecondition`
   en debug garde l'invariant côté adapter.
2. **Jamais de travail par-chunk sur le main thread** (§6.3). Le MainActor ne reçoit que
   des `TerminalScreen` / `ScreenDelta`, valeurs immuables, à la cadence du pacer.
3. **Ordre par terminal.** `started` ≺ (`bytes` | `parsed` | `resized`)\* ≺ `terminated`.
   Les observateurs `.rawBytes` voient les octets dans l'ordre exact du PTY ; un
   `.parsed(dirty)` suit toujours le `feed` des octets qui l'ont produit.
4. **La fin de session vient de l'exit, pas de l'EOF** (recherche §7.4). `endOfFile` est
   journalisé et ignoré comme signal de terminaison. Sur `terminated`, le runtime pose une
   **barrière** sur la queue : les octets en vol sont fed, `takeDirtyRegions` est vidé, le
   snapshot final est pris, `flush()` est appelé sur tous les observateurs — *ensuite*
   seulement `terminalTerminated` / `sessionEnded` sont émis. Un appelant qui reçoit
   `sessionEnded` sait que le transcript est complet sur disque.
5. **Resize atomique.** `resize` applique `engine.resize` puis `channel.resize` sur la
   queue, sans qu'aucun octet ne s'intercale entre les deux ; l'événement `.resized` suit.
   L'appelant n'a jamais à connaître `TIOCSWINSZ`.
6. **Réattachement synchrone.** Quand `attach` retourne, `sink.present(snapshot)` a déjà
   été exécuté sur le MainActor. Quand `Attachment.detach()` retourne, aucune frame ne
   sera plus délivrée.
7. **Observateur tardif jamais désynchronisé.** Un observateur ajouté par `addObserver`
   reçoit d'abord un `.started` synthétique puis, s'il déclare `.parsedScreen`, un
   `.parsed` couvrant tout l'écran. Il ne rejoint jamais le flux au milieu d'un slice.
8. **Isolation des pannes d'observateur.** Un `observe` qui `throw` n'interrompt ni le
   parsing ni les autres observateurs ; après 3 échecs consécutifs l'observateur est mis
   en quarantaine et `observerQuarantined` est émis. Le transcript n'est jamais la cause
   d'un gel du terminal.
9. **La Session se termine avec son terminal principal.** L'exit d'un terminal secondaire
   émet `terminalTerminated` sans toucher à l'état de la Session (SES-04).
10. **Aucun rendu pour un terminal non attaché** (TRM-03). Zéro `RenderTap`, zéro tick de
    pacer, zéro calcul de delta — mais parsing et transcript continuent.

### 1.11 Contraintes d'ordre d'appel

- `openTerminal` précède tout `write` / `resize` / `attach` / `snapshot` sur ce terminal.
- `shutdown` est terminal : tout `openTerminal` ultérieur lève `runtimeShuttingDown`.
- `close` est idempotent ; le second appel rend le même `ExitStatus`.
- `write` / `resize` sur un terminal terminé lèvent `terminalAlreadyTerminated` — ce n'est
  pas silencieux, parce qu'une frappe perdue est un bug visible par l'utilisateur.
- `addObserver` / `removeObserver` sont sûrs à tout moment, y compris pendant le streaming.
- Une **Reprise** (SES-02) n'est pas une méthode : c'est un nouveau `SessionRuntime` sur
  la même `SessionID`, ouvert avec la commande `claude --resume` fournie par
  l'`AgentAdapter`. Le runtime ne connaît pas la notion de session native.

### 1.12 Modes d'erreur

| Situation | Comportement |
|---|---|
| `forkpty` échoue | `openTerminal` lève `ptyOpenFailed` ; rien n'est enregistré, pas de fuite de fd |
| Binaire absent du `PATH` | `executableNotFound` avec le `PATH` effectivement transmis (diagnostic UIX-06) |
| Agent ignore SIGINT | escalade automatique de la `ShutdownLadder` ; `ExitStatus.signal = SIGKILL` |
| EOF sans exit | attente de `terminated` ; après un délai de garde, `diagnostic` puis `ExitStatus(code: nil)` |
| Observateur en panne | quarantaine après 3 échecs ; flux préservé (invariant 8) |
| Producteur plus rapide que les observateurs | anneau borné (4 Mo) ; en dépassement, `backpressureOverflow` avec le compte exact d'octets perdus — jamais de perte silencieuse, jamais d'OOM |
| Crash de l'UI | les observateurs vivent sur la queue de session, hors couche vue : le transcript continue (NFR-R) |

### 1.13 Caractéristiques de performance

- **Débit ≥ 20 Mo/s (NFR-P)** : chemin sans copie de la lecture au `feed`
  (`ArraySlice<UInt8>` sur l'anneau du runtime). Un observateur qui veut conserver des
  octets copie explicitement. Le coût par slice est : un `OptionSet` testé par observateur,
  un `feed`, un `takeDirtyRegions`.
- **Réattachement < 100 ms (TRM-03)** : `snapshot` coûte O(cellules visibles), pas
  O(scrollback) ; c'est un `struct` copié une fois vers le MainActor.
- **Latence frappe → écho < 16 ms** : `write` traverse la queue sans passer par le moteur.
- **Session non visible** : coût nul côté rendu ; scrollback compacté via
  `compactScrollback` (NFR-M) sans effet sur le transcript disque.
- **Isolation** : une session saturée n'occupe que sa queue. Le budget est ~1 thread par
  session, borné par SES-09 (défaut 12).

---

## 2. Exemple d'usage

### 2.1 `SessionManager` crée une session

```swift
let env = RuntimeEnvironment.live(
    transcripts: transcriptWriter,
    state: stateEngine,
    loginPATH: await shellEnvironment.loginPATH()
)

let runtime = SessionRuntime(sessionID: session.id, environment: env)
runtimes[session.id] = runtime

let command = agentAdapter.launchCommand(for: spec)          // ClaudeCodeAdapter
let agentTerminal = try await runtime.openTerminal(
    TerminalSpec(
        kind: .agent,
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: worktree.url,
        environment: .standard(loginPATH: env.loginPATH, extra: command.environment),
        initialSize: TerminalSize(cols: 120, rows: 32),
        scrollback: 10_000,                                   // TRM-05, jamais le défaut
        label: nil
    )
)

Task { [weak self] in
    for await event in runtime.events() {
        switch event {
        case .sessionEnded(let status):
            // Le transcript est déjà flushé : invariant 4.
            await self?.record(session.id, state: status.isSuccess ? .completed : .failed,
                               source: .process, exitCode: status.code)
        case .terminalTerminated(let id, _):
            await self?.forgetTerminal(id)
        case .observerQuarantined(_, let reason):
            await self?.log.warning("observateur en quarantaine : \(reason)")
        case .terminalOpened, .diagnostic:
            break
        }
    }
}
```

### 2.2 Terminal secondaire (SES-04) — même appel, autre `kind`

```swift
let shell = try await runtime.openTerminal(
    TerminalSpec(kind: .shell, executable: "/bin/zsh", arguments: ["-l"],
                 workingDirectory: worktree.url,
                 environment: .standard(loginPATH: env.loginPATH),
                 initialSize: size, scrollback: 10_000, label: "Term 2")
)
```

`TranscriptTap` s'y branche automatiquement (un transcript par terminal, DAT-01/§6.5) ;
`StateSampleTap` l'ignore — sa fabrique rend `nil` pour un `.shell`.

### 2.3 Arrêt (SES-06)

```swift
// L'UI a déjà confirmé si l'état est `working`.
let statuses = await runtime.shutdown(using: .graceful)
```

### 2.4 L'UI attache et détache une vue

```swift
@MainActor
final class TerminalViewController: NSViewController, TerminalViewSink {
    private var attachment: Attachment?

    func viewWillAppear() {
        Task {
            // Au retour, present(_:) a déjà peint l'écran : réattachement < 100 ms.
            attachment = try? await runtime.attach(terminalID, to: self, pacing: .display)
        }
    }

    func viewDidDisappear() {
        Task { await attachment?.detach(); attachment = nil }
        // La session continue : parsing et transcript ne s'arrêtent pas (TRM-03).
    }

    func present(_ screen: TerminalScreen) { renderer.replace(with: screen) }
    func apply(_ delta: ScreenDelta)       { renderer.apply(delta) }

    override func viewDidLayout() {
        Task { try? await runtime.resize(terminalID, to: TerminalSize(cols: cols, rows: rows)) }
    }
}
```

Aperçu de carte (SES-03), sans coût de rendu :

```swift
let preview = try await runtime.snapshot(of: agentTerminal.id).lastNonEmptyLines(3)
```

### 2.5 Extension future — sans toucher au module

```swift
// Recherche live (SES-08) : un observateur de plus, aucune modification de SessionRuntime.
await runtime.addObserver(LiveSearchIndexFactory(index: ftsIndex))

// Réplication iOS (§12) : idem, en .rawBytes.
let token = await runtime.addObserver(CompanionMirrorFactory(peer: peer))
await runtime.removeObserver(token)

// Backend tmux (v2) : une ligne dans la composition.
var v2 = RuntimeEnvironment.live(...)
v2.ptyHost = TmuxPTYHost(server: tmuxServer)

// libghostty : une autre.
v2.engineFactory = GhosttyEngineFactory()
```

---

## 3. Ce que l'implémentation cache

Derrière ces ~12 méthodes, l'appelant n'a à connaître **aucun** des points suivants —
c'est la mesure de la profondeur du module.

**Du côté process et PTY.** `forkpty`, `setsid` et la création du process group dédié
(TRM-02) ; la construction de l'`argv`/`envp` ; le `TIOCSWINSZ` du resize ; le
`waitpid` / `DispatchSourceProcess` qui porte `NOTE_EXIT` ; les timers d'escalade
SIGINT → SIGTERM → SIGKILL et l'annulation propre si le process meurt entre deux
échelons ; la fermeture des descripteurs sans fuite sur créer/détruire 100 sessions
(NFR-M).

**La course EOF / exit.** Que `dataReceived` s'arrête ne veut rien dire ; que `running`
passe à `false` non plus ; le dernier lot d'octets peut être en cours de `feed` quand
`processTerminated` arrive. Le drainage par barrière avant snapshot final et flush est
entièrement interne (recherche §7.4).

**La lacune `PATH` de SwiftTerm.** `getEnvironmentVariables` omet `PATH` — piège
opérationnel qui casserait toute invocation non-login. Aucun appelant ne peut l'oublier
puisqu'il ne construit jamais l'environnement à la main.

**Le confinement (ADR-0007).** La queue sérielle, le fait que la doc SwiftTerm ment sur
la thread-safety, le marshalage de tout snapshot sur la queue, la vigilance sur le mode
DEC 2026 (seul endroit où le moteur touche la main queue de lui-même). L'UI voit des
valeurs, jamais un `Terminal`.

**La boucle de lecture et l'anneau.** `DispatchIO`, la taille des lots, le ré-armement,
la backpressure bornée, la comptabilité des octets perdus.

**Le rendu.** La coalescence des chunks, le `CVDisplayLink`, le diff de régions sales,
le choix entre `present` complet et `apply(delta)`, la suppression totale du travail de
rendu quand rien n'est attaché, le compactage du scrollback des sessions non visibles.

**Le fan-out.** L'ordre des observateurs, le filtrage par `ObserverInterest`, la
quarantaine, les `flush` aux barrières, l'injection d'état initial pour un observateur
tardif.

**Le test de suppression.** Si l'on supprimait `SessionRuntime`, chacun de ces points
réapparaîtrait chez `SessionManager`, dans la couche UI, dans `TranscriptWriter` et dans
`StateEngine` — quatre appelants qui devraient tous connaître la course EOF/exit, la
paire de resize et la discipline de queue. La complexité ne disparaît pas : elle se
disperse. C'est la définition d'un module qui gagne sa place.

---

## 4. Stratégie de dépendances et adapters

| Dépendance | Catégorie | Seam | Adapters |
|---|---|---|---|
| PTY / process | **local-substitutable** | `PTYHost` / `PTYChannel` (externe) | `ForkPTYHost` (v1), `TmuxPTYHost` (v2), `ScriptedPTYHost` (test) |
| SwiftTerm | **in-process tiers** | `TerminalEngine` + `TerminalEngineFactory` (externe) | `SwiftTermEngine`, `RecordingEngine` (test), `GhosttyEngine` (v2) |
| Disque (transcript) | **local-substitutable** | `TranscriptSink` (**interne** à `TranscriptTap`) | fichier + rotation 10 Mo, en-mémoire (test) |
| Temps | in-process | `RuntimeClock` (externe) | `ContinuousClock`, `ManualClock` (test) |
| Cadence d'affichage | local-substitutable | `RenderPacer` (externe) | `DisplayLinkPacer`, `ManualPacer` (test) |
| Réducteur d'état, diff, `ChildEnvironment`, `ShutdownLadder` | **in-process** | aucun | testés directement |

**PTY / process — le seam le plus rentable.** Deux adapters de production sont déjà
justifiés par la trajectoire (`ForkPTYHost` v1, `TmuxPTYHost` v2, ADR-0006/§12) : ce n'est
pas un seam hypothétique. L'adapter de test, `ScriptedPTYHost`, est alimenté par un
`PTYScript` — octets en mémoire, pauses, séquence d'exit — ce qui rend testables sans
process réel : la course EOF/exit (script émettant l'EOF avant, puis après l'exit),
l'escalade de la ladder (script qui ignore SIGINT, sous `ManualClock`), et l'endurance à
20 Mo/s (script qui déverse un fichier de bytes). La discipline du contrat vient de ce que
`PTYChannel` n'expose **jamais** de fd : tmux n'en a pas, et un `capabilities` déclaratif
plutôt qu'implicite évite qu'un appelant présume un process group.

**SwiftTerm — in-process tiers derrière un seam existant.** ADR-0001 fixe déjà la
frontière ; ce candidat n'ajoute que la fabrique (pour recevoir la queue de session, ce
que `HeadlessTerminal(queue:)` exige) et `takeDirtyRegions` / `compactScrollback`, qui
sont les deux besoins que le rendu et NFR-M imposent au moteur. Le fake `RecordingEngine`
enregistre les `feed` et rend un écran programmable : il permet de tester le fan-out, la
barrière de drainage et l'attachement sans parser une seule séquence ANSI.

**Disque — seam interne, délibérément.** `TranscriptSink` vit à l'intérieur de
`TranscriptTap` et n'apparaît pas dans l'interface de `SessionRuntime`. Un seam interne
utilisé par les tests du tap ne doit pas remonter dans l'interface du module (discipline
de seam) : `SessionManager` n'a pas à savoir qu'un transcript s'écrit dans un fichier.

**Temps et cadence.** Deux petits seams qui achètent le déterminisme : sans eux, tester
SES-06 coûte 11 secondes de sommeil réel par cas et devient flaky en CI ; avec
`ManualClock`, c'est instantané et exact.

**Remplacer, pas empiler.** Les tests visent l'interface de `SessionRuntime` : ouvrir un
terminal scripté, faire couler des octets, assurer que le transcript contient tout, que
l'écran attaché correspond, que `sessionEnded` n'arrive qu'après le flush. Pas de test
unitaire sur le fan-out interne ni sur l'anneau — ils survivraient mal au passage à tmux
ou à libghostty, qui est précisément ce qu'on veut pouvoir faire sans réécrire la suite.

---

## 5. Trade-offs

### Où le levier est fort

- **Un seul objet à apprendre pour tout le chemin chaud.** `SessionManager` connaît
  `openTerminal` / `close` / `shutdown` / `events()` ; l'UI connaît `attach` / `detach` /
  `resize` / `write`. Douze méthodes couvrent N terminaux × N backends × N observateurs.
- **Les trois évolutions annoncées coûtent une ligne de composition chacune.** tmux =
  un `PTYHost`. libghostty = une `TerminalEngineFactory`. Recherche live et réplication
  iOS = une `StreamObserverFactory`. Aucune de ces quatre n'ouvre `SessionRuntime.swift`.
- **Les terminaux multiples ne sont pas un cas particulier.** `TerminalKind` porte toute
  la différence ; SES-04 tombe du modèle au lieu d'être greffé dessus. Le corollaire —
  « la Session se termine avec son terminal principal » — est un invariant explicite (9)
  plutôt qu'une hypothèse implicite.
- **Localité maximale sur les pièges de la recherche.** Course EOF/exit, `PATH` absent,
  paire de resize, confinement de queue, `terminate()` obligatoire : cinq bugs sérieux
  vivent chacun à un seul endroit. Corrigés une fois, corrigés partout.
- **Testabilité sans process réel.** `RuntimeEnvironment.test(script:)` rend l'endurance
  (NFR-M, 100 sessions), le débit et l'escalade d'arrêt exécutables en CI, déterministes,
  sous Thread Sanitizer.

### Où le levier est mince

- **Le registre d'observateurs est de la généralité achetée à crédit.** Aujourd'hui il n'y
  a que deux observateurs de production (transcript, état) plus le rendu. « Un adapter =
  seam hypothétique » : ce seam-ci est justifié par la trajectoire §12, pas par le présent.
  Si la recherche live et la réplication iOS ne se font jamais, `StreamObserver` aura été
  de l'indirection pure, et un simple appel direct au tee aurait suffi. **C'est le pari
  central du candidat, et le premier endroit où le simplifier si l'on doute de la v2.**
- **Coût dans la boucle la plus chaude.** Un test d'`OptionSet` et un appel de protocole
  par observateur et par slice, à 20 Mo/s. Mesurable ; probablement noyé dans le coût du
  parsing, mais c'est une hypothèse à vérifier au banc, pas un acquis.
- **`ObserverContext.engine` est un trou de confinement fermé par convention.** Rien dans
  le type ne m'empêche de capturer le moteur et de le lire depuis un autre thread. Un
  `~Escapable` le fermerait proprement quand la version de Swift le permettra ; en
  attendant, `dispatchPrecondition` en debug et revue de code.
- **Le contrat de coût des observateurs (< 50 µs) n'est pas exécutable.** Un observateur
  lent plafonne le débit de sa session sans que rien ne le signale au-delà d'un
  `diagnostic`. C'est de la documentation, pas une garantie.
- **`PTYChannel` risque de mal épouser tmux.** `signal(.interrupt)` se traduit
  naturellement en forkpty ; en tmux, l'équivalent est un `send-keys C-c` et l'arrêt réel
  est un `kill-session`. Le `PTYCapabilities` amortit, mais la vraie forme du seam ne sera
  connue qu'en écrivant le second adapter. Écrire tôt un `TmuxPTYHost` même incomplet,
  uniquement pour valider la forme, est le meilleur investissement de dérisquage.
- **Plus de pièces mobiles que le strict nécessaire.** `RuntimeClock`, `RenderPacer`,
  `makeSessionQueue` : trois seams supplémentaires justifiés par le déterminisme des tests.
  Sur un module qu'on écrirait une fois et ne changerait plus, ce serait de la cérémonie ;
  sur celui-ci, qui doit accueillir deux backends et deux moteurs, ça se rentabilise.
- **`AsyncStream<RuntimeEvent>` ajoute un saut** entre la queue et l'appelant. Acceptable
  pour des événements de cycle de vie (rares) ; interdit sur le chemin des octets — d'où
  le fait que les observateurs soient synchrones sur la queue et non des consommateurs
  d'`AsyncSequence`. C'est un choix assumé de faire cohabiter deux styles de concurrence
  dans un même module.
