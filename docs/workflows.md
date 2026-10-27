# Workflows

Un workflow enchaîne des étapes confiées à des **experts** : on le dessine dans l'onglet **Workflows**, on le lance sur une PR, un ticket Jira ou à la main, et il se termine par un **rapport**. Les choix de conception sont dans l'[ADR-0017](adr/0017-workflows-multi-agents.md).

## L'onglet Workflows

- **Workflows** : la bibliothèque. Un clic ouvre l'éditeur ; un double-clic renomme ; le menu contextuel lance, duplique, exporte (avec ses experts et connecteurs, sans secret) ou supprime. Le `+` crée, importe un fichier `.loom-workflow.json`, ou ajoute le built-in « PR review — 3 passes ».
- **Experts**, **Connectors** : des formulaires natifs (voir plus bas).
- **Runs** : l'historique. Un run en cours se suit sur le graphe (les étapes s'allument, « pass 2 »…) ; **Report** ouvre le rapport, **Log** le journal, le dossier contient tout.
- En bas : combien d'étapes tournent à la fois dans un run, et le modèle par défaut.

## L'éditeur

Glisser une étape depuis la palette (ou cliquer dessus), relier le point de droite d'une étape au point de gauche d'une autre. **Plusieurs liens sortants s'exécutent en parallèle, plusieurs liens entrants attendent tous.** ⌘Z / ⇧⌘Z annulent et rétablissent ; tout est enregistré au fil de l'eau. Les problèmes (une étape sans prompt, un lien qui ferait un cercle, une variable qui ne vient de nulle part) s'affichent sur les étapes ; **Run…** reste grisé tant qu'il reste une erreur.

| Étape | Rôle |
|---|---|
| **Start** | Le départ, et ce qui peut lancer le workflow : le bouton Run (⌘K), l'onglet d'une PR, une clé Jira seule, une review planifiée. |
| **Context** | Charge sans LLM : la PR (corps, fichiers, conversation, checks — et son worktree en lecture seule), le ticket Jira (lu par claude à travers un connecteur Atlassian), le repo (arborescence, README, fichiers touchés). |
| **Agent** | Une étape pour un expert : un prompt, et les **champs** de sa réponse — claude répond un seul objet JSON, vérifié, redemandé une fois s'il ne colle pas. Headless (`claude -p`) ou dans une **session visible** de Loom. |
| **Condition** | Prend le chemin Oui ou Non selon une valeur (`steps.coherence.stable` est vrai…). |
| **Loop** | Relance des étapes plus haut — toutes celles entre elles et la boucle — **au plus** N fois de plus (0 à 5), et s'arrête plus tôt quand une condition tient. |
| **Artifact** | Écrit le rapport, dans un thème de Loom ; peut remplir l'onglet de la PR (résumé, commentaires en attente, verdict suggéré). |

### Ce qu'un prompt peut citer

Cliquer une variable sous le prompt l'insère :

- `{{steps.<étape>.<champ>}}` : un champ de la réponse d'une étape d'avant ; `{{steps.<étape>.text}}` sa réponse en texte.
- `{{previous.<étape>}}` : sa réponse à la passe précédente (vide à la première) — c'est ainsi qu'une relance tient compte des retours ; `{{history.<étape>}}` toutes les passes d'avant.
- `{{pr.number}}`, `{{pr.title}}`, `{{pr.url}}`, `{{pr.author}}`, `{{pr.base}}`, `{{pr.head}}`, `{{pr.body}}` ; `{{ticket.key}}` ; `{{repo.name}}`, `{{repo.path}}` ; `{{run.note}}` (la note saisie au lancement) ; `{{iteration}}` (le numéro de passe).

## Experts

Un expert = des **instructions** ajoutées au prompt système de claude (`--append-system-prompt`), un **modèle** (`opus`, `sonnet`, `haiku` ou un identifiant), des **skills** (lues dans `~/.claude/skills` et `.claude/skills` du projet, injectées dans ses étapes seulement), des **connecteurs**, et les **outils** qu'il peut utiliser. Une étape headless n'a personne pour répondre à une demande de permission : ce qui n'est pas listé est refusé. Par défaut : lecture, recherche, et les commandes `git` / `gh` en lecture seule. Une étape peut ajouter ses propres skills et connecteurs à ceux de son expert.

## Connecteurs

- **Atlassian — le serveur de ton Claude Code** : le serveur MCP distant d'Atlassian, connecté une fois pour toutes en OAuth :

  ```sh
  claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse
  ```

  puis `/mcp` dans une session claude pour se connecter. Les étapes qui l'utilisent voient aussi tes autres serveurs MCP ; seuls les outils de celui-ci leur sont autorisés.
