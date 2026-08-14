# Cahier des charges technique — **Bunshin**
## Environnement de développement agentique natif macOS

**Version** : 1.2 — Août 2026
**Statut** : Draft pour validation
**Destinataires** : Équipe de développement

> **Nom** : *Bunshin* (分身, « double de soi ») — référence au Kage Bunshin no Jutsu de *Naruto* : des clones qui travaillent en parallèle et dont l'expérience revient à l'original. Mot japonais générique, sans dépôt de franchise sur le terme lui-même ; vérification INPI/EUIPO (classes 9 et 42) et disponibilité des domaines (`bunshin.app`, `getbunshin.com`) à effectuer avant communication publique.

---

## 1. Contexte et vision

Les développeurs utilisant des agents de codage IA en CLI (Claude Code, Codex, Gemini CLI) mènent aujourd'hui plusieurs sessions d'agents en parallèle, chacune dans un onglet de terminal distinct, sans vue d'ensemble : impossible de savoir d'un coup d'œil quelle session travaille, laquelle attend une réponse, laquelle a terminé. Le contexte se perd entre les sessions, les branches Git se marchent dessus, et l'historique des sessions passées disparaît à la fermeture du terminal.

**Bunshin** est une application macOS native qui orchestre ces sessions d'agents : elle organise le travail par projet, exécute chaque session dans un terminal persistant isolé sur son propre worktree Git, détecte l'état de chaque agent en temps réel, conserve l'historique complet des sessions, et intègre un navigateur web avec sessions persistantes pour les tâches connexes (GitHub, documentation, back-offices).

L'application est mono-utilisateur, locale, sans backend distant. Elle ne remplace pas les agents CLI : elle les héberge et les orchestre. L'authentification et la configuration de chaque agent restent gérées par leur CLI natif.

**Principes directeurs** : fluidité native irréprochable (120 Hz ProMotion), esthétique macOS moderne sombre, zéro configuration pour démarrer, robustesse des sessions (une session ne doit jamais être perdue par accident).

---

## 2. Périmètre

### 2.1 Inclus dans la v1

Le périmètre v1 couvre : la gestion de projets locaux (dossiers Git), le cycle de vie complet des sessions d'agents (création, exécution, suivi d'état, archivage, historique), l'émulation de terminal intégrée avec sessions persistantes pendant la durée de vie de l'application, la création et gestion automatique de worktrees Git par session, la détection d'état des agents (working / needs input / idle / done / failed) avec priorité au support de Claude Code via ses hooks, un navigateur web intégré (WKWebView) avec persistance des cookies et sessions entre les lancements, un panneau Git par session (status, diff, commit log), les notifications système, une palette de commandes (⌘K), et la persistance locale de toutes les données (projets, sessions, transcripts).

### 2.2 Exclus de la v1 (envisagé v2+)

Sont explicitement hors périmètre v1 : tout backend cloud ou synchronisation multi-machines, le partage de sessions entre utilisateurs, l'équivalent de Spotify Portal (catalogue de services, contexte organisationnel), la survie des sessions au-delà du cycle de vie de l'application (redémarrage app ou machine — voir §6.4 pour la stratégie de reprise), le support Windows/Linux, un système de plugins tiers, la facturation/télémétrie, et l'édition de code intégrée (l'app affiche des diffs, elle n'est pas un éditeur).

### 2.3 Contraintes imposées

L'application est développée en Swift (SwiftUI + AppKit), cible macOS 14 Sonoma minimum (macOS 15 recommandé), architecture Apple Silicon prioritaire (build universel accepté), distribution hors Mac App Store (Developer ID + notarisation) pour conserver la liberté sur les process enfants et le système de fichiers.

---

## 3. Utilisateurs et cas d'usage de référence

**Persona principal** : développeur solo ou en petite équipe, technophile, utilisateur quotidien de Claude Code, menant 2 à 10 sessions d'agents en parallèle sur 1 à 5 projets.

