# Navigateur de l'agent sur Chromium (contrôle ultra rapide)

Date : 2026-10-06 · Statut : validé par l'utilisateur (Chromium pour l'agent, WebKit pour l'utilisateur ; latence par commande d'abord ; écarts au format Playwright MCP en option seulement ; Chromium détecté ou téléchargé sur un clic ; WebKit en repli ; panneau interactif ; `browser_run_code` façon Playwright ; une branche, une PR, CI GitHub Actions)

## But

Que l'agent pilote son navigateur vite et comme un humain le ferait. Ses
retours, par priorité : (1) des pages qui tournent panneau caché, (2) de vrais
événements de saisie, (3) un script qui enchaîne plusieurs actions et des
actions qui ne renvoient pas l'instantané entier, (4) une largeur de page par
projet, (5) Chromium. La mesure du code WebKit donnait la même cause : le temps
venait d'attentes fixes (un clic ≥ 530 ms), pas du moteur.

## Décisions prises

- **Deux moteurs derrière une façade** (`AgentBrowserEngine`) : Chromium sans
  fenêtre piloté par CDP pour l'agent (ADR-0016), WebKit en repli (ADR-0014).
  Les navigateurs « Web n » de l'utilisateur ne changent pas.
- **Moteur figé par session**, à son lancement ou à sa reprise
  (`LOOM_BROWSER_ENGINE` pour `loom mcp`) : la liste des outils et leurs mots en
  dépendent. Réglage Automatique (par défaut), Chromium, WebKit ;
  `LOOM_AGENT_ENGINE` le surcharge.
- **Binaire** : `chrome-headless-shell` (téléchargé par Loom sur un clic, sinon
  celui de Playwright) ; un navigateur complet seulement choisi. Version 120 au
  moins.
- **Transport** : `--remote-debugging-pipe` (fd 3/4, JSON terminé par NUL),
  jamais de port ; `posix_spawn` + `POSIX_SPAWN_CLOEXEC_DEFAULT` sous un
  `SpawnLock` partagé avec `forkpty`.
- **Opt-in seulement** pour ce qui s'écarte de Playwright MCP :
  `snapshot: "none"` sur les 13 outils qui répondent un instantané.
