# SessionRuntime — synthèse du « design it twice » et décision

Trois candidats complets dans `candidates/` (A minimal, B flexible, C appelant-d'abord), produits indépendamment sous contraintes opposées. Ce document est la décision ; les candidats restent la trace des alternatives.

## Convergences (donc considérées comme acquises)

Les trois designs, sans se voir, ont convergé sur : la queue sérielle de session invisible de l'appelant (ADR-0007 rendu structurel) ; le seam `PTYHost` à deux adapters (forkpty prod / scripté test), seul moyen de tester la course EOF/exit et l'escalade SES-06 sans process réel ; la fin de session par l'exit jamais par l'EOF, avec **barrière de drainage** avant l'événement final (transcript complet garanti à `.terminated`) ; le `PATH` construit par le module ; le resize à deux opérations caché ; `TerminalScreen` = écran visible seulement, jamais le scrollback ; le runtime **mesure et transporte, n'interprète pas** — `working`/`needs_input` appartiennent au StateEngine.

## Divergences et arbitrage

| Axe | A (minimal) | B (flexible) | C (appelant) | Retenu |
|---|---|---|---|---|
| Surface | 3 points d'entrée + `TerminalAttachment` (détach par ARC) | ~12 méthodes + registre `StreamObserver` | `launch`/`events`/`stop` + `TerminalSurface` `@Observable` | **C**, avec le flux d'événements rendu par `launch` (idée A) |
| Vue | pull de frames `AsyncSequence` | push `TerminalViewSink` (délégué MainActor) | `surface.attached()` en `.task`, `screen` jamais vide | **C** — le cycle de vie suit l'annulation structurée SwiftUI, la faute « oublier de détacher » devient non représentable |
| Extensibilité | aucune prévue | observateurs N-aires (recherche live, iOS) | aucune prévue | **A/C** : rejet du registre en v1 — « un adapter = seam hypothétique ». Transcript et échantillonnage câblés en dur ; le registre reste l'option v2 documentée dans B |
| Shell secondaire | `attach(.newShell)` (création+attache fusionnées) | `openTerminal(spec)` générique | `openShell()` dédié | **C** — A signale lui-même sa fusion comme son compromis le plus discutable |
| Erreurs | typées par méthode | 8 cas + quarantaine | un seul `try` à `launch`, le non-fatal en `.notice` | **C** — la frappe clavier ne doit pas avoir de `do/catch` |
| Forme PTY seam | callbacks séparés | `PTYEvent` enum + `PTYCapabilities`, jamais de fd | callbacks mutables | **B** — l'enum rend l'ordre EOF/exit testable par construction, l'absence de fd et les capabilities préparent tmux (v2 actée, ADR-0006) sans le payer |
| Arrêt | `StopPolicy` valeur | `ShutdownLadder` valeur | `StopMode` enum | `ShutdownLadder` (B) : l'escalade est une donnée, testable sous horloge injectée |

## Décision (v1)

Le squelette **C**, durci par deux emprunts :

1. **API du module** : `SessionRuntime.launch(plan, using: .live) → (runtime, events)` (le flux rendu une seule fois, propriété mono-consommateur structurelle — A) ; `stop(_ ladder: ShutdownLadder)` idempotent ; `openShell`/`closeShell` ; `send` non-async non-jetant ; `surface(_:) → TerminalSurface` `@MainActor @Observable`, `screen` jamais vide.
2. **Seams internes** (`Dependencies` avec défauts, aucun appelant de production ne les nomme) : `PTYHost`/`PTYChannel` forme B (PTYEvent, capabilities, pas de fd), `TerminalEngine` + fabrique (snapshot(), takeDirtyRows(), setScrollback — élargissement assumé du §6.2 du cahier des charges), `TranscriptSink`, `Clock`, `EnvironmentResolver`.
3. **Rejets explicites** : registre d'observateurs (v2 si la recherche live/iOS se confirment — reprendre B §1.5) ; exposition du moteur ou de la queue ; décision d'état dans le runtime.

**Risque principal retenu (C §5.4)** : l'interface est orientée snapshot — elle parie que Loom dessine depuis des valeurs. À valider au spike M0 : rendu 120 Hz depuis snapshots sur session en streaming continu. Si le banc dit non, c'est ce design qu'on revoit, pas ses appelants.

**Tests (seams convenus, à confirmer avant le premier test — discipline TDD)** : l'interface publique de `SessionRuntime` + `TerminalSurface` est la surface de test ; `ScriptedPTYHost` et `TestClock` sont les adapters de test ; aucun test ne franchit la queue ni ne touche le moteur.