Les cas d'usage nominaux qui doivent être parfaitement fluides sont les suivants. **UC-1 — Lancer une tâche** : depuis un projet, l'utilisateur décrit un objectif dans un champ de saisie, l'app crée un worktree, ouvre une session Claude Code avec le prompt initial, et affiche la carte de session en état « working ». **UC-2 — Superviser** : depuis la vue Sessions, l'utilisateur voit toutes ses sessions groupées par projet avec leur état en temps réel ; un badge signale les sessions qui attendent une intervention. **UC-3 — Intervenir** : l'utilisateur clique sur une carte, le terminal s'ouvre en plein écran avec une transition animée, il répond à l'agent, revient à la vue d'ensemble ; la session continue en arrière-plan. **UC-4 — Consulter le travail** : pour une session donnée, l'utilisateur consulte le diff Git du worktree, les fichiers modifiés, et le transcript. **UC-5 — Naviguer sur le web** : l'utilisateur ouvre le navigateur intégré (globalement ou dans le contexte d'une session), il est déjà connecté à GitHub car les cookies persistent entre les lancements. **UC-6 — Clôturer** : l'utilisateur archive une session terminée ; le transcript et les métadonnées restent consultables dans l'historique ; le worktree peut être conservé, mergé ou supprimé. **UC-7 — Reprendre après redémarrage** : au relancement de l'app, les sessions actives sont proposées à la reprise (`claude --resume` / `--continue`), l'historique est intact.

---

## 4. Exigences fonctionnelles

Chaque exigence est identifiée (préfixe par domaine), avec priorité **P0** (bloquant v1), **P1** (v1 souhaité), **P2** (v1.x).

### 4.1 Projets (PRJ)

| ID | Exigence | Priorité |
|---|---|---|
| PRJ-01 | Créer un projet en pointant un dossier local ; si le dossier est un repo Git, détection automatique (branche par défaut, remotes, état). | P0 |
| PRJ-02 | Vue projet avec onglets : Overview (sessions actives + champ de lancement rapide), Git (branches, worktrees, commits récents), Files (arborescence en lecture), Skills et Rules (voir §4.10). | P0 (Skills/Rules P1) |
| PRJ-03 | Sidebar listant les projets, réordonnables par drag & drop, avec compteur de sessions actives par projet. | P0 |
| PRJ-04 | Champ « quick start » : saisie d'un objectif → création de session pré-remplie (choix agent, branche de base, worktree auto). Support du collage d'une URL de ticket (simple stockage en métadonnée en v1). | P0 |
| PRJ-05 | Sessions « générales » sans projet (répertoire de travail arbitraire ou temporaire). | P1 |
| PRJ-06 | Suppression/archivage d'un projet sans toucher au dossier source (l'app ne détruit jamais de données utilisateur hors de ses worktrees). | P0 |

### 4.2 Sessions (SES)

Une **session** est l'unité centrale : un agent CLI donné, exécuté dans un PTY, attaché à un répertoire de travail (worktree ou dossier du projet), avec un cycle de vie et un transcript.

