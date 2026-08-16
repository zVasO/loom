# SwiftTerm & PTY — recherche sur sources primaires

Recherche menée le 2026-08-14 pour le projet **loom**.

**Méthode.** Toutes les affirmations ci-dessous proviennent de sources primaires :
le dépôt officiel `migueldeicaza/SwiftTerm` cloné et lu localement, sa
documentation DocC embarquée (`Sources/SwiftTerm/Documentation.docc/`), ses
issues GitHub officielles, et les man pages / en-têtes SDK d'Apple sur la
machine.

**Révision analysée.** Clone `--depth 50` de `https://github.com/migueldeicaza/SwiftTerm.git`,
HEAD = `1052996` (« Merge pull request #632 from faisalmumtaz89/decrqss-nonascii-upstream »,
2026-08-13). Dernier tag = **v1.18.0** (`7691f85`, 2026-08-09, d'après `git log -1 --format=%ad v1.18.0`).

> ⚠️ **Avertissement de lecture.** La section 2 (thread-safety) contredit
> frontalement la documentation officielle de SwiftTerm. C'est le point le plus
> important de ce document pour loom. Voir §2.

---

## 0. Résumé exécutif

| Sujet | Verdict |
|---|---|
| Headless | Excellent support, classe dédiée `HeadlessTerminal`, documentée, testée |
| Thread-safety | **La doc officielle est fausse.** Aucune primitive de synchronisation dans le moteur |
| PTY | `forkpty` fourni clé en main ; `posix_spawn`/`openpty` **pas** utilisé (code mort) |
| Perf | Throttling à 60 fps côté vue ; backpressure PTY 4 MB ; perf engine = chantier ouvert |
| Licence | MIT (permissive, compatible commercial) |
| Environnement enfant | ⚠️ **`PATH` absent** de l'env par défaut — à fournir soi-même (§7.3) |

*Le document a fait l'objet d'une **seconde passe de vérification indépendante**
(§7) : aucun constat infirmé, 2 points de §6 clos, 3 compléments ajoutés.*

---

## 1. API SwiftTerm pour macOS

### 1.1 Les trois couches

Le dépôt sépare strictement moteur et vue.
Source : `README.md` L11-14 — « This repository contains both a terminal emulator
engine that is UI agnostic, as well as front-ends for this engine for iOS using
UIKit, and macOS using AppKit. »

| Classe | Fichier | Rôle |
|---|---|---|
| `Terminal` | `Sources/SwiftTerm/Terminal.swift` L303 | Moteur pur, **aucune dépendance UI** |
| `TerminalView` | `Sources/SwiftTerm/Mac/MacTerminalView.swift` | `NSView` AppKit |
| `LocalProcessTerminalView` | `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift` | `TerminalView` + PTY local |
| `HeadlessTerminal` | `Sources/SwiftTerm/HeadlessTerminal.swift` | `Terminal` + `LocalProcess`, **sans vue** |
| `LocalProcess` | `Sources/SwiftTerm/LocalProcess.swift` | Gestion process + PTY, réutilisable seule |

`Terminal` est déclaré `open class Terminal {` (Terminal.swift:303) — c'est une
classe ordinaire, ni `actor` ni `@MainActor`. Ce point est vérifié et
load-bearing pour §2.

### 1.2 Injection de bytes (`feed`)

Quatre points d'entrée publics, tous convergents (Terminal.swift L6148-6178) :

```swift
public func feed (byteArray: [UInt8])          // → parse(buffer: byteArray[...])
public func feed (text: String)                // → parse(buffer: ([UInt8](text.utf8))[...])
public func feed (buffer: ArraySlice<UInt8>)   // → parse(buffer: buffer)
public func parse (buffer: ArraySlice<UInt8>)  // → parser.parse(data: buffer)
```

`feed` est un mince wrapper : tout finit dans `parser.parse`. **Aucun verrou,
aucune file, aucun `await`** dans ce chemin. C'est un appel synchrone qui mute
directement le buffer.

Côté vue, `TerminalView` réexpose `feed` (`Apple/AppleTerminalView.swift` L2799,
L2807) et donne accès au moteur via `public func getTerminal() -> Terminal`
(AppleTerminalView.swift:378) et `public var terminal: Terminal!`
(MacTerminalView.swift:291).

### 1.3 Redimensionnement

Deux niveaux distincts, à ne pas confondre :

**Niveau moteur** — `Terminal.resize(cols:rows:)` (Terminal.swift:6707). Il
applique un plancher `MINIMUM_COLS`/`MINIMUM_ROWS`, sort tôt si les dimensions
sont inchangées, appelle `endSynchronizedOutput()`, `resizeBuffers(...)`, refait
les tab stops et déclenche `refresh(startRow:0, endRow:rows-1)`.

**Niveau PTY** — il faut *en plus* informer le kernel, sinon les applications
plein écran (vim, htop) gardent l'ancienne taille. `LocalProcessTerminalView`
le fait dans `sizeChanged` (MacLocalTerminalView.swift) :

```swift
public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard process.running else { return }
    var size = getWindowSize()
    let _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    processDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
}
```

> ⚠️ **`HeadlessTerminal` ne fait PAS ce second appel.** Il expose
> `getWindowSize()` (utilisé au démarrage du process) mais n'a aucun code
> appelant `setWinSize` après coup — vérifié par lecture intégrale de
> `HeadlessTerminal.swift`. Pour loom, un resize d'une session headless
> impose donc **deux** appels manuels : `terminal.resize(cols:rows:)` **et**
> `PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &ws)`.

### 1.4 Snapshot de l'écran / accès au buffer

API publiques (Terminal.swift, listées aussi dans
`Documentation.docc/Extensions/Terminal.md` sous « Buffer Access ») :

| API | Ligne | Sémantique |
|---|---|---|
| `getBufferAsData(kind:encoding:)` | 7144 | Buffer entier encodé, lignes séparées par `\n` |
| `getText(start:end:)` | 7163 | Texte entre deux `Position` |
| `getLine(row:)` | 839 | Ligne **relative à l'affichage** : `buffer.lines[row + buffer.yDisp]`, borné `0..<rows` |
| `getScrollInvariantLine(row:)` | 851 | Ligne **absolue depuis le début du scrollback** |
| `getCharData(col:row:)` | 823 | Cellule brute (`CharData`, avec attributs) |
| `getCharacter(col:row:)` | 863 | Cellule rendue en `Character` |
| `getCursorLocation()` | 6338 | `(x, y)` relatif à la partie visible |
| `getTopVisibleRow()` | 6345 | `buffer.yDisp` |

Et pour l'invalidation incrémentale (utile si loom veut ne re-parser que le
delta) : `getUpdateRange()` (6262), `getScrollInvariantUpdateRange()` (6312),
`clearUpdateRange()` (6325), `updateFullScreen()` (6244).

**Piège documenté par le code.** Le guide DocC `HeadlessUsage.md` affirme :
« After the process completes, the terminal buffer contains exactly what a user
would see on screen. You can extract it as text: `getBufferAsData()` ». C'est
imprécis. L'implémentation (Terminal.swift:7144) itère sur **toutes** les lignes
du buffer, scrollback compris :

