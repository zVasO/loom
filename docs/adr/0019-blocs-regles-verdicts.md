# Des blocs à soi, des règles, des verdicts que les liens suivent

L'éditeur de workflows (ADR-0017) n'offrait que six cases fixes, sans moyen d'en ajouter. Une étape répondait des champs, mais pour dire « si l'agent dit ok, on passe à la suite, sinon on reprend », il fallait une Condition, puis une Loop qui relance tout son corps. On veut :
- des **cases à soi** dans la palette, avec leurs consignes et leurs règles, posées autant de fois qu'on veut ;
- des **règles propres à chaque case posée** ;
- des règles **sur les liens** ;
- un **verdict** que les liens suivent ;
- et, dans le même esprit : une **validation humaine**, un **pour chaque élément**, une **commande** (tests, lint) et des **jeux de règles** réutilisables.

## Décision

### Blocs
Un **bloc** est un agent préparé, rangé dans `<support>/workflows/blocks/` : son prompt, ses champs, son verdict, son expert et ses réglages, ses règles.

- Une case posée depuis un bloc reste un nœud `agent`, avec `blockID` : il n'y a pas de nouveau type, donc ni le planner, ni l'orchestrateur, ni le rapport n'ont de cas de plus.
- La case est **liée** au bloc : modifier le bloc change toutes ses utilisations. `BlockResolver.effective` est pur et calcule ce qu'elle fait tourner :
  - le bloc fournit tout ;
  - la case ajoute ses **consignes propres** après le prompt du bloc, ses **règles propres** et ses jeux de règles ;
  - elle peut remplacer l'expert ou le modèle.
- Un run **fige** les blocs et les jeux de règles au lancement, comme il fige les experts.

### Règles
On peut écrire des règles sur :
- un bloc ;
- une case ;
- un lien : elles valent pour la case d'arrivée quand le run prend ce lien ;
- une reprise : elles valent quand le run repasse par là.

On peut aussi y cocher un jeu de règles (`<support>/workflows/rules/`). `RuleComposer` les rassemble par provenance et les ajoute au prompt système de l'étape (`--append-system-prompt`, section « Rules for this step »). Elles survivent donc à la relance d'une réponse mal formée et au `--resume` de l'orchestrateur.

### Variables de bloc
Un bloc ne connaît pas le workflow où il est posé : `{{in.text}}` et `{{in.<champ>}}` désignent les étapes juste avant, `{{item}}` et `{{index}}` l'élément d'un « pour chaque ».

### Verdicts
Une étape peut déclarer un **verdict** : des options, de la meilleure à la pire. Le schéma de sa réponse reçoit `verdict` (contraint aux options par `OutputField.options`) et `verdictReason`. Une validation humaine (ses réponses), une commande (`pass` / `fail`) et un « pour chaque » (le pire de ses éléments) rendent aussi un verdict.

### Liens conditionnels
Un lien porte `when` (une option) ou `otherwise` (ce qu'aucun autre lien vers l'avant ne prend) ; le planner les suit dans `state(of:)`.

### Reprises
Un **lien qui remonte** est une **reprise** (`retry.max`, 5 au plus).

- Ce n'est pas une dépendance : il n'entre ni dans la disponibilité des étapes, ni dans la détection de cycle.
- Quand son étape rend le verdict `when` et qu'il reste des tours, `complete()` relance le corps, c'est-à-dire les étapes du chemin cible → source. Les réponses passent dans l'historique, le compteur est `iterations["edge:<id>"]`, et l'étape relancée apprend pourquoi.
- Une fois les tours épuisés, l'étape suit ses liens vers l'avant.

C'est la boucle de l'ADR-0017 sans case Loop : bornée, déterministe, toujours décidée par le planner pur.

### Les trois nouveaux types
- **Validation humaine** : le run attend, une notification part, un bandeau sur le run propose une réponse par option et un commentaire. Au-delà d'un délai éventuel, c'est la dernière option qui compte.
- **Pour chaque** : un agent (inline ou un bloc) en headless, une fois par élément d'une liste, 30 au plus, quelques-uns à la fois. Les réponses sont rassemblées.
- **Commande** : une ligne de shell dans le dossier du run, dont le code de sortie donne le verdict.
  - **Aucun gabarit dans la ligne** : le texte d'une PR n'entre jamais dans une commande. Les données passent par `LOOM_PR_NUMBER`, `LOOM_PR_BASE`, `LOOM_PR_HEAD`, `LOOM_REPO_PATH` et `LOOM_RUN_FOLDER`.
  - L'environnement perd le socket et les jetons de Loom.
  - Sur une PR, une commande **exécute le code de la PR** (ADR-0014). La case doit l'autoriser explicitement (`allowOnPullRequests`), sinon un run sur une PR refuse de démarrer, quel que soit le chemin de lancement.

## Alternatives rejetées

- **Un nouveau type de nœud par bloc** : chaque switch, l'orchestrateur et le rapport auraient dû le connaître.
- **Des blocs copiés** au lieu de liés : c'est le choix de l'utilisateur ; une règle corrigée doit atteindre toutes les cases.
- **Des règles en texte libre dans le prompt** : elles se perdraient à la relance, et l'éditeur ne pourrait pas dire d'où elles viennent.
- **Des cycles libres dans le graphe** : rien de borné.
- **Des gabarits dans les commandes**, échappés : une injection shell attend la première erreur d'échappement.

## Conséquences

- `WorkflowEdge` gagne `when`, `otherwise`, `retry`, `rules` et `ruleSetIDs`. `AgentConfig` gagne `blockID`, `rules`, `ruleSetIDs` et `verdict`. Les anciens fichiers se lisent, et l'export emporte blocs et jeux de règles.
- L'éditeur a une palette « My blocks » avec `+` et ✎, un inspecteur de lien (quand, reprise, règles), « Make a block of this step », et des cartes qui montrent options et verdict rendu. Les reprises sont dessinées en pointillé.
- L'onglet Workflows a une section **Rules** et le bandeau de décision sur un run qui attend.
- L'estimation compte chaque élément d'un « pour chaque » et chaque tour d'une reprise. Une commande et une validation ne coûtent rien.
- L'orchestrateur (ADR-0018) peut aussi relancer ou sauter un « pour chaque » ou une commande, pas une validation humaine.
