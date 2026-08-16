# Loom 分身

Environnement de développement agentique natif macOS : chaque session d'agent CLI
(Claude Code en tête) vit dans un terminal persistant sur son propre worktree Git,
avec détection d'état en temps réel, transcripts continus et historique complet.

Le cahier des charges fait foi : [`cahier-des-charges-loom.md`](cahier-des-charges-loom.md).
Le vocabulaire canonique vit dans [`CONTEXT.md`](CONTEXT.md), les décisions dans
[`docs/adr/`](docs/adr/), les recherches en sources primaires dans [`docs/research/`](docs/research/).

## Démarrer

```sh
swift test        # 95 tests, 17 suites — process réels, repos Git réels, sockets réels
swift run LoomApp
```

Release signée/notariée : `./scripts/release-wizard.sh` (guide interactif, 8 étapes).

## Ce que la v1 sait faire

- **Sessions** : lancement depuis un objectif (UC-1), worktree isolé `loom/<slug>`
  par session, arrêt escaladé SIGINT→SIGTERM→SIGKILL, Reprise après crash sous le
  même identifiant (`claude --resume`, UUID imposé au lancement), archivage,
  historique, recherche FTS5, palette ⌘K.
- **Détection d'état — le différenciateur** : deux canaux fusionnés par une machine
  à états pure (fenêtre de priorité hooks 10 s, hystérésis 2 s, péremption 4 s).
  Canal hooks : `--settings` injecté par session → binaire `loom-hook` → socket
  Unix 0600 → token par session → réducteur. Canal heuristique (agents sans hooks) :
  silence/octets/motifs d'invite/CPU. `needs_input` badge la carte et notifie.
- **Terminal** : SwiftTerm headless confiné à une queue sérielle par session
  (sa doc ment sur la thread-safety — voir ADR-0007), `TerminalSurface` `@Observable`
  dont l'écran n'est jamais vide, transcripts bruts + dé-ANSI-isés en continu,
  rotation 10 Mo.
- **Git** : worktrees avec collisions départagées, status porcelain v2, diff
  (non-suivis compris), suppression refusée si travail non commité.
- **Navigateur** : WKWebView à data store persistant (cookies GitHub conservés),
  UA Safari, LRU d'onglets, historique avec suggestions.
- **Persistance** : GRDB, migrations versionnées (v1→v4), journal des transitions
  avec source, marquage `interrupted` au relancement.
- **Thèmes** : format JSON à deux espaces, résolution en cascade app→projet,
  4 thèmes intégrés, sémantique des badges invariante.

## Architecture

Packages SPM aux frontières imposées (§6.1 du cahier des charges, ADR-0009) :
`LoomCore` (états, réducteur) ← `LoomTerminal` (PTY, moteur, runtime) ·
`LoomAgents` (adapter Claude Code, classification) · `LoomGit` · `LoomWeb` ·
`LoomPersistence` (GRDB, transcripts) · `LoomIPC` (socket hooks) ←
`LoomSessions` (SessionManager, orchestration) ← `LoomApp` (SwiftUI).
Exécutable compagnon : `loom-hook`.

Aucun service ne dépend de l'UI ; l'UI ne voit que des valeurs (`TerminalScreen`),
jamais le moteur. Tout accès moteur est confiné à la queue sérielle de sa session.

## Reste pour une release publique

Étapes humaines : dérouler `scripts/release-wizard.sh` (certificat Developer ID,
notarisation). Techniques : validation visuelle de l'app avec de vraies sessions
Claude Code, banc de rendu 120 Hz (risque assumé de l'ADR-0008), Sparkle,
terminaux secondaires (SES-04), Skills/Rules (SKL, P1), import de thèmes
iTerm/Ghostty (THM-05), tests d'endurance NFR-M.