| ID | Exigence | Priorité |
|---|---|---|
| SES-01 | Cycle de vie : `draft → starting → working → needs_input → idle → completed / failed → archived`. Toutes les transitions sont horodatées et journalisées. | P0 |
| SES-02 | Création d'une session avec : titre (généré depuis le prompt si absent), agent (Claude Code en P0 ; Codex, Gemini CLI en P1), projet, branche de base, stratégie worktree (nouveau worktree / dossier du projet / worktree existant), prompt initial optionnel, variables d'environnement additionnelles. | P0 |
| SES-03 | Vue « Sessions » globale : cartes groupées par projet, affichant titre, état (badge coloré + animation subtile pour `working`), branche, durée, agent, aperçu de la dernière sortie. Tri par activité ou récence, regroupement configurable, vue grille et vue liste. | P0 |
| SES-04 | Plusieurs terminaux par session (ex. « Term 2 » pour lancer des commandes à côté de l'agent, dans le même worktree). Le terminal principal héberge l'agent ; les terminaux secondaires sont des shells libres. | P1 |
| SES-05 | Actions sur carte : ouvrir, envoyer un message rapide sans ouvrir le terminal (P1), renommer, archiver, dupliquer la configuration, ouvrir le worktree dans le Finder/l'éditeur externe. | P0 (message rapide P1) |
| SES-06 | Arrêt d'une session : SIGINT gracieux à l'agent, puis SIGTERM au groupe de process après délai (5 s), puis SIGKILL. Confirmation utilisateur si l'agent est en état `working`. | P0 |
| SES-07 | Historique : les sessions `completed`/`archived` restent listées (section dédiée), avec transcript complet consultable, métadonnées, et lien vers la branche/worktree si conservé. | P0 |
| SES-08 | Recherche plein texte dans les titres et transcripts (index SQLite FTS5). | P1 |
| SES-09 | Limite de garde-fou configurable sur le nombre de sessions simultanées (défaut : 12) avec avertissement au-delà. | P1 |

### 4.3 Terminal (TRM)

| ID | Exigence | Priorité |
|---|---|---|
| TRM-01 | Émulation de terminal complète via **SwiftTerm** (xterm-256color, truecolor, UTF-8, curseur, sélection, copier-coller, liens cliquables). Le moteur est isolé derrière un protocole `TerminalEngine` (voir §6.2) pour permettre une migration ultérieure (libghostty). | P0 |
| TRM-02 | Chaque session possède son PTY (`forkpty`), le process agent est lancé dans un **process group dédié** afin que les signaux atteignent tous les descendants. Redimensionnement PTY synchronisé avec la vue (`TIOCSWINSZ`). | P0 |
| TRM-03 | Les sessions restent vivantes quand leur vue n'est pas affichée : la lecture du PTY continue, la sortie alimente l'état du terminal et le transcript en arrière-plan. Réattacher une vue restaure l'écran instantanément (< 100 ms). | P0 |
| TRM-04 | **Throttling du rendu** : coalescence des chunks PTY, rendu au plus au rythme de l'écran (CADisplayLink / CVDisplayLink, 60–120 Hz), jamais de rendu par chunk. Objectif : aucune saccade de scroll pendant qu'un agent stream du texte. | P0 |
| TRM-05 | Scrollback : 10 000 lignes en mémoire par session visible ; les sessions non visibles peuvent réduire leur empreinte (voir NFR). Le transcript intégral est de toute façon écrit sur disque en continu (§4.7). | P0 |
| TRM-06 | Personnalisation : le rendu terminal consomme l'espace *Terminal* du thème résolu (voir §4.9) ; police (défaut : SF Mono ou JetBrains Mono embarquée sous licence), taille, ligatures (P2). | P1 |
| TRM-07 | Entrée clavier complète (modificateurs, séquences xterm), IME, et raccourcis app non conflictuels avec le terminal (stratégie : ⌘ réservé à l'app, tout le reste transmis au PTY). | P0 |
| TRM-08 | Barre d'état par session (visible dans la vue terminal) : agent et version, durée, compteur de tokens/contexte si l'agent l'expose (parsing de la status line Claude Code), branche. | P1 |

### 4.4 Détection d'état des agents (STA)

C'est le différenciateur produit : la fiabilité de `working` / `needs_input` / `done` conditionne toute la valeur de la vue d'ensemble.

| ID | Exigence | Priorité |
|---|---|---|
| STA-01 | **Canal privilégié — hooks Claude Code** : à la création d'une session Claude Code, l'app injecte (via settings du worktree ou flag `--settings`) des hooks `Notification`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit` qui notifient l'app via un **socket Unix** local (`~/Library/Application Support/Bunshin/bunshin.sock`) avec un payload JSON signé par un token de session. L'app n'écrit jamais dans les settings globaux de l'utilisateur sans consentement. | P0 |
| STA-02 | **Canal de repli — heuristiques PTY** (pour agents sans hooks, ou en cas de défaillance des hooks) : détection combinée par silence du flux de sortie (fenêtre glissante), motifs de prompt en fin d'écran (regex par agent, configurables), et activité CPU du process group (via `proc_pid_rusage`). Une machine à états lisse les faux positifs (hystérésis ≥ 2 s). | P0 |
| STA-03 | Priorité des signaux : hook > heuristique. Un état issu d'un hook n'est jamais écrasé par une heuristique dans les 10 s qui suivent. | P0 |
| STA-04 | `needs_input` déclenche : badge sur la carte, badge du Dock, notification système (configurable, avec regroupement pour éviter le spam), et son optionnel. Clic sur la notification → ouvre la session. | P0 |
| STA-05 | Détection de fin de process (waitpid sur le PTY) → `completed` (exit 0) ou `failed` (exit ≠ 0), avec code de sortie stocké. | P0 |
| STA-06 | Journal de diagnostic des transitions d'état par session (visible dans un panneau debug), pour itérer sur les heuristiques. | P1 |

### 4.5 Git et worktrees (GIT)

| ID | Exigence | Priorité |
|---|---|---|
| GIT-01 | Création automatique d'un worktree par session : `git worktree add <racine>/worktrees/<slug-session> -b <branche>` ; racine par défaut : `<repo>/.bunshin/worktrees/` (gitignorée automatiquement) ou dossier sibling `<repo>-worktrees/`, configurable. Nettoyage du `.git/worktrees` orphelin au démarrage (`git worktree prune`). | P0 |
| GIT-02 | Nommage de branche templatisé : `bunshin/<slug>` par défaut, configurable par projet. Vérification des collisions. | P0 |
| GIT-03 | Panneau Git par session : fichiers modifiés (status porcelain v2), diff unifié avec coloration syntaxique (lecture seule), commits de la branche. Rafraîchi par FSEvents sur le worktree + polling de secours (5 s). | P0 |
| GIT-04 | Actions v1 : commit (message saisi), push, ouverture d'une PR via l'URL GitHub pré-remplie (pas d'API GitHub en v1 — le navigateur intégré prend le relais). Merge/rebase : hors périmètre v1, l'utilisateur utilise son outil habituel. | P1 |
| GIT-05 | Gestion des worktrees au niveau projet : liste, statut (sessions associées, divergence avec la branche par défaut), suppression sécurisée (refus si modifications non commit, avec option force explicite). | P0 |
| GIT-06 | Implémentation : shell out vers le binaire `git` de l'utilisateur (PATH résolu depuis le shell de login), pas de libgit2 en v1 (compatibilité maximale avec les configs utilisateur : hooks, credentials helpers, SSH). Toutes les commandes sont journalisées. | P0 |

### 4.6 Navigateur intégré (WEB)

| ID | Exigence | Priorité |
|---|---|---|
| WEB-01 | Navigateur basé **WKWebView** : barre d'adresse avec suggestion depuis l'historique, back/forward, reload, ouverture dans le navigateur système, copie d'URL. | P0 |
| WEB-02 | **Persistance des sessions web** : `WKWebsiteDataStore` persistant partagé par toute l'app (cookies, localStorage, IndexedDB) survivant aux relances — l'utilisateur connecté à GitHub le reste. Profils multiples via data stores identifiés : P2. | P0 |
| WEB-03 | Onglets navigateur au niveau app (fenêtre/panneau navigateur global) et ouverture contextuelle depuis une session (ex. lien cliqué dans le terminal → choix « navigateur intégré / navigateur système », mémorisable). | P1 |
| WEB-04 | User-agent Safari standard configuré (`customUserAgent`) pour éviter les blocages OAuth ; les flux d'authentification qui refusent les webviews basculent vers `ASWebAuthenticationSession` ou le navigateur système. | P0 |
| WEB-05 | Hygiène mémoire : au plus N webviews vivantes (défaut 4, LRU) ; les onglets au-delà sont suspendus (URL + scroll conservés, rechargés à l'affichage — la session cookie garantit la continuité de connexion). | P0 |
| WEB-06 | Téléchargements gérés (WKDownloadDelegate) vers ~/Downloads avec notification. | P1 |
| WEB-07 | Aucune injection de script dans les pages, aucune interception de contenu au-delà des besoins de navigation. Les données du data store ne quittent jamais la machine. | P0 |

### 4.7 Transcripts et données (DAT)

| ID | Exigence | Priorité |
|---|---|---|
| DAT-01 | Transcript intégral de chaque terminal écrit en continu sur disque (flux brut + version nettoyée des séquences ANSI pour la recherche), rotation par fichiers de 10 Mo. Localisation : `~/Library/Application Support/Bunshin/transcripts/<session-id>/`. | P0 |
| DAT-02 | Base locale **SQLite via GRDB** : projets, sessions, transitions d'état, worktrees, historique navigateur, préférences. Migrations versionnées dès la v1. (Choix GRDB plutôt que SwiftData : contrôle des migrations, FTS5, accès concurrent depuis les services background.) | P0 |
| DAT-03 | Export d'une session : Markdown (transcript nettoyé + métadonnées + diff final). | P2 |
| DAT-04 | Aucune télémétrie. Logs applicatifs locaux (OSLog + fichier exportable pour support). | P0 |

### 4.8 Navigation, UI globale (UIX)

| ID | Exigence | Priorité |
|---|---|---|
| UIX-01 | Structure : barre de navigation supérieure (Projects / Sessions / bouton +), sidebar contextuelle, zone de contenu. Vue Sessions = hub par défaut au lancement. | P0 |
| UIX-02 | **Palette de commandes ⌘K** : navigation vers tout projet/session, actions (nouvelle session, archiver, ouvrir navigateur…), fuzzy matching. | P1 |
| UIX-03 | Transitions animées carte ↔ plein écran (zoom/matched geometry), 120 Hz, interruptibles. Aucune animation > 300 ms sur le chemin critique. | P0 |
| UIX-04 | Raccourcis globaux : ⌘1..9 (sessions récentes), ⌘T (nouveau terminal dans la session), ⌘L (focus barre d'adresse navigateur), ⇧⌘A (archiver). Personnalisation P2. | P1 |
| UIX-05 | Mode sombre natif (défaut) et clair, matériaux système (NSVisualEffectView), respect des réglages d'accessibilité (Reduce Motion, contraste augmenté, Dynamic Type dans les limites d'AppKit). | P0 (accessibilité complète P1) |
| UIX-06 | État vide soigné (onboarding : choisir un dossier, vérifier la présence de Claude Code dans le PATH avec diagnostic guidé). | P0 |

### 4.9 Thèmes et personnalisation visuelle (THM)

Le système de thèmes repose sur une **résolution en cascade** : thème de l'app → override par projet → (héritage par les sessions du projet). Une session affiche toujours le thème résolu de son projet, ce qui donne un repère visuel immédiat : « je suis dans quel projet ? » se lit à la couleur.

| ID | Exigence | Priorité |
|---|---|---|
| THM-01 | **Thème global de l'app** sélectionnable dans les préférences : thèmes intégrés (≥ 4 au lancement : sombre par défaut, sombre chaud, clair, contraste élevé) + thèmes utilisateur. Application instantanée, sans redémarrage, animée (cross-fade ≤ 200 ms, désactivé si Reduce Motion). | P0 |
| THM-02 | **Override par projet** : dans les réglages d'un projet, choix « Hériter du thème global » (défaut) ou sélection d'un thème spécifique. Le thème projet s'applique à : la teinte d'accent des cartes de session du projet, l'en-tête de la vue projet, la vue terminal des sessions du projet (fond, palette ANSI), et la sidebar (pastille de couleur du projet). | P0 |
| THM-03 | Granularité de l'override : l'override projet peut être **complet** (thème entier) ou **accent seul** (juste la couleur d'accent sur le thème global) — ce second mode est le plus courant et doit être le chemin rapide (color picker directement dans les réglages projet). | P1 |
| THM-04 | **Définition d'un thème** : fichier JSON versionné (`schemaVersion`) couvrant deux espaces : *UI* (fond, surfaces, accent, couleurs sémantiques des états de session, texte primaire/secondaire) et *Terminal* (fond, premier plan, curseur, sélection, palette ANSI 16 couleurs + brights). Un thème peut ne définir que l'un des deux espaces (fusion avec le thème parent pour le reste). | P0 |
| THM-05 | **Import de thèmes terminal** aux formats iTerm2 (`.itermcolors`) et Ghostty (fichier de config), mappés vers l'espace *Terminal* du format Bunshin. Export au format Bunshin JSON. | P1 |
| THM-06 | **Éditeur de thème intégré** : duplication d'un thème existant puis édition des couleurs avec prévisualisation live (échantillon d'UI + terminal factice affichant la palette ANSI). Sauvegarde dans `~/Library/Application Support/Bunshin/themes/`. | P1 |
| THM-07 | Clair/sombre : un thème déclare sa `appearance` (dark/light) ; un réglage « Suivre le système » permet d'associer une **paire** de thèmes (un clair, un sombre) basculée automatiquement avec l'apparence macOS, y compris pour les overrides projet. | P1 |
| THM-08 | Résolution et cohérence : la résolution du thème est centralisée (un seul `ThemeResolver`), aucune vue ne lit une couleur en dur ; les badges d'état de session (working/needs input/…) conservent leur **sémantique** dans tous les thèmes (les thèmes ajustent la teinte, pas le sens — un thème ne peut pas rendre `failed` vert). Vérification de contraste minimal (WCAG AA sur texte primaire) avec avertissement dans l'éditeur. | P0 |
| THM-09 | Les webviews ne sont pas thémées (contenu web intact) ; seul le chrome du navigateur (barre d'adresse, onglets) suit le thème. | P0 |

### 4.10 Skills et Rules (SKL)

L'app expose une interface de consultation et de gestion des **skills** (dossiers d'instructions réutilisables par les agents) et des **rules** (fichiers d'instructions injectés en contexte, type `CLAUDE.md`), aux deux portées : **globale** (niveau utilisateur) et **projet**. Principe fondateur : **le système de fichiers est la source de vérité** — l'app lit et écrit les emplacements natifs des agents, elle ne maintient aucune copie en base (seul un index de recherche est dérivé). Tout changement fait hors de l'app (éditeur, git pull) est reflété en direct via FSEvents.

Emplacements scannés en v1 (conventions Claude Code, abstraites derrière `AgentAdapter` pour extension future) : skills globaux `~/.claude/skills/*/SKILL.md`, skills projet `<repo>/.claude/skills/*/SKILL.md`, rules globales `~/.claude/CLAUDE.md`, rules projet `<repo>/CLAUDE.md` et `<repo>/.claude/**` pertinents. Les adaptateurs Codex/Gemini mappent leurs équivalents (`AGENTS.md`, `GEMINI.md`) en P2.

| ID | Exigence | Priorité |
|---|---|---|
| SKL-01 | **Onglet Skills** dans la vue projet : grille de cartes (nom, description extraite du frontmatter YAML de `SKILL.md`, badge de portée `global`/`project`), avec filtres **All / Global / Project** et compteurs, comme la référence visuelle. Recherche texte locale. | P1 |
| SKL-02 | Parsing du frontmatter (`name`, `description`) avec repli gracieux : un `SKILL.md` mal formé apparaît quand même (nom = dossier, badge d'avertissement + raison), jamais d'écran vide silencieux. | P1 |
| SKL-03 | **Shadowing** : quand un skill projet porte le même nom qu'un skill global, les deux cartes sont affichées et liées visuellement, avec mention « override le skill global » sur la version projet (comportement effectif de Claude Code : le projet prime). Un indicateur signale les paires divergentes. | P1 |
| SKL-04 | Détail d'un skill : vue lecture du `SKILL.md` (rendu Markdown), liste des fichiers annexes du dossier skill, chemin sur disque, actions : ouvrir dans le Finder, ouvrir dans l'éditeur externe, copier le chemin. | P1 |
| SKL-05 | Actions de gestion : créer un skill (template `SKILL.md` avec frontmatter pré-rempli, choix de la portée), dupliquer un skill global vers le projet (base d'un override), renommer, supprimer (corbeille système, jamais de `rm` définitif). Édition intégrée du Markdown : P2 (v1 : éditeur externe). | P1 (édition intégrée P2) |
| SKL-06 | **Onglet Rules** : liste des fichiers de rules détectés aux deux portées, avec aperçu rendu, taille, date de modification, et indication de la **chaîne effective** (ordre dans lequel l'agent les charge : global puis projet). Création depuis template si absent. Édition intégrée : P2. | P1 |
| SKL-07 | Rafraîchissement live : FSEvents sur les répertoires scannés (globaux + projet ouvert), debounce 500 ms ; aucun redémarrage ni action manuelle nécessaire pour voir un skill ajouté à la main. | P1 |
| SKL-08 | Sessions : à la création d'une session, un panneau optionnel (replié par défaut) montre les skills/rules qui seront visibles par l'agent dans ce worktree — les worktrees étant des checkouts complets, les skills projet y sont naturellement présents ; l'app vérifie et signale toute anomalie (ex. `.claude/` gitignoré donc absent du worktree). | P1 |
| SKL-09 | Sécurité : l'app n'exécute jamais le contenu des skills ; elle les affiche et les gère comme des documents. Les écritures restent confinées aux emplacements listés ci-dessus. | P0 |

---

## 5. Exigences non fonctionnelles

**Performance (NFR-P)** : lancement à froid < 1,5 s jusqu'à l'affichage du hub ; réattachement d'une session < 100 ms ; saisie clavier → écho terminal < 16 ms de latence ajoutée par l'app ; scroll et animations sans frame drop à 120 Hz sur Apple Silicon avec 8 sessions actives dont 3 en streaming continu ; débit terminal soutenu ≥ 20 Mo/s de sortie sans gel de l'UI (le parsing tourne hors main thread).

**Mémoire (NFR-M)** : cible < 400 Mo avec 8 sessions actives et 2 webviews (hors process agents, qui appartiennent à l'utilisateur) ; scrollback des sessions non visibles compacté ; pas de fuite sur créer/détruire 100 sessions (vérifié en CI par test d'endurance).

**Robustesse (NFR-R)** : un crash de l'UI ne doit pas tuer les agents sans tentative de sauvegarde du transcript (les writers de transcript sont dans un service découplé de la couche vue) ; toute écriture disque est atomique ; l'app se relance proprement après kill -9 (base cohérente, sessions marquées `interrupted` avec proposition de reprise via `--resume`).

**Sécurité et confidentialité (NFR-S)** : app **non sandboxée** (requis pour forkpty, git, accès worktrees) mais Hardened Runtime activé, Developer ID + notarisation ; le socket Unix des hooks est en permissions 0600 avec token par session ; aucune donnée n'est transmise à un serveur tiers par l'app elle-même ; les secrets (tokens web) restent dans le data store WebKit et le Keychain système.

**Compatibilité (NFR-C)** : macOS 14+, Apple Silicon natif ; agents supportés v1 : Claude Code (support complet hooks), Codex CLI et Gemini CLI (support générique heuristique) ; git ≥ 2.39.

---

## 6. Architecture technique

### 6.1 Vue d'ensemble

Application Swift unique, découpée en packages SPM pour imposer les frontières :

```
BunshinApp (target app, SwiftUI + AppKit)
├── BunshinUI            — vues, design system (tokens), ThemeResolver, transitions
├── BunshinCore          — modèle métier, SessionManager, machine à états
├── BunshinTerminal      — protocole TerminalEngine + implémentation SwiftTerm + PTY
├── BunshinAgents        — adaptateurs par agent (ClaudeCodeAdapter, GenericAdapter),
│                          SkillsService (scan skills/rules, FSEvents, frontmatter)
├── BunshinGit           — GitService (worktrees, status, diff)
├── BunshinWeb           — BrowserService (WKWebView pool, data store, historique)
├── BunshinPersistence   — GRDB, migrations, TranscriptWriter, FTS
└── BunshinIPC           — serveur socket Unix pour les hooks
```

Le pattern général est **services acteurs (Swift Concurrency) + état observable** : chaque service est un `actor` ; la couche UI observe des projections `@Observable` mises à jour sur le MainActor. Aucun service ne dépend de la couche UI.

### 6.2 Contrats clés

```swift
protocol TerminalEngine: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    var screenSnapshot: TerminalScreen { get }   // réattachement instantané
    var delegate: TerminalEngineDelegate? { get set }
}

protocol AgentAdapter {
    var id: AgentID { get }                       // .claudeCode, .codex, .gemini
    func launchCommand(for spec: SessionSpec) -> Command   // binaire, args, env
    func installHooks(in worktree: URL, socket: URL, token: String) throws -> HookInstallation?
    func interpret(hookPayload: Data) -> AgentEvent?       // → machine à états
    var promptHeuristics: PromptHeuristics { get }         // regex fin d'écran, etc.
    func resumeCommand(for session: SessionRecord) -> Command?  // claude --resume
    func skillLocations(project: URL?) -> [ScopedLocation]      // §4.10 : global + projet
    func ruleLocations(project: URL?) -> [ScopedLocation]       // CLAUDE.md, AGENTS.md…
}
```

`SessionManager` (actor central) orchestre : création (GitService → worktree, AgentAdapter → commande, PTYHost → fork), routage des événements (PTY bytes → TerminalEngine + TranscriptWriter ; hooks IPC → StateEngine), transitions d'état, arrêts, reprise au lancement.

`StateEngine` : machine à états par session, fusionnant événements hooks (prioritaires) et heuristiques (repli), avec hystérésis et journal.

### 6.3 Flux de données terminal (chemin chaud)

```
PTY fd ──read loop (DispatchIO, hors main)──▶ ring buffer
   ├──▶ TranscriptWriter (append fichier, batché 250 ms)
   ├──▶ TerminalEngine.feed() (thread parsing dédié)
   └──▶ StateEngine (échantillonné)
TerminalEngine ──dirty regions──▶ coalesceur ──CVDisplayLink──▶ rendu vue (main)
```

Règles : jamais de travail par-chunk sur le main thread ; le rendu tire l'état, il n'est pas poussé ; les sessions non visibles ne déclenchent aucun rendu (mais parsing et transcript continuent).

### 6.4 Persistance des sessions et reprise

En v1, les PTY sont des enfants de l'app : ils meurent avec elle. La stratégie de continuité est donc : (1) transcript et état sauvés en continu, (2) à la fermeture normale, dialogue si des sessions sont `working` (arrêt gracieux des agents), (3) au relancement, sessions `interrupted` listées avec action « Reprendre » qui relance l'agent via son mécanisme natif (`claude --resume <session>` — l'ID de session Claude Code est capturé au lancement via hook `SessionStart`). Un backend tmux optionnel offrant la vraie persistance est architecturé comme une seconde implémentation de `PTYHost` et planifié v2.

### 6.5 Schéma de données (extrait GRDB)

```
project(id, name, path, defaultBranch, worktreeRoot,
        themeOverrideId?, accentOverride?, createdAt, archivedAt)
theme(id, name, kind(builtin|user|imported), appearance(dark|light),
      pairedThemeId?, json, schemaVersion, createdAt, updatedAt)
session(id, projectId?, title, agentId, state, branch, worktreePath?,
        initialPrompt, agentNativeSessionId?, exitCode?, createdAt,
        startedAt?, endedAt?, archivedAt?, lastActivityAt)
state_transition(id, sessionId, fromState, toState, source(hook|heuristic|process|user), at)
terminal(id, sessionId, kind(agent|shell), transcriptPath, createdAt)
web_history(id, url, title, visitedAt)
settings(key, value)
+ FTS5: session_fts(title, transcriptPlainText)
```

### 6.6 IPC hooks

Serveur socket Unix (SwiftNIO ou NWListener) ; payload JSON ligne par ligne : `{token, sessionId, event, data}` ; token vérifié contre la table des sessions actives ; commande hook installée = petit script sh généré par l'app (`printf ... | nc -U`) ou binaire helper embarqué (préféré : binaire `bunshin-hook` copié dans Application Support, appelé par les hooks avec les données en stdin — plus robuste que nc).

---

## 7. Spécifications UI/UX

**Design system** : entièrement construit sur des **design tokens** résolus par le système de thèmes (§4.9) — aucune couleur en dur dans les vues. Le thème par défaut : sombre, fond profond (#0B0B0F environ), surfaces élevées par matériaux (`.ultraThinMaterial` sur fond teinté), accent orange type screenshot, coins 10–12 pt, ombres discrètes. Typographie : SF Pro pour l'UI, mono embarquée pour terminal et éléments code. Badges d'état : vert pulsé (`working`), ambre (`needs_input`), bleu (`idle`), gris (`completed`), rouge (`failed`) par défaut — teintes ajustables par thème, sémantique invariante (THM-08), pulsation respectant Reduce Motion. Les cartes de session portent la couleur d'accent résolue de leur projet, ce qui rend la vue Sessions multi-projets lisible sans lire les titres.

**Composants clés** : carte de session (état, titre, branche, durée, aperçu dernière ligne, actions au survol), grille/liste avec regroupement, vue terminal plein contenu avec barre d'outils contextuelle (onglets terminaux de la session, Git, Files, navigateur, Stop), panneau Git en overlay latéral, navigateur en panneau ou fenêtre séparée (fenêtres multiples supportées via `WindowGroup`).

**Micro-interactions** : transition carte→terminal en zoom (matched geometry), apparition des cartes en spring léger, feedback haptique sur trackpad pour les actions destructives, compteur de sessions `needs_input` sur l'icône Dock.

Les maquettes détaillées (Figma) sont livrables du jalon M0 ; le présent document fait foi pour la structure et les états.

---

## 8. Plan de développement

**M0 — Fondations (2 sem.)** : setup projet SPM, CI (GitHub Actions, runners macOS), design system **tokenisé dès le premier écran** (ThemeResolver + thème sombre par défaut — le rétrofit de tokens sur des vues existantes coûte cher, donc c'est un livrable M0), maquettes Figma validées, spike SwiftTerm + forkpty (preuve : 4 sessions streaming simultanées fluides), spike hooks Claude Code → socket.

**M1 — Cœur sessions (4 sem.)** : SessionManager, PTYHost, TerminalEngine/SwiftTerm intégré avec throttling, transcripts, GRDB + migrations, création/arrêt de sessions, vue Sessions avec états via heuristiques basiques. *Critère de sortie : UC-1/2/3 fonctionnels avec Claude Code, états fiables à l'œil nu.*

**M2 — Git + états fiables (3 sem.)** : worktrees automatiques, panneau Git, hooks Claude Code complets (STA-01→05), notifications, arrêt gracieux, reprise `--resume`. *Critère : démo « 5 tâches parallèles sur un repo réel, zéro collision, zéro état faux ».*

**M3 — Navigateur + finitions (4 sem.)** : BrowserService complet (WEB-01→05), palette ⌘K, historique/archives, recherche FTS, **thèmes** (sélecteur global, override projet complet et accent seul, thèmes intégrés, application au terminal ; import iTerm/Ghostty et éditeur si le temps le permet, sinon M4/v1.1), **Skills & Rules** (SKL-01→08 : scan FSEvents, onglets, shadowing, création/duplication — l'édition intégrée reste P2), accessibilité P0, états vides, préférences.

**M4 — Durcissement et release (2 sem.)** : tests d'endurance mémoire, agents génériques (Codex/Gemini heuristique), signature/notarisation, **Sparkle** pour les mises à jour, DMG, doc utilisateur, beta privée.

Total : ~15 semaines pour 1 dev senior Swift à temps plein (ajuster ±30 % selon familiarité AppKit/PTY).

---

## 9. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Fiabilité de la détection d'état sur agents sans hooks | Élevé — cœur de la valeur | Prioriser Claude Code (hooks) ; heuristiques versionnées + journal de diagnostic (STA-06) ; regex par agent mises à jour sans release (fichier de définitions) |
| Évolution des CLI agents (flags, formats de sortie, hooks) | Moyen | Adaptateurs isolés (BunshinAgents), tests d'intégration contre versions épinglées, canary check au lancement (`claude --version`) |
| Perf SwiftTerm sous très fort débit | Moyen | Throttling agressif dès M1 ; abstraction TerminalEngine permettant migration libghostty quand son API sera stabilisée avec renderer |
| Blocages OAuth en webview (Google SSO) | Moyen | UA Safari (WEB-04) + bascule navigateur système documentée |
| Perte de sessions au crash | Élevé perçu | Transcripts continus, reprise `--resume`, tests de kill -9 en CI ; backend tmux en v2 |
| Worktrees et repos exotiques (submodules, LFS, monorepos géants) | Moyen | Shell out vers git utilisateur (GIT-06), tests sur repos de référence, création worktree asynchrone avec progression |

---

## 10. Stratégie de test

**Unitaires** (BunshinCore, BunshinAgents, StateEngine) : transitions d'état exhaustives, parsing des payloads hooks, heuristiques sur corpus de sorties enregistrées (fixtures de vraies sessions Claude Code/Codex). **Intégration** : PTY réels avec scripts simulant des agents (streaming, prompts, exit codes), git réel sur repos fixtures (worktrees, collisions de branches). **Endurance** : 100 cycles création/destruction de sessions, 1 h de streaming continu multi-sessions, mesure mémoire/CPU automatisée. **UI** : tests XCUITest sur les parcours UC-1→UC-6 ; vérification Reduce Motion. **Manuel structuré** : checklist par release sur les 3 agents supportés et 2 versions de macOS.

Couverture cible : 80 % sur BunshinCore/BunshinAgents/BunshinGit ; le rendu terminal est validé par tests de snapshot d'écran.

---

## 11. Livraison et exploitation

Distribution : DMG signé Developer ID, notarisé, mises à jour via Sparkle (appcast auto-hébergé), versionnage SemVer. Canaux : beta (early adopters) puis stable. Diagnostics : export de logs en un clic (OSLog filtré + journaux d'état), aucun envoi automatique. Licence et modèle économique : hors périmètre de ce document.

---

## 12. Trajectoire v2 (pour information, non contractuel)

Backend tmux (persistance réelle des sessions), profils navigateur par projet, API GitHub (PRs natives), orchestration multi-agents sur une même tâche (fan-out/review), migration TerminalEngine vers libghostty quand renderer et API C seront stables, système de skills/templates de prompts par projet, app compagnon iOS (supervision à distance).

---

## Annexe A — Décisions d'architecture actées (ADR résumés)

**ADR-1 SwiftTerm vs libghostty-vt** : SwiftTerm retenu (complet : parsing+rendu+PTY, API Swift) ; libghostty-vt écarté v1 (API en flux, pas de renderer fourni) ; frontière `TerminalEngine` imposée pour réversibilité. **ADR-2 GRDB vs SwiftData** : GRDB (migrations contrôlées, FTS5, accès acteurs background). **ADR-3 git CLI vs libgit2** : CLI utilisateur (compat credentials/hooks/SSH). **ADR-4 App non sandboxée** : requis PTY/worktrees ; compensé par Hardened Runtime + notarisation. **ADR-5 Hooks via socket Unix + binaire helper** : plus fiable que fichiers sentinelles ou polling ; token par session. **ADR-6 Pas de persistance PTY v1** : coût tmux repoussé ; continuité assurée par `--resume` + transcripts.