- **Largeur par défaut par projet** (1280 px d'usine), `browser_resize` ne
  change que la session.
- **`browser_run_code`** (Chromium seulement) : `async (page) => {…}` exécuté
  hors de la page testée, dans une cible « runner » hors ligne.
- **Panneau interactif** : screencast + entrées de la personne relayées, l'agent
  passant d'abord.

## Architecture

### LoomChromium (nouveau target — LoomCore ; Foundation, Dispatch, CryptoKit)

Tout ce qui décide, testable sans AppKit :
`CDPFramer`, `CDPMessage`, `CDPConnection` (corrélation, sessions « flatten »,
écritures groupées, trames de screencast routées brutes), `ChromiumSpawn`,
`ChromiumProcess` (sortie, stderr, `Browser.getVersion`, échelle d'arrêt
`Browser.close` → SIGTERM du groupe → SIGKILL), `ChromiumLocator`,
`ChromiumFlags` (trio anti-throttling, `--blink-settings` hover/pointer,
aucun trafic propre ; interdits vérifiés par test), `ChromiumFence` (proxy du
mode sites locaux : accepte et ferme), `ChromiumProfiles`, `ChromiumBrowser`
(session racine, auto-attach, routage), `ChromiumPool` (un processus par profil
de projet, un processus privé partagé avec un contexte par session, lancement
paresseux, arrêt après 60 s d'inactivité), `SettleMachine` + `PageSignals`
(l'attente pilotée par les événements, rejouée sur des traces enregistrées),
`DialogLedger`, `CDPInput`, `MacEditingCommands`, `ChromiumNetError`,
`ScreencastGeometry`, `RunnerFence`, `ChromiumDownload` (épinglage, SHA-256,
`ditto`, installation), et `Panel/` (mappings clavier/souris, raccourcis,
arbitre, coalescence, curseurs).

### LoomWeb/AgentBrowser/Chromium

`ChromiumAgentBrowser` (façade `@MainActor`), `ChromiumAgentCore` (un actor par
session : onglets, file de commandes, délais), `ChromiumTabRuntime` (init d'une
cible en un write : helper dans le monde `loom-agent`, binding de console sans
`Runtime.enable`, interception du sélecteur de fichier, émulation, UA sans
« HeadlessChrome »), `ChromiumHelper`, `ChromiumRunner` +
`ChromiumAgentCore+RunCode`, `ChromiumAgentSurface`, `ScreencastStream`,
`ChromiumPageView` (NSView + NSTextInputClient), `UserInputPump`,
`PanelClipboard`, `SelectMenuBridge`, `ChromiumBrowserPanelView`. Côté JS :
`AgentScripts` (helper partagé avec WebKit, moteur de sélecteurs),
`AgentRunnerScript` (façade Playwright du runner), `AgentPanelScript` (ops du
panneau).

### LoomApp, LoomAPI, LoomCLI

`AppModel.agentEngines` (moteur figé), `ChromiumSetupModel` (téléchargement),
Réglages ▸ Agents (moteur, Chromium trouvé, télécharger/retirer, choisir),
Réglages ▸ Projects (largeur). `APIToolCatalog` par moteur, `isError` dans
`APIToolContent` (MCP `isError`, code de sortie 1 de la CLI).

## Comportement

- **Après une action** : une barrière `setTimeout(0)` dans la page ; si une
  navigation part, le `load` du nouveau document (plafond 10 s, 30 s pour
  navigate ; une navigation jamais commencée est abandonnée après 500 ms) ;
  puis 32 ms de calme sur les XHR/Fetch lancées après la marque (plafond 2 s).
- **Entrées** : l'op `prepare` du helper fait défiler, vérifie la stabilité sur
  une frame et le hit-test ; `mouseMoved`/`Pressed`/`Released` partent en un
  write. Entrée porte `"\r"`. Les touches de l'agent ne portent jamais `copy`,
  `cut` ni `paste` (presse-papiers partagé par processus).
- **Politique des schémas** avant chaque `Page.navigate` (Chromium ouvrirait
  `file:` et exécuterait `javascript:`) ; popups reprises puis fermées quand
  elles sont refusées.
- **Dialogues** : chacun reçoit exactement une réponse ; `beforeunload` accepté
  quand l'agent navigue lui-même.
- **Plantages** : cible ou processus relancés, URLs restaurées, une note ;
  relances plafonnées. Une page bloquée est arrêtée par
  `Runtime.terminateExecution`.
- **`browser_run_code`** : un monde isolé neuf par run ; les appels `page.*`
  passent par un binding vers le cœur, qui les exécute avec ses primitives et
  ses politiques ; actions sérialisées, attentes concurrentes ; 56 s, 1 000
  appels, 32 en vol, 256 Ko par message ; arrêt
  `terminateExecution` → `closeTarget` → `Page.crash`.
- **Panneau** : flux seulement à l'écran ; la page prend le clavier sur un clic
  en elle ; ⌘ réservés (page / panneau / Loom) ; IME par
  `imeSetComposition`/`insertText` ; coller par événement `paste` puis
  `Input.insertText` ; `<select>` en `NSMenu` ; curseur échantillonné ; l'agent
  passe d'abord (prise de main annoncée au fil principal sans l'attendre, compteur
  `control.isBusy` lu entre-temps), une note par intervalle dans `### Events`.

## Gestion des erreurs

- `net::ERR_*` traduits dans les messages de WebKit (« nothing is listening on
  … ») ; un refus du mode sites locaux est toujours dit comme tel.
- Chromium trop ancien, profil tenu par un orphelin (un balayage puis un nouvel
  essai), proxy du mode local qui ne démarre pas (aucun lancement) : erreurs
  nommées, dites dans le panneau.
- Téléchargement : taille ou SHA-256 différents ⇒ rien n'est installé ; annulation,
  réseau, disque : un message, un nouvel essai possible.
- `run_code` : `### Error` en tête, ligne du script de l'agent, mots de
  Playwright (`TimeoutError`, strict mode), résultat marqué en erreur.

## Tests

- **Swift** (`swift test`, CI macOS) : chaque type de LoomChromium, le cœur sur un
  faux pair CDP, les traces enregistrées, la pompe d'entrées sur 29 séquences de
  référence, le téléchargement sur des dossiers jetables ; avec
  `LOOM_CHROMIUM`, le pool et une session de bout en bout sur un vrai
  `chrome-headless-shell` (navigate, click, type, instantané, `isTrusted`,
  `run_code`).
- **Node, sur un vrai Chromium** : `Tests/AgentBrowserJS` (helper, sélecteurs
  comparés aux locators de Playwright, façade du runner) ;
  `Tests/AgentBrowserCDP` (lancement sans port, init des cibles, pages en
  arrière-plan, clic, touches, course des dialogues, attente, latence, captures,
  largeur, sondes de fuite du mode local, politique des schémas, plantages,
  `run_code` et sa barrière réseau, entrées du panneau).
- **Auto-test** de l'app (`LOOM_AUTOTEST=agent-browser`, job CI manuel, deux
  moteurs) : les étapes de l'ADR-0014 plus `isTrusted`, `:hover`, animations
  sans fenêtre, latences p50/p90.

### Validation sur le Mac

- Réglages : télécharger `chrome-headless-shell` (progression, annuler, SHA
  faux simulé, hors ligne), « Remove » refusé tant qu'un agent l'utilise.
- `kill -9` de Loom : Chromium s'arrête ; `lsof` : aucun port ouvert ; aucune
  icône dans le Dock ; `nettop` à zéro sur `about:blank`.
- Panneau : IME et touches mortes d'un clavier français ; ⌘C/⌘V avec d'autres
  apps ; se connecter à une app de dev ; un clic sur un panneau vide garde le
  clavier au terminal ; ⌘N ⌘T ⌘K ⌘W restent à Loom ; ⌃Tab ressort ; un
  `<select>` ouvre un menu Mac ; une commande de l'agent pendant un glisser
  relâche le bouton.
- VoiceOver : la vue est annoncée, la pastille et le bandeau restent lisibles.
- Mémoire et énergie d'un processus par projet face à NFR-M.

## Hors périmètre

Glisser-déposer HTML natif et dépôt de fichiers dans le panneau, collage riche,
menu contextuel de Loom, vue « texte de la page » pour VoiceOver, outils de
développement pour la personne, plusieurs vues d'un même onglet avec une vue
primaire, mode 2× net du panneau.

## Suites

- Rejouer les séquences de référence sur le Chromium de la CI macOS et lire la
  ligne « T-clip » (Chromium écrit-il dans le presse-papiers du Mac ?).
- Mesurer les latences sur un Mac (cible : clic sans instantané p50 ≤ 40 ms).