```swift
for row in 0..<b.lines.count {
    let bufferLine = b.lines [row]
    let str = bufferLine.translateToString(trimRight: true)
    ...
}
```

Pour n'obtenir **que** l'écran visible, il faut boucler `0..<terminal.rows` avec
`getLine(row:)` — c'est d'ailleurs le second exemple du même document DocC.
Distinction critique pour loom : « ce qui est à l'écran » ≠ « tout ce qui a
été produit ».

`BufferLine.translateToString(trimRight:startCol:endCol:skipNullCellsFollowingWide:characterProvider:)`
(BufferLine.swift:502) est public et paramétrable — c'est la primitive de
scraping ligne à ligne.

### 1.5 Support headless — confirmé et de première classe

C'est un scénario **explicitement supporté**, pas un détournement.

- `README.md` L5-7 : « can be embedded into macOS, iOS applications, **text-based, headless applications** or other custom scenarios ».
- `README.md` L59 : « Bundled Headless terminal. »
- Fichier dédié `Sources/SwiftTerm/HeadlessTerminal.swift`, compilé sur macOS (`#if !os(iOS) && !os(Windows)`).
- Guide DocC dédié : `Documentation.docc/HeadlessUsage.md`.
- Page DocC dédiée : `Documentation.docc/Extensions/HeadlessTerminal.md`.
- Toute la suite de tests l'utilise (18 fichiers de test, dont `DcsTests`, `OscTests`, `UnicodeTests`, `ReflowTests`, `ImageTests`, `PerformanceTest`).

Docstring de la classe (HeadlessTerminal.swift) :

> « A `HeadlessTerminal` provides a terminal emulator that runs a local process,
> but the output does not go anywhere. You can use this to script applications
> and **screen scrape the output** for example, by accessing the `terminal` from
> this class. »

Constructeur : `public init(queue: DispatchQueue? = nil, options: TerminalOptions = .default, onEnd: @escaping (Int32?) -> ())`.

**`Terminal` seul, sans même `HeadlessTerminal`.** `Terminal(delegate:options:)`
est public (Terminal.swift:750) et `TerminalDelegate` a des implémentations par
défaut pour presque tout. J'ai calculé la différence entre les méthodes du
protocole (Terminal.swift L18-278) et celles de `public extension TerminalDelegate`
(Terminal.swift:7952+) :

**Une seule méthode est réellement obligatoire : `send(source:data:)`.**

Les 30 autres (`bell`, `bufferActivated`, `showCursor`, `hideCursor`,
`setTerminalTitle`, `scrolled`, `linefeed`, `selectionChanged`, `windowCommand`,
`isProcessTrusted`, `colorChanged`, `createImageFromBitmap`, `progressReport`,
`synchronizedOutputChanged`, etc.) ont un défaut no-op. Un délégué headless
minimal tient donc en ~5 lignes. C'est excellent pour loom s'il veut piloter
son propre transport (pas seulement un process local).

### 1.6 Licence & intégration SPM

**Licence : MIT.** `LICENSE` à la racine — « Permission is hereby granted, free
of charge, to any person obtaining a copy of this software... to deal in the
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies ».
Copyrights cumulés : Miguel de Icaza (2019-2026), les auteurs de xterm.js
(2017-2019), SourceLair (2014-2016), Christopher Jeffrey (2012-2013).
Aucune clause copyleft, aucune restriction commerciale. Une seule obligation :
conserver la notice.

**SPM.** `README.md` L107-109 : « SwiftTerm uses the Swift Package Manager for
its build, and you can add the library to your project by using the url for this
project or a fork of it. » Forme recommandée par `Documentation.docc/GettingStarted.md` :

```swift
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0")
]
```

Contraintes tirées de `Package.swift` (source faisant foi) :

- `// swift-tools-version:6.0` — **exige Swift 6.0+ / Xcode 16+**.
- Plateformes : `.iOS(.v14)`, `.macOS(.v11)`, `.tvOS(.v13)`, `.visionOS(.v1)`.
  (`.macOS(.v11)` parce que `disableBenchmark = true` ; sinon ce serait `.v13`.)
- `swiftLanguageModes: [.v5]` — le package compile en **mode langage Swift 5**,
  donc *sans* le contrôle de concurrence strict de Swift 6. Cohérent avec §2 :
  le compilateur ne vérifie aucune garantie de concurrence ici.
- Produit à lier : `.library(name: "SwiftTerm", targets: ["SwiftTerm"])`.
- Dépendances transitives : `swift-argument-parser` (≥1.0.0) et `swift-docc-plugin`
  (≥1.4.3). ⚠️ `swift-argument-parser` n'est nécessaire qu'à l'exécutable
  `termcast`, mais SPM la résoudra quand même.
- Ressource embarquée : `Apple/Metal/Shaders.metal`.
- Un build-tool plugin `SwiftTermBuildInfoPlugin` s'exécute à la compilation.

**Versions récentes** (dates issues de `git log` sur les tags, source primaire) :
v1.18.0 (2026-08-09), v1.17.0 (2026-08-09), v1.16.0 (2026-08-07).

> Note de fiabilité : la page GitHub Releases, lue via fetch, a renvoyé « August 9,
> 2024 » pour v1.18.0. C'est une erreur de lecture de l'outil ; les dates de
> commit git font foi et donnent 2026. Les notes de version citent pour v1.18.0
> « Small improvements by the community worth distributing **before the IO
> changes** » et pour v1.17.0 « OSC133 + fixes **before the big IO layer
> changes** » — indiquant une refonte de la couche I/O annoncée mais non encore
> livrée. À surveiller pour loom : la cadence est rapide (3 releases en 3 jours).

---

## 2. Thread-safety — ⚠️ la documentation officielle est fausse

### 2.1 Ce que la doc affirme

Trois affirmations officielles, concordantes :

1. `README.md` L76, liste des features : « **Thread-safe Terminal instances** »
2. `Documentation.docc/Documentation.md` L53 : « Thread-safe `Terminal` instances »
3. `Documentation.docc/Extensions/Terminal.md` — la plus explicite et la plus
   dangereuse :

   > « Instances are thread-safe: you can call `feed(byteArray:)` from a
   > background queue and **the terminal will synchronize internally**. »

### 2.2 Ce que le code montre

J'ai cherché toute primitive de synchronisation dans l'intégralité du moteur —
`Terminal.swift`, `Buffer.swift`, `BufferLine.swift`, `BufferSet.swift`,
`EscapeSequenceParser.swift`, `CircularList.swift` :

```
grep -rn "NSLock|os_unfair_lock|pthread_mutex|DispatchSemaphore|
          NSRecursiveLock|\.sync \{|actor |@MainActor"  <ces 6 fichiers>
→ aucun résultat
```

**Résultat vide.** Il n'existe **aucun** verrou, aucune file de sérialisation,
aucun acteur, aucun isolement `@MainActor` dans le moteur. `Terminal` est un
`open class` (Terminal.swift:303) dont `feed` mute directement le buffer.