- **Atlassian — mcp-atlassian avec un jeton d'API** : Loom démarre [`mcp-atlassian`](https://github.com/sooperset/mcp-atlassian) (il faut `uv`) avec `JIRA_URL` (`https://<site>.atlassian.net`), `JIRA_USERNAME` (ton e-mail) et `JIRA_API_TOKEN` (créé sur id.atlassian.com), gardés au Trousseau.
- **Un serveur MCP** : une commande (arguments, variables d'environnement) ou une URL HTTP (en-têtes). Écrire `{{secret:NOM}}` là où une valeur doit venir du Trousseau ; le formulaire propose alors de la saisir.

**Run a test** lance claude avec ce seul connecteur et affiche les outils qu'il apporte.

## Lancer

- **Run…** dans l'éditeur, ⌘K « Run workflow: … », ou le menu contextuel : choisir le projet, la PR, la clé Jira (sinon trouvée dans le titre, la branche ou le corps de la PR), une note. L'estimation (nombre de runs claude, ordre de grandeur en dollars) s'affiche avant de lancer.
- **Depuis l'onglet d'une PR** : le menu **Workflow** lance un workflow sur cette PR, ou rouvre un de ses runs.
- **Planifié** : dans Réglages › Scheduled reviews, « Review with » choisit un workflow plutôt que la review intégrée ; il tourne sur chaque PR choisie.

## L'orchestrateur

Un workflow peut avoir un **orchestrateur** ([ADR-0018](adr/0018-orchestrateur-de-workflow.md)) : une session claude visible, lancée avec chaque run, qui le pilote. Il se règle dans l'éditeur, panneau de droite, quand aucune étape n'est sélectionnée :
- son expert ;
- son modèle ;
- ce qu'il doit surveiller ;
- son budget d'interventions ;
- les relances permises par étape ;
- si le rapport attend son feu vert.

- **Où le trouver** : Sessions › **Workflows**, un groupe par run (« PR review — 3 passes · PR #482 »), l'orchestrateur en tête puis les étapes visibles. Ou bien le bouton **Orchestrator** en haut d'un run. On lui parle comme à toute session. Il reste ouvert après le run.
- **Ce qu'il reçoit** : Loom lui écrit quand une étape finit (deux lignes), échoue, quand une boucle repart, quand une étape visible lui écrit, et à la fin du run. Ces messages arrivent seulement quand il est au repos, jamais au milieu de sa réponse.
- **Ce qu'il peut faire** (outils `loom_workflow_*`) :
  - lire l'état du run et la réponse d'une étape ;
  - **poser une question** à une étape : une étape visible la reçoit dans sa session, une étape headless reprend sa conversation (`claude -p --resume`) avec tout ce qu'elle avait lu ;
  - **relancer** une étape avec des consignes : elle repart avec sa réponse précédente, et les étapes après elle aussi ;
  - **sauter** une étape qui n'a pas tourné ;
  - **arrêter** le run.
- **Les points d'arrêt** : avant le rapport, si c'est coché, et avant de finir sur un échec. Le run attend une relance, un saut, `loom_workflow_proceed`, ou la fin de son tour, 15 minutes au plus. L'en-tête du run affiche alors « Waiting for the orchestrator ».
- **Les limites** :
  - questions, relances et sauts entament le budget du run ;
  - une étape ne se relance que tant qu'elle et la suite ne tournent pas, et dans sa limite de relances ;
  - l'orchestrateur n'atteint que son run, et seulement avec le jeton de sa session.
- **Sur le graphe d'un run** : chaque étape porte ce qu'il en a fait (« rerun », « asked », « skipped »).

Le built-in « PR review — 3 passes » a pour orchestrateur le lead reviewer. Une bibliothèque créée avant lui le reçoit en ajoutant de nouveau le built-in (`+`).

## Le rapport

Un fichier HTML autonome dans le dossier du run, animé (apparitions, compteurs, frise ; `prefers-reduced-motion` respecté). Le gabarit « Rapport de review de PR » cherche les champs par leur nom, quel que soit le nom des étapes : `intent`, `readingOrder`, `ticketCriteria`, `risks`, `questions`, et la réponse consolidée qui porte `verdict` et `findings` (avec `summary`, `stable`, `dropped`, `changes`). Les réponses avec `findings` mais sans verdict sont les experts. Le gabarit « générique » montre chaque étape.

Il porte **un thème de Loom** : couleurs par rôle (accent → liens et boutons ; couleur des en-têtes de groupe → accent de marque ; fond du contenu → bandeau et pied de page ; danger / « à toi » / « idle » → bloquant / à corriger / OK), polices, rayon et logo pris dans le volet « Reports » du thème (Réglages › Theme). Le thème HomeServe est prêt : **Import a theme file…** → `docs/themes/homeserve.json`, puis y coller le logo SVG.

## Le format

Un workflow est un fichier JSON lisible — `nodes` (`id`, `title`, `type`, `position`, `config`) et `edges` (`from`, `to`, `branch` pour les sorties d'une condition). L'éditeur se reconstruit par `scripts/build-workflow-editor.sh` après une modification de `WorkflowEditor/src`.
