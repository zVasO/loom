# Loom

Environnement de développement agentique natif macOS : chaque session d'agent CLI
(Claude Code en tête) vit dans un terminal persistant sur son propre worktree Git,
avec détection d'état en temps réel, transcripts continus et historique complet.

Le cahier des charges fait foi : [`cahier-des-charges-loom.md`](cahier-des-charges-loom.md).
Le vocabulaire canonique vit dans [`CONTEXT.md`](CONTEXT.md), les décisions dans
[`docs/adr/`](docs/adr/), les recherches en sources primaires dans [`docs/research/`](docs/research/).

## Démarrer

```sh
swift build -c release          # construit l'app ET loom-hook (détection d'état)
swift run -c release LoomApp    # IMPORTANT : release — le debug est 10-50× plus lent
                                # sur le rendu terminal (parse par cellule non optimisé)
```

Tests : `swift test` (process réels, repos Git réels, sockets réels).
SDK des extensions et exemple Jira : `cd Examples/extensions && npm test`.
Scripts du navigateur de l'agent : `node --test Tests/AgentBrowserJS/*.test.mjs`
(sur un vrai DOM si Playwright est installé) ; son moteur Chromium sur un vrai
Chromium, par le protocole DevTools : `node --test --test-concurrency=1 Tests/AgentBrowserCDP/*.test.mjs`
(et `LOOM_CHROMIUM=<chrome-headless-shell> swift test` pour les tests Swift de bout en bout) ;
l'app entière : `LOOM_AUTOTEST=agent-browser LOOM_AUTOTEST_ENGINE=chromium|webkit swift run LoomApp`
(rapport et latences p50/p90 dans `/tmp/loom-agent-browser-report.json`).

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
- **Pull requests** : onglet PR sur le `gh` de l'utilisateur — projets locaux,
  orgs du compte (repos ajoutés comme projets en un clic, clone via gh), inbox
  « en attente de moi » tous repos confondus, recherche locale + GitHub, ouverture
  par URL, diff côte à côte, checks CI détaillés, commentaires de ligne mis en
  brouillon et envoyés en une seule review avec le verdict, session claude par PR,
  un onglet par PR ouverte (aperçu réutilisé au clic, épinglé par la review),
  conservés d'un onglet de l'app à l'autre et d'un lancement à l'autre.
- **Navigateur** : WKWebView à data store persistant (cookies GitHub conservés),
  UA Safari, LRU d'onglets, historique avec suggestions. Panneau latéral (⌘⇧B) :
  un navigateur de la pile à côté du terminal de la session, sans jamais
  réduire le terminal sous 80 colonnes de lui-même ni le redimensionner pendant
  un glisser.
- **Navigateur de l'agent** (ADR-0014, ADR-0016) : chaque session claude a son propre
  navigateur, à côté de son terminal, sur un profil isolé par projet (jamais les
  cookies de l'utilisateur ; privé pour les revues) — Chromium sans fenêtre quand
  Loom en trouve un (événements de confiance, pages qui tournent panneau caché,
  panneau interactif), WebKit sinon —, piloté par les outils MCP
  `browser_*` au format de Playwright MCP — naviguer, instantané d'accessibilité à
  références, cliquer, taper, remplir un formulaire, envoyer un fichier, touches,
  attendre, console, requêtes, capture (pleine page comprise), largeur de page,
  JavaScript, dialogues, onglets, scripts Playwright (`browser_run_code`, Chromium) —
  et par `loom browser <outil>`. L'agent ouvre le
  panneau sur son navigateur la première fois qu'il s'en sert. Outils
  pré-autorisés par défaut, coupables dans les Réglages. Guide :
  [`docs/agent-browser.md`](docs/agent-browser.md).
- **Persistance** : GRDB, migrations versionnées (v1→v4), journal des transitions
  avec source, marquage `interrupted` au relancement.
- **Extensions** (ADR-0011) : pages web tierces dans un onglet « Extensions »,
  chacune dans sa vue web isolée (store non persistant, CSP stricte, réseau
  bloqué sauf `loom.http.fetch` vers les hôtes consentis), pont `window.loom`
  gardé par les permissions du manifeste (lecture des sessions et projets,
  lancement toujours confirmé par une feuille native), secrets au Trousseau,
  commandes dans ⌘K ; extensions d'arrière-plan, alarmes natives, statut dans
  la barre du haut et écran de premier plan (ADR-0012). Exemples : un board Jira
  qui démarre une session depuis un ticket (`Examples/extensions/jira-board/`),
  un Pomodoro qui couvre Loom pendant les pauses (`Examples/extensions/pomodoro/`),
  une veille techno dont Claude résume les nouveautés chaque matin
  (`Examples/extensions/tech-watch/`, ADR-0015 : `claude -p` sans outils et
  hôtes accordés à l'usage).
  Guide : [`docs/extensions.md`](docs/extensions.md).
- **Thèmes** : 9 familles intégrées, chacune en clair et en sombre ; apparence
  Système / Clair / Sombre (suivi de macOS en direct) ; override par projet ;
  import d'un thème tweakcn/shadcn (nom, URL ou CSS collé) ; aperçu sur des
  composants factices avec bascule clair/sombre ; sémantique des badges invariante ;
  en option, le thème appliqué à Claude Code lui-même, en direct (ADR-0013).

## Architecture

Packages SPM aux frontières imposées (§6.1 du cahier des charges, ADR-0009) :
`LoomCore` (états, réducteur) ← `LoomTerminal` (PTY, moteur, runtime) ·
`LoomAgents` (adapter Claude Code, classification) · `LoomGit` · `LoomWeb` ·
`LoomPersistence` (GRDB, transcripts) · `LoomAPI` (contrat de l'API agents) ·
`LoomExtensions` (manifeste, permissions et pont des extensions, ADR-0011) ·
`LoomIPC` (socket hooks + requêtes) ←
`LoomSessions` (SessionManager, orchestration) ← `LoomApp` (SwiftUI).
Exécutables compagnons : `loom-hook` (hooks) et `loom` (CLI + serveur MCP de
l'API agents, ADR-0010 ; sa logique vit dans `LoomCLI`). Dans une session,
`loom docs` imprime la référence de l'API ; `loom mcp` la sert en outils MCP,
branché par `--mcp-config` au lancement. Le navigateur de l'agent vit dans
`LoomWeb/AgentBrowser` (ADR-0014) ; son moteur Chromium dans `LoomChromium`
(transport, processus, profils, attente) et `LoomWeb/AgentBrowser/Chromium` (ADR-0016).

Aucun service ne dépend de l'UI ; l'UI ne voit que des valeurs (`TerminalScreen`),
jamais le moteur. Tout accès moteur est confiné à la queue sérielle de sa session.

## Reste pour une release publique

Étapes humaines : dérouler `scripts/release-wizard.sh` (certificat Developer ID,
notarisation). Techniques : validation visuelle de l'app avec de vraies sessions
Claude Code, banc de rendu 120 Hz (risque assumé de l'ADR-0008), Sparkle,
terminaux secondaires (SES-04), Skills/Rules (SKL, P1), import de thèmes
iTerm/Ghostty (THM-05), tests d'endurance NFR-M.