Les deux seuls `NSLock` de toute la bibliothèque sont :

- `CharData.swift:193` — `private static let lock = NSLock()` protégeant la table
  **globale statique** `TinyAtom.map` (allocation d'identifiants 16 bits pour les
  URLs OSC 8 et les blobs d'images). Il protège de l'état *partagé entre toutes
  les instances*, pas l'état d'une instance.
- `LocalProcess.swift:95` — `pendingLock`, qui protège la file de chunks entrants
  de `LocalProcess`, pas le `Terminal`.

**Conclusion : « the terminal will synchronize internally » est factuellement
faux.** Ce qui est réellement vrai, et que le `NSLock` de `TinyAtom` rend
possible, c'est :

> On peut **confiner** une instance `Terminal` à un thread/queue de fond, et
> faire tourner **plusieurs instances `Terminal` en parallèle sur des queues
> différentes** sans corrompre l'état global partagé.

C'est du **thread-confinement**, pas de la thread-safety. Un accès concurrent à
*une même* instance est une data race.

### 2.3 Le contrat réel, tel qu'écrit dans le code

Les commentaires du code sont, eux, rigoureux et contredisent la doc publique :

- `Terminal.swift:1925` — « **Thread contract**: this mutates the incremental
  scanner state and the [...] thread — the same thread that calls `feed`. GUI
  views send on that thread; `HeadlessTerminal.send` marshals onto its effective
  queue »
- `Terminal.swift:2315` — « **Thread contract**: call this on the terminal's
  processing thread — the same thread that runs `feed` and `registerUserInput`
  — [...] from another thread must marshal them onto that thread. »
- `AppleTerminalView.swift:2855` — « it **MUST** be called on the same thread
  that drives `terminal.feed` »
- `AppleTerminalView.swift:2869` — une assertion runtime le vérifie :
  `assert(Thread.isMainThread, "TerminalView.send(data:) must be called on the main thread")`

Le code applique donc partout une discipline « un seul thread par Terminal ».

### 2.4 Comment le parsing hors-main est réellement supporté

C'est le chemin **testé et supporté**, à condition de fournir une queue.
`LocalProcess.childProcessRead` (LocalProcess.swift) branche selon la queue :

```swift
var keepReading = true
if usesMainQueue {
    keepReading = enqueueReceivedData(b)      // chemin main : file + coalescing
} else {
    dispatchQueue.sync {                       // chemin custom queue
        self.delegate?.dataReceived(slice: b[...])
    }
}
```

avec `usesMainQueue = (self.dispatchQueue === DispatchQueue.main)`.

Quand une queue custom est fournie, `feed` est appelé **synchronement depuis la
`readQueue` privée, sur la queue custom**. Une seule chaîne de lecture se
ré-arme à la fois (voir §4.2), donc les `feed` sont naturellement sérialisés.
C'est exactement le motif employé par toute la suite de tests :

```swift
let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
```
(`Tests/SwiftTermTests/DcsTests.swift:21` et ~18 autres fichiers)

où `SwiftTermTests.queue` (SwiftTermTests.swift:14) est :

```swift
DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, ...)
```

> 🔎 Détail intéressant : cette queue de test est `.concurrent`. La sérialisation
> ne vient donc **pas** de la queue mais du fait qu'une seule chaîne de lecture
> DispatchIO est active à la fois. Fragile par construction — si loom ajoute
> une seconde source qui `feed` le même `Terminal`, la sérialisation disparaît.
> **Recommandation : utiliser une queue `serial` par session**, ce qui rend
> l'invariant explicite plutôt qu'accidentel.

### 2.5 ⚠️ Fuite vers le main thread : `DispatchQueue.main.asyncAfter` dans le moteur

Le moteur n'est pas totalement agnostique de la main queue. Dans
`scheduleSynchronizedOutputTimeout()` (Terminal.swift:6799-6805) :

```swift
private func scheduleSynchronizedOutputTimeout () {
    synchronizedOutputTimeoutItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
        guard let self, self.synchronizedOutputActive else { return }
        self.endSynchronizedOutput()
    }
    synchronizedOutputTimeoutItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + synchronizedOutputTimeoutSeconds, execute: workItem)
}
```

avec `private let synchronizedOutputTimeoutSeconds: TimeInterval = 1.0` (Terminal.swift:388).

**Conséquence concrète pour loom.** Ce timer est armé quand l'application
invitée active le mode DEC 2026 « synchronized output » (Terminal.swift:5304,
5552 — référencé à `contour-terminal/vt-extensions` ; utilisé par tmux, neovim,
Ghostty…). Si le timeout expire, `endSynchronizedOutput()` s'exécute **sur la
main queue** et appelle `refresh(startRow:0, endRow:rows-1)`, qui mute
`refreshStart`/`refreshEnd`/`scrollInvariantRefresh*` — **pendant qu'un `feed`
peut tourner sur la queue de fond**. C'est une data race réelle, non protégée,
dans le scénario précis que loom vise (parsing hors-main de sessions non
affichées exécutant des TUI modernes).

Atténuations : la fenêtre est étroite (1 s après un `BSU` non suivi d'un `ESU`),
et les champs en cause sont des `Int` scalaires — la corruption pratique se
limiterait à une plage de rafraîchissement fausse, pas à un crash du buffer.
Mais sous Thread Sanitizer, cela **sera** signalé. À valider par un test TSan
dédié côté loom.

À noter : `Terminal.resize(cols:rows:)` appelle `endSynchronizedOutput()` de
façon synchrone, ce qui est correct si le resize est fait sur la queue du
terminal — encore un argument pour la discipline « tout sur la queue de session ».

---

## 3. Gestion du PTY

### 3.1 Ce que SwiftTerm fournit clé en main

`PseudoTerminalHelpers` (`Sources/SwiftTerm/Pty.swift`), compilé sur macOS
(`#if !os(iOS) && !os(tvOS) && !os(Windows)`). Docstring : « APIs to assist in
controlling a Unix pseudo-terminal from Swift. This provides a wrapper for the
libc `forkpty` API ». Trois méthodes statiques publiques :

| Méthode | Implémentation réelle |
|---|---|
| `fork(andExec:args:env:currentDirectory:desiredWindowSize:) -> (pid, masterFd)?` | `forkpty(&master, nil, nil, &desiredWindowSize)` puis, dans l'enfant, `chdir` optionnel + `execve` + `_exit(127)` en cas d'échec |
| `setWinSize(masterPtyDescriptor:windowSize:) -> Int32` | `ioctl(fd, TIOCSWINSZ, &windowSize)` |
| `availableBytes(fd:) -> (status, size)` | `ioctl(fd, 0x4004667f /* FIONREAD */, &size)` |

La gestion mémoire des tableaux C (`argv`, `envp`) est faite proprement via
`strdup` + `defer { freeCStringArray(...) }`.

**Donc : `forkpty` est fourni. Il n'y a rien à réécrire pour le cas nominal.**

### 3.2 ⚠️ `posix_spawn` + `openpty` : présent mais DÉSACTIVÉ (code mort)

`LocalProcess.swift` contient une implémentation alternative complète à base de
`openpty` + `login_tty` + swift-subprocess + `POSIX_SPAWN_SETSID`… **entièrement
neutralisée**. Tous ces blocs sont gardés par :

```swift
#if false //canImport(Subprocess)
```

`startProcess` route donc en dur vers `forkpty` :

```swift
public func startProcess(executable: String = "/bin/bash", ...) {
    if running { return }
    #if false //canImport(Subprocess)
    startProcessWithSubprocess(...)
    #else
    startProcessWithForkpty(...)     // ← le seul chemin réellement compilé
    #endif
}
```

La raison est documentée dans `Package.swift`, commentaire du target `SwiftTerm` :

> « We can not use Swift Subprocess, because there is **no way of configuring the
> child process to be a controlling terminal**, as it is posix-spawn based. »

La dépendance `swift-subprocess` est d'ailleurs commentée dans le manifeste.
La docstring de `LocalProcess` affirme pourtant encore « This implementation uses
swift-subprocess with openpty/login_tty for pseudo-terminal support » — **c'est
une docstring périmée** qui décrit le chemin mort. Ne pas s'y fier.

**Implication pour loom.** Si vous voulez `posix_spawn` + `openpty` (par
exemple pour éviter les dangers de `fork()` dans un process multi-threadé —
`forkpty` appelle `fork()`, et entre `fork` et `execve` seules les fonctions
async-signal-safe sont légales), **vous devrez l'implémenter vous-même**.
SwiftTerm ne vous le donne pas, et son auteur a explicitement renoncé à la voie
swift-subprocess. Les briques nécessaires existent toutefois toutes sur macOS
(vérifié dans le SDK, §3.4).

### 3.3 Process group / `setsid`

`forkpty(3)` s'en charge implicitement. Man page Apple `openpty(3)`
(`man 3 openpty`, section `DESCRIPTION`) :

> « The `login_tty()` function prepares for a login on the tty *fd* [...] by
> **creating a new session**, making *fd* the controlling terminal for the
> current process, setting *fd* to be the standard input, output, and error
> streams of the current process, and closing *fd*. »
>
> « The `forkpty()` function **combines `openpty()`, `fork()`, and `login_tty()`**
> to creates a new process operating in a pseudo-tty. »

Donc `forkpty` ⇒ `openpty` + `fork` + `login_tty` ⇒ nouvelle session + terminal
de contrôle. Aucun `setsid()` manuel n'est requis.

`setsid(2)` (man page Apple) : « creates a new session. The calling process is
the session leader of the new session, is the process group leader of a new
process group and **has no controlling terminal**. » — noter le « has no
controlling terminal » : `setsid()` seul ne suffit pas, il faut ensuite
`ioctl(TIOCSCTTY)` ou `login_tty()`.

Que le code de SwiftTerm compte bien sur la nouvelle session est confirmé par ce
commentaire dans `startProcessWithForkpty` :

> « processTerminated() reads self.shellPid (a 0 here makes `waitpid(0, ...)`
> target the caller's process group, which never matches the **setsid child**) »

### 3.4 Briques disponibles si loom réimplémente le PTY

Vérifié sur cette machine (SDK `MacOSX.sdk`, Xcode) :

| Brique | Vérification |
|---|---|
| `openpty`, `login_tty`, `forkpty` | `man 3 openpty` — déclarés dans `<util.h>` |
| `POSIX_SPAWN_SETSID` | `$SDK/usr/include/sys/spawn.h:61` → `#define POSIX_SPAWN_SETSID 0x0400` |
| `posix_spawnattr_setflags` | `$SDK/usr/include/spawn.h:110`, `__API_AVAILABLE(macos(10.5), ios(2.0))` |
| `TIOCSWINSZ` | `$SDK/usr/include/sys/ttycom.h:144` → `_IOW('t', 103, struct winsize)` |
| `TIOCGWINSZ` | `$SDK/usr/include/sys/ttycom.h:143` → `_IOR('t', 104, struct winsize)` |
| `SIGWINCH` | `$SDK/usr/include/sys/signal.h:119` → `#define SIGWINCH 28 /* window size changes */` |

`man 4 tty` (Apple), sur `TIOCSWINSZ` :

> « **TIOCGWINSZ** `struct winsize *ws` — Put the window size information
> associated with the terminal in the winsize structure pointed to by *ws*. The
> window size structure contains the number of rows and columns (and pixels if
> appropriate) of the devices attached to the terminal. It is set by user
> software and is the means by which most full-screen oriented programs determine
> the screen size. »
>
> « **TIOCSWINSZ** `struct winsize *ws` — Set the window size associated with the
> terminal to be the value in the winsize structure pointed to by *ws*. »

⚠️ **Non vérifié** — voir §6 : la man page Apple `tty(4)` ne dit **pas** que
`TIOCSWINSZ` envoie `SIGWINCH` au process group du terminal.

### 3.5 Lecture via DispatchIO — fournie par SwiftTerm

`LocalProcess` implémente déjà toute la boucle de lecture. Points saillants :

```swift
let readSize = 128*1024
var readQueue: DispatchQueue   // = DispatchQueue(label: "sender")
var io: DispatchIO?
```

Mise en place (`startProcessWithForkpty`) :

```swift
let fdToClose = childfd
io = DispatchIO(type: .stream, fileDescriptor: childfd, queue: dispatchQueue, cleanupHandler: { _ in
    close(fdToClose)      // fermé APRÈS que DispatchIO en a fini
})
io.setLimit(lowWater: 1)
io.setLimit(highWater: readSize)
io.read(offset: 0, length: readSize, queue: readQueue) { [weak self] done, data, errno in
    self?.childProcessRead(done: done, data: data, errno: errno)
}
```

Le commentaire justifie le `cleanupHandler` : « This prevents **EV_VANISHED
crash** by ensuring proper cleanup order ». Leçon à reprendre si loom
réimplémente : ne **jamais** `close()` un fd encore détenu par un `DispatchIO`.

Écriture — `send(data:)` utilise `DispatchIO.write` sur
`DispatchQueue.global(qos: .userInitiated)`, avec un garde `guard running`.

Détection de fin de process (macOS uniquement) :

```swift
childMonitor = DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
cm.setEventHandler(handler: { [weak self] in self?.processTerminated () })
if #available(macOS 10.12, *) { cm.activate() } else { cm.resume() }
```

Le commentaire adjacent documente un bug corrigé, précieux pour loom :
« **NOTE_EXIT is delivered at most once**; if the source is activated first and a
fast-exiting child's exit fires before the handler is set, the event is dropped
and never redelivered, so `processTerminated()` never runs — the child is not
reaped and callers waiting on exit hang. » ⇒ **poser le handler avant
`activate()`**.

`terminate()` fait `io?.close()`, met `childfd = -1`, puis `kill(shellPid, SIGTERM)`.
Le `deinit` ferme le `DispatchIO` mais **n'envoie pas** `SIGTERM` (choix
délibéré et commenté). ⚠️ Pour loom : oublier `terminate()` laisse le shell
enfant vivant.

### 3.6 ⚠️ Piège majeur : la queue par défaut est la MAIN queue

`LocalProcess.init` (LocalProcess.swift) :

```swift
public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil) {
    self.delegate = delegate
    self.dispatchQueue = dispatchQueue ?? DispatchQueue.main     // ← main !
    self.readQueue = DispatchQueue(label: "sender")
    self.usesMainQueue = self.dispatchQueue === DispatchQueue.main
}
```

et `HeadlessTerminal` transmet la queue telle quelle :
`process = LocalProcess(delegate: self, dispatchQueue: queue)`.

Donc **`HeadlessTerminal(options:onEnd:)` sans argument `queue` livre les données
sur la main queue.**

**Le guide DocC officiel affirme le contraire** (`HeadlessUsage.md`, section
« Dispatch Queue ») :

> « **By default, process I/O is dispatched on a private queue.** You can provide
> your own queue for integration with existing concurrency patterns. »

**C'est faux.** La seule queue privée est `readQueue` (label `"sender"`), qui
sert à *lire*, pas à *livrer*. La livraison — donc `feed` — se fait sur
`dispatchQueue`, qui vaut `.main` par défaut.

Preuve par l'usage officiel : `Sources/Termcast/TermcastRecorder.swift` construit
`LocalProcess(delegate: recorder)` **sans queue** (ligne 58) et doit donc, ligne
86, faire tourner explicitement `RunLoop.main.run()`. Un outil CLI qui a besoin
d'une run loop main : c'est la signature du défaut sur la main queue.

> 🔴 **Conséquence directe pour loom.** Un démon / CLI sans run loop main
> active qui instancie `HeadlessTerminal` sans queue **ne recevra jamais aucune
> donnée** — le process tournera, le PTY se remplira, et rien n'arrivera. La
> parade est en une ligne : **toujours passer une `DispatchQueue` sérielle
> explicite par session.** Cela règle simultanément ce piège, la sérialisation
> de `feed` (§2.4) et le parsing hors-main voulu.

---

## 4. Performance

### 4.1 Throttling / coalescing côté vue

`queuePendingDisplay()` (`Apple/AppleTerminalView.swift`:2512) — commentaire
d'intention :

> « The code below is intended to not repaint too often, which can produce
> flicker, for example when the user refreshes the display, and this repaints the
> screen, as dispatch delivers data in blocks of 1024 bytes, which is not enough
> to cover the whole screen, so this delays the update »

```swift
func queuePendingDisplay () {
    if terminal.synchronizedOutputActive { return }
    if !pendingDisplay {
        let fps60 = 16670000            // ns
        let fpsDelay = fps60
        pendingDisplay = true
        DispatchQueue.main.asyncAfter(deadline: ..., execute: updateDisplay)
    }
}
```

⇒ **plafond à 60 fps**, via un flag `pendingDisplay` qui absorbe toutes les
demandes intermédiaires. Même mécanisme pour Metal (`queueMetalDisplay`,
`pendingMetalDisplay`). Un second point de coalescing (AppleTerminalView.swift
~2785) porte ce commentaire : « **Coalesce with the throttled path**: if a redraw
is already scheduled [...] don't post another [...] instead of flooding the main
queue with one updateDisplay per chunk. »

> **Pertinent pour loom** : tout ce throttling vit dans la **couche vue**. En
> headless, il n'y en a **aucun** — `feed` parse à la vitesse d'arrivée des
> octets. C'est ce que vous voulez pour du parsing, mais cela signifie que le
> coût CPU est proportionnel au débit, sans amortissement. Si loom n'a besoin
> que d'un snapshot périodique, il faut throttler **la lecture du buffer**
> (`getLine`/`getBufferAsData`), pas le `feed`.

### 4.2 Backpressure PTY — protection anti-OOM (chemin main queue uniquement)

`LocalProcess.swift` implémente une régulation de flux, avec un commentaire qui
documente le bug d'origine :

```swift
private let pendingHighWaterBytes = 4 * 1024 * 1024   // 4 MB
private let pendingLowWaterBytes  = 1 * 1024 * 1024   // 1 MB
private let pendingChunkFlushThreshold = 32
private let pendingTimeSliceNs: UInt64 = 4_000_000    // 4 ms
```

> « Backpressure for the main-queue delivery path: without it the read loop
> re-arms unconditionally, so when the child produces output faster than the
> consumer queue drains it, `pendingChunks` grows without bound (**observed
> ~280 MB/s with a `yes` flood against a busy main thread — multi-GB footprints
> in long sessions**). Past the high-water mark we stop re-arming the PTY read;
> the kernel PTY buffer fills and the child blocks in `write()`, exactly like any
> other terminal. Reads resume once the backlog drains below the low-water mark. »

`drainReceivedData` cède la main toutes les 4 ms (`pendingTimeSliceNs`) en se
re-postant, pour ne pas monopoliser la queue.

Second garde-fou documenté, sur le ré-armement des lectures :

> « `done`: DispatchIO invokes this handler several times per read op (partial
> deliveries with `done=false`, then a final `done=true`). **Re-arming on every
> invocation spawns an extra concurrent read chain per partial delivery** — under
> a fast producer the chains multiply and hundreds of MB of in-flight reads pile
> up. One op must spawn exactly one successor. »

> 🔴 **Point critique pour loom.** Cette backpressure n'est appliquée que sur
> `if usesMainQueue`. Sur le chemin **queue custom** — celui que loom va
> utiliser — la branche est `dispatchQueue.sync { delegate?.dataReceived(...) }`.
> Le `sync` fournit une backpressure *implicite* (la readQueue bloque tant que le
> `feed` n'est pas fini, donc le PTY n'est pas relu, donc le kernel finit par
> bloquer l'enfant en `write()`). C'est correct, mais **cela signifie que le
> parsing devient bloquant pour la boucle de lecture**. Si N sessions partagent
> une queue, un `feed` lent en bloque N. **Une queue sérielle par session** est
> donc à nouveau la bonne granularité.

### 4.3 Scrollback configurable

`TerminalOptions.scrollback` — « Size of the scrollback buffer, **defaults to 500
lines** » (`TerminalOptions.swift`). Configurable au démarrage :

```swift
let options = TerminalOptions(cols: 132, rows: 50, scrollback: 5000)   // ex. de HeadlessUsage.md
```

Modifiable **à chaud** :

- `Terminal.changeScrollback(_ newScrollback: Int?)` (Terminal.swift:6742)
- `Terminal.changeHistorySize(_:)` (6760) — simple alias de `changeScrollback`
- `HeadlessTerminal.changeScrollback(_:)` — délègue au terminal
- `Terminal.clearScrollback()` (6735) — vide l'historique **sans** effacer
  l'écran visible ni changer la capacité

`nil` désactive le scrollback. Les trois méthodes ne touchent que le buffer
normal : « Only the normal buffer has scrollback, the alt buffer should never
have scrollback. »

Coût mémoire : `CircularList.init(maxLength:)` (CircularList.swift:58-61) fait
`Array(repeating: nil, count: maxLength)` — les *slots* sont préalloués. Ce sont
des optionnels de référence (~8 octets), donc ~40 KB pour 5000 lignes : le coût
des slots est négligeable, le coût réel vient des `BufferLine` effectivement
remplies.

Autre limite mémoire à connaître : `kittyImageCacheLimitBytes`, « defaults to
**320MB** and is clamped to 4GB » (TerminalOptions.swift). ⚠️ Par session, cela
peut peser lourd si loom multiplie les sessions et que les programmes émettent
des images Kitty. À réduire explicitement. `Terminal.garbageCollectPayload()`
(6277) libère les payloads (images, URLs) devenus inatteignables.

### 4.4 Problèmes de perf connus (issues GitHub officielles)

| # | Titre | État | Date |
|---|---|---|---|
| 379 | Idea for performance. | **Ouverte** | 2025-07-02 |
| 373 | Performance | **Ouverte** | 2025-06-12 |
| 374 | Performance 2 | Fermée | 2025-06-20 |
| 372 | Low hanging fruit | Fermée | 2025-06-12 |
| 525 | DEC 2026 sync output 100ms debounce causes input lag for direct applications | Fermée | 2026-04-03 |
| 294 | Rapid input causes LocalProcessTerminalView hosting REPL processes to hang | Fermée | 2023-05-22 |

**Issue #373 « Performance »** (ouverte, par le mainteneur lui-même) — chiffres
de référence : débit initial mesuré à **94 983 caractères/seconde** via
`PerformanceTest`, sur MacBook Pro M1 Max 2021. Diagnostic : `swift_beginAccess`
représente ~12 % du temps global quand `insertCharacter` accède aux propriétés du
buffer, et **43,2 %** si l'on ne considère que `insertCharacter` ; retain/release
ajoutent ~12 %. Optimisations planifiées : valider les `syncValues`, ajouter un
`lastBufferStorage` pour les caractères combinants, synchroniser les wrap modes.

Ce diagnostic éclaire un vestige dans `Package.swift` : le flag
`-enforce-exclusivity=none` est présent **en commentaire** sur le target — une
piste d'optimisation envisagée puis non retenue.

**Issue #294** (fermée) — pertinente pour le PTY : envoi rapide de gros volumes
vers un `LocalProcessTerminalView` hébergeant un REPL GHCI ⇒ la vue devient
« unresponsive » et « the hosted REPL process becomes unresponsive to further
text input ». Le rapporteur mettait en cause `send` / `DispatchIO` réentrant en
contexte `@MainActor`. La page ne montre pas le correctif appliqué (voir §6).

**Issue #525** (fermée) — le debounce de 100 ms du mode DEC 2026 causait du lag
d'entrée. Aujourd'hui la constante vaut `synchronizedOutputTimeoutSeconds = 1.0`
(Terminal.swift:388) et le mécanisme est décrit comme « Mirrors ghostty: flip a
flag and arm a safety timer ». Contexte utile pour le risque décrit en §2.5.

### 4.5 Outillage de mesure fourni

`PERFORMANCE.md` documente trois niveaux, dont deux directement réutilisables
par loom :

1. **Headless feed benchmarks** — « measure the terminal-emulation engine (parser
   + buffer) **with no rendering** ». Dans `Tests/SwiftTermTests/PerformanceTest.swift`.
   ```bash
   swift test -c release -Xswiftc -enable-testing --filter "PerformaceTests/testPerformance2"
   ```
   ⚠️ « Run each test individually with `--filter` — **Swift Testing runs tests
   concurrently by default, which corrupts throughput measurements**. »
2. **RenderBench** (`Tools/RenderBench`) — chemin de rendu réel, non pertinent en headless.
3. **In-app / vtebench** — bout en bout sur PTY réel.

Avertissements méthodologiques du même document, à retenir : « **Pair your A/B
runs** » (les chiffres absolus dérivent) ; « `time cat file` [...] payloads under
a few MB fit in kernel buffering and undercount. **Use payloads of 10 MB+** » ;
les distributions vtebench sont bimodales, « treat differences under ~10% as
noise ». Un build **Release** est impératif : « Debug builds SwiftTerm at
`-Onone` and exaggerates Swift-level costs ».

Chaque `feed` est instrumenté par un `os_signpost` (sous-système
`org.tirania.SwiftTerm`) — exploitable directement dans Instruments par loom.

---

## 5. Recommandations pour loom

Découlant directement des constats ci-dessus :

1. **Une `DispatchQueue` sérielle dédiée par session**, passée explicitement à
   `HeadlessTerminal(queue:)`. Résout d'un coup : le piège de la main queue
   (§3.6), la sérialisation de `feed` (§2.4), l'isolement des sessions lentes
   (§4.2). C'est la décision d'architecture la plus rentable du document.
2. **Ne jamais toucher un `Terminal` hors de sa queue.** Toute lecture de snapshot
   (`getLine`, `getBufferAsData`, `getCursorLocation`) doit être marshalée sur la
   queue de la session. La doc promet une synchronisation interne qui n'existe pas
   (§2.2).
3. **Tester sous Thread Sanitizer**, en ciblant le mode DEC 2026 (§2.5) — c'est le
   seul point où le moteur touche la main queue de lui-même.
4. **Toujours appeler `terminate()`** ; `deinit` n'envoie pas `SIGTERM` (§3.5).
5. **Resize = deux appels** en headless : `terminal.resize(cols:rows:)` **et**
   `PseudoTerminalHelpers.setWinSize(...)` (§1.3).
6. **Régler `scrollback` et `kittyImageCacheLimitBytes` explicitement** — les
   défauts (500 lignes, 320 MB) sont pensés pour une app mono-session (§4.3).
7. **Distinguer écran visible et buffer complet** : `getBufferAsData()` renvoie
   aussi le scrollback (§1.4).
8. **Épingler la version SPM** (`.upToNextMinor(from: "1.18.0")` plutôt que
   `from: "1.0.0"`) : cadence de release rapide et refonte de la couche I/O
   annoncée dans les notes de v1.17/v1.18 (§1.6).
9. **Toujours passer un `environment` explicite incluant `PATH`.** L'environnement
   par défaut de SwiftTerm **omet `PATH`** (commenté dans le code source), ce qui
   casse toute invocation non-login (§7.3).
10. **Ne détecter la fin de session que via `processTerminated(_:exitCode:)`**, et
    drainer la queue de session avant le snapshot final : l'EOF du PTY et l'exit du
    process sont deux événements distincts, d'ordre non garanti (§7.4).

---

## 6. Ce que je n'ai PAS pu vérifier

Listé explicitement, par honnêteté méthodologique.

1. **`TIOCSWINSZ` envoie-t-il `SIGWINCH` ?** Non vérifié sur source primaire
   Apple. `man 4 tty` décrit `TIOCSWINSZ` sans mentionner de signal, et `grep -i
   "SIGWINCH|window size"` sur cette man page ne renvoie aucune ligne l'affirmant.
   `SIGWINCH` existe bien (`sys/signal.h:119`, « window size changes ») et c'est
   le comportement BSD/XNU attendu, mais **je ne peux pas le sourcer depuis la
   documentation Apple**. À valider empiriquement par loom (test : resize d'un
   PTY hébergeant `vim`, observer la réaction).
2. **Résolution de l'issue #294.** Le fetch de la page n'a renvoyé que le rapport
   initial, sans les commentaires ni le commit de correction. Le statut « Closed »
   est certain, la nature du correctif ne l'est pas.
3. ~~**Contenu complet des issues #379 et #372.**~~ **#379 résolu** lors de la
   seconde passe (§7.2) ; #372 (« Low hanging fruit », fermée) reste non ouverte.
4. **Datation de l'affirmation « Thread-safe Terminal instances ».** Le clone est
   `--depth 50` ; `git log -S` sur cette chaîne remonte au commit de troncature
   `d3e2d4c`, qui apparaît comme créant *tous* les fichiers. Impossible donc de
   dater l'ajout de cette ligne au README, ni de savoir si elle a précédé ou suivi
   une éventuelle synchronisation depuis retirée. **Le constat de §2.2 sur le code
   actuel reste, lui, certain** (grep exhaustif sur la révision analysée).
5. **Aucune compilation ni exécution.** Je n'ai ni construit SwiftTerm, ni lancé
   ses tests, ni exécuté de benchmark. Tous les constats sont issus de lecture de
   code, de documentation et de man pages. Les chiffres de perf cités (94 983
   char/s, ~280 MB/s) sont **rapportés par le projet**, non reproduits par moi.
6. **Comportement réel sous Thread Sanitizer.** La data race décrite en §2.5 est
   déduite par lecture du code, pas observée. Elle mérite confirmation
   expérimentale avant d'être traitée comme un fait.
7. ~~**`availableBytes` / FIONREAD.**~~ **Résolu** lors de la seconde passe : la
   constante `0x4004667f` est exacte et portable. Démonstration en §7.1.

---

## 7. Seconde passe — vérification indépendante et compléments

Cette section est le produit d'une **relecture indépendante** des mêmes sources
primaires (même clone, révision `1052996`), menée sans s'appuyer sur les sections
1-6. Objectif : confirmer ou infirmer les constats, et combler les trous de §6.

### 7.0 Résultat de la vérification croisée

Les constats suivants ont été **re-dérivés indépendamment et confirmés** :
absence totale de primitive de synchronisation dans le moteur (§2.2) ; contrat
« un thread par Terminal » écrit dans les commentaires (§2.3) ; `forkpty` seul
chemin compilé et blocs `#if false //canImport(Subprocess)` morts (§3.2) ;
`dispatchQueue ?? DispatchQueue.main` dans `LocalProcess.init` (§3.6) ; seuils de
backpressure 4 MB / 1 MB / 32 chunks / 4 ms (§4.2) ; throttle `fps60 = 16670000`
ns (§4.1) ; `scrollback: 500` et `kittyImageCacheLimitBytes: 320 MB` par défaut
(§4.3) ; licence MIT à quatre copyrights (§1.6) ; `swift-tools-version:6.0` +
`swiftLanguageModes: [.v5]` + `.macOS(.v11)` (§1.6) ; `terminate()` = `SIGTERM`
seul (§3.5).

**Aucune contradiction relevée.** Les trois compléments ci-dessous sont additifs.

### 7.1 `FIONREAD` — constante vérifiée exacte (clôt §6.7)

`Pty.swift:132` code la constante en dur :

```swift
let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
```

Vérification par dérivation depuis les en-têtes du SDK de cette machine
(`MacOSX.sdk`, chemin obtenu via `xcrun --show-sdk-path`) :

| Élément | Source | Valeur |
|---|---|---|
| `FIONREAD` | `sys/filio.h:77` | `_IOR('f', 127, int)` |
| `_IOR(g,n,t)` | `sys/ioccom.h:94` | `_IOC(IOC_OUT, (g), (n), sizeof(t))` |
| `IOC_OUT` | `sys/ioccom.h:83` | `0x40000000` |
| `IOCPARM_MASK` | `sys/ioccom.h:74` | `0x1fff` |

Calcul : `0x40000000 | ((4 & 0x1fff) << 16) | ('f' << 8) | 127`
= `0x40000000 | 0x00040000 | 0x6600 | 0x7f` = **`0x4004667f`** ✅ — identique à la
valeur codée en dur.

**Portabilité arm64 / x86_64 : garantie.** Le seul terme dépendant de la
plateforme est `sizeof(int)`, qui vaut 4 sous les deux ABI (LP64). La constante
est donc correcte sur Apple Silicon comme sur Intel. Le point §6.7 est clos.

### 7.2 Issue #379 « Idea for performance » — contenu (clôt §6.3)

Ouverte par **Miguel de Icaza le 2 juillet 2025**, toujours ouverte, sans label ni
assignee ni PR liée.

Proposition : remplacer la structure actuelle *tableau de lignes* par un **bloc de
données unique organisé en matrice L×C** (L = lignes, C = colonnes), afin de
réduire les appels à `swift_beginAccess` en uniformisant les schémas d'accès
mémoire. C'est la suite logique du diagnostic de #373 (§4.4), qui attribuait
~12 % du temps global à `swift_beginAccess`.

L'issue **ne contient ni benchmark, ni cas de test, ni critère d'acceptation** —
c'est une note d'intention du mainteneur, pas un plan.

> **Lecture pour loom.** Les deux issues perf ouvertes (#373, #379) visent
> toutes deux la représentation interne du buffer. Une telle refonte, combinée à
> la « big IO layer change » annoncée dans les notes de v1.17/v1.18 (§1.6),
> renforce la recommandation n°8 : **épingler la version**.

### 7.3 ⚠️ `getEnvironmentVariables` n'inclut PAS `PATH` — piège opérationnel

Point non couvert plus haut, et directement bloquant pour loom.

`LocalProcess.startProcess` construit l'environnement de l'enfant ainsi
(`LocalProcess.swift`, `startProcessWithForkpty`) :

```swift
var env: [String]
if environment == nil {
    env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
} else {
    env = environment!
}
```

Or l'implémentation (`Terminal.swift:7070`) est :

```swift
public static func getEnvironmentVariables (termName: String? = nil, trueColor: Bool = true) -> [String]
{
    var l : [String] = []
    let t = termName == nil ? "xterm-256color" : termName!
    l.append ("TERM=\(t)")
    if trueColor { l.append ("COLORTERM=truecolor") }
    // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
    l.append ("LANG=en_US.UTF-8")
    let env = ProcessInfo.processInfo.environment
    for x in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USER", "HOME" /* "PATH" */ ] {
        if env.keys.contains(x) { l.append ("\(x)=\(env[x]!)") }
    }
    return l
}
```

**`"PATH"` est explicitement commenté dans la liste des variables reprises.**
L'environnement par défaut se limite donc à : `TERM`, `COLORTERM`, `LANG`,
`LOGNAME`, `USER`, `DISPLAY`, `LC_TYPE`, `HOME`. (Noter aussi le bug bénin :
`"USER"` figure deux fois, et `"LC_TYPE"` est vraisemblablement une coquille pour
`LC_CTYPE`.)

**Conséquence.** Un `/bin/bash` lancé en **shell de login** (`-l`) reconstruit un
`PATH` via `/etc/profile` + `path_helper`, ce qui masque le problème. Mais toute
invocation **non-login** — `bash -c "..."`, un binaire lancé directement, ou une
commande one-shot, exactement le genre de chose qu'un outil d'automatisation
fait — hérite d'un environnement **sans `PATH`**, et échouera en
« command not found » sur des commandes pourtant présentes.

> ✅ **Recommandation (à ajouter à la liste §5).** Ne jamais laisser
> `environment: nil`. Construire explicitement :
> ```swift
> var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
> env.append("PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")")
> process.startProcess(executable: "/bin/bash", args: [...], environment: env)
> ```
> Rappel connexe (§1.3 de `MacLocalTerminalView`) : passer `nil` conserve
> `TERM=xterm-256color` en dur et **ignore `options.termName`** — le commentaire
> du code le dit explicitement (« hosts that want options.termName in the child's
> environment pass `Terminal.getEnvironmentVariables(termName:)` explicitly »).

### 7.4 EOF du PTY ≠ fin du process — deux événements distincts

Subtilité de `LocalProcess.childProcessRead` importante pour détecter la fin
d'une session :

```swift
if data.count == 0 {
    childfd = -1
    if running {
        // Keep process monitor alive so the exit event can still deliver
        // processTerminated to clients when PTY EOF arrives first.
        childStopped(cancelProcessMonitor: false)
        // delegate.processTerminated (self, exitCode: nil)   ← délibérément désactivé
    }
    return
}
```

Donc, à la fermeture d'une session, **deux** événements arrivent dans un ordre non
garanti : l'EOF sur le PTY, et `NOTE_EXIT` du `DispatchSourceProcess`. L'EOF
passe `running` à `false` **sans** notifier le délégué ; seul `NOTE_EXIT` déclenche
`processTerminated(_:exitCode:)`. Le paramètre `cancelProcessMonitor: false`
existe précisément pour que l'EOF n'annule pas le moniteur qui portera le code de
sortie.

> **Pour loom :** ne pas traiter `dataReceived` s'arrêtant comme la fin de
> session, et ne pas conclure non plus depuis `running == false`. **La seule
> source de vérité pour la terminaison et le code de sortie est le callback
> `processTerminated(_:exitCode:)`.** Corollaire : le dernier lot d'octets peut
> encore être en cours de `feed` quand ce callback arrive — il faut donc drainer
> la queue de session avant de prendre le snapshot final du buffer.

### 7.5 Le code de la vue confirme le `feed` hors-main (renfort de §2.4)

Élément de preuve supplémentaire que « `feed` sur un thread de fond » est un
scénario **prévu par le projet**, et pas seulement toléré — dans
`Mac/MacTerminalView.swift:209-218` :

```swift
/// Output received shortly after local input is likely echo or prompt redraw;
/// render it without the 16.67ms frame-rate throttle so typing feels responsive.
var lastUserInputUptimeNs: UInt64 = 0
/// Guards lastUserInputUptimeNs, which is written on the main thread and
/// read from the (possibly background) feed thread.
let userInputLock = NSLock()
let interactiveInputDisplayWindowNs: UInt64 = 150_000_000   // 150 ms
```

Deux enseignements :

1. « read from the **(possibly background) feed thread** » — le projet assume
   explicitement, jusque dans sa couche AppKit, que `feed` puisse tourner hors du
   main thread. Cela confirme §2.4 : le mode supporté est **confinement sur une
   queue**, et la seule donnée partagée entre cette queue et le main thread est
   protégée à la main, au cas par cas (ici par `userInputLock`).
2. Complément à §4.1 : le throttle 60 fps admet un **contournement** — pendant
   150 ms après une frappe utilisateur, le rendu est immédiat. Sans effet en
   headless (aucune vue), mais bon à savoir si loom affiche un jour une session.

---

## Annexe — index des sources

**Dépôt officiel** — `https://github.com/migueldeicaza/SwiftTerm`, révision
`1052996` (2026-08-13), tag le plus récent `v1.18.0` (2026-08-09).

Fichiers lus intégralement ou partiellement :
`README.md` · `LICENSE` · `Package.swift` · `PERFORMANCE.md` ·
`Sources/SwiftTerm/Terminal.swift` · `Sources/SwiftTerm/HeadlessTerminal.swift` ·
`Sources/SwiftTerm/LocalProcess.swift` · `Sources/SwiftTerm/Pty.swift` ·
`Sources/SwiftTerm/TerminalOptions.swift` · `Sources/SwiftTerm/CharData.swift` ·
`Sources/SwiftTerm/CircularList.swift` · `Sources/SwiftTerm/BufferLine.swift` ·
`Sources/SwiftTerm/Mac/MacLocalTerminalView.swift` ·
`Sources/SwiftTerm/Mac/MacTerminalView.swift` ·
`Sources/SwiftTerm/Apple/AppleTerminalView.swift` ·
`Sources/SwiftTerm/Documentation.docc/{Documentation,GettingStarted,HeadlessUsage}.md` ·
`Sources/SwiftTerm/Documentation.docc/Extensions/{Terminal,HeadlessTerminal}.md` ·
`Sources/Termcast/TermcastRecorder.swift` ·
`Tests/SwiftTermTests/{SwiftTermTests,DcsTests}.swift`

**Issues GitHub** — `.../issues/373`, `/379`, `/294`, et la recherche
`issues?q=is:issue+performance+OR+slow+OR+lag`.

**Seconde passe (§7)** — mêmes fichiers, plus :
`Sources/SwiftTerm/Terminal.swift:7070` (`getEnvironmentVariables`) ·
`Sources/SwiftTerm/Pty.swift:132` (`availableBytes`/FIONREAD) ·
`Sources/SwiftTerm/Mac/MacTerminalView.swift:209-218` ·
`$(xcrun --show-sdk-path)/usr/include/sys/filio.h:77` ·
`.../usr/include/sys/ioccom.h:74,83,94`

**Documentation API en ligne** —
`https://migueldeicaza.github.io/SwiftTerm/documentation/swiftterm/`
(référencée par le README ; le contenu correspond aux fichiers DocC lus en local,
qui font foi ici car liés à la révision analysée).

**Apple** — `man 3 openpty` · `man 2 setsid` · `man 4 tty` ·
`MacOSX.sdk/usr/include/sys/spawn.h` · `.../usr/include/spawn.h` ·
`.../usr/include/sys/ttycom.h` · `.../usr/include/sys/signal.h`
