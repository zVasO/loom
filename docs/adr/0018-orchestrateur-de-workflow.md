# Un orchestrateur par run : une session visible qui pilote par l'API des agents

Un run de workflow (ADR-0017) enchaîne des étapes que rien ne relit au fil de l'eau : une réponse vague d'un expert passe telle quelle jusqu'au rapport, et une étape headless ne peut plus être interrogée une fois finie. On veut un **orchestrateur** : une session claude **visible**, lancée avec le run, rangée sous Sessions › Workflows, qui suit chaque étape, peut **poser une question** à n'importe quelle étape, **relancer** une étape avec des consignes, en **sauter** une, **arrêter** le run, et à qui la personne parle comme à toute session.

Décision : **le moteur garde la main sur le graphe ; l'orchestrateur agit par des méthodes de l'API des agents** (ADR-0010) — `workflow.get`, `workflow.step.read`, `workflow.step.ask`, `workflow.step.rerun`, `workflow.step.skip`, `workflow.stop`, `workflow.proceed`, et `workflow.message` pour une étape visible qui lui écrit — exposées en outils MCP `loom_workflow_*` et en `loom workflow …`.

- **Une relance** passe par le planner pur (`WorkflowPlanner.rerun`). L'étape et **tout ce qui en dépend** repassent en attente, leurs réponses vont dans l'historique comme pour une boucle. Les consignes sont ajoutées au prompt de l'étape, avec sa réponse précédente. C'est refusé pendant qu'une étape concernée tourne, et au-delà d'un plafond par étape.
- **Un saut** termine une étape en attente avec une réponse `{"skipped": true}` : la suite tourne.
- Le runner applique ces changements **entre deux étapes**. L'API modifie l'état du run puis réveille la boucle, qui ne les voit qu'entre deux `await`.
- **Une question** à une étape visible est tapée dans sa session quand elle est au repos. La réponse est lue dans son transcript natif, à partir de la taille qu'il avait avant la question.
- **Une question** à une étape headless reprend sa conversation (`claude -p --resume <session_id>`, l'id lu dans l'enveloppe JSON) avec le même expert, les mêmes outils, les mêmes connecteurs et le même dossier.
- Loom **tape les événements** dans la session de l'orchestrateur, regroupés, **seulement quand elle est au repos**, jamais au milieu d'un tour. Ce sont : une étape finie (deux lignes), un échec, une nouvelle passe, le message d'une étape, la fin du run.
- **Deux points d'arrêt bornés** :
  - avant le rapport (réglable) ;
  - avant de finir sur un échec.

  Le run attend une relance, un saut, `proceed`, `stop`, la fin du tour de l'orchestrateur sans décision, ou 15 minutes au plus. Il n'y attend de nouveau qu'après une relance ou un saut.
- **Un budget** : un nombre d'interventions par run (questions, relances, sauts) et de relances par étape. Une fois épuisé, la réponse est `conflict`.

**La portée vient de la session, jamais de la requête.** Le jeton de session de l'orchestrateur désigne son run, retrouvé par `WorkflowsModel.part(of:)` : le run qui le nomme orchestrateur, ou qui a lancé cette session pour une étape. Le jeton global est refusé (`allowsGlobalScope` faux) : un shell d'agent peut lire ce jeton dans son fichier, et il n'a pas de run. Un rôle n'atteint que ses méthodes : l'orchestrateur toutes sauf `workflow.message`, une étape visible seulement celle-là. La variable `LOOM_WORKFLOW_ROLE` ne fait que lister les outils pour `loom mcp`. Ce qu'un agent écrit et que Loom va taper dans un terminal est nettoyé : caractères de contrôle retirés, 8 000 caractères au plus.

**Alternatives rejetées** :
- donner à l'orchestrateur le jeton global et `sessions.list` : il verrait et toucherait toutes les sessions ;
- faire de l'orchestrateur le moteur (un agent qui lance lui-même les étapes) : rien de borné ni de déterministe, et l'état ne serait plus dans `run.json` ;
- envoyer les événements par un fichier qu'il surveille : il faudrait qu'il boucle ;
- relancer une étape headless sans `--resume` pour une simple question : elle aurait tout relu.

## Conséquences

- `Workflow.orchestrator` (expert, modèle, instructions, budget, point d'arrêt avant le rapport) est décodé de façon tolérante : un workflow sans ce champ n'a pas d'orchestrateur.
- `NodeRecord` gagne :
  - `claudeSessionID` ;
  - `reruns` ;
  - `extraInstructions`.
- `WorkflowRun` gagne :
  - `orchestratorSessionID` ;
  - `interventions` ;
  - `messages`, le journal des échanges ;
  - `stepSessions`, toutes les sessions d'étape de toutes les passes ;
  - ce qu'il faut pour reprendre l'orchestrateur après un redémarrage de Loom : dossier de travail, instructions, modèle.

  Les anciens runs se relisent.
- À chaque lancement **et à chaque reprise**, `adapter(for:)` redonne à une session de run :
  - son rôle ;
  - les règles de l'orchestrateur et son modèle ;
  - pour une étape, une ligne qui lui apprend `loom_workflow_message`.
- Sessions › **Workflows** : un groupe par run, l'orchestrateur en tête, puis les étapes visibles. L'appartenance vient des runs, pas des badges. Ces sessions sortent de leur projet et de CODE REVIEW, sauf si l'utilisateur coupe le réglage.
- Le built-in « PR review — 3 passes » a un orchestrateur, le lead reviewer, avec un budget de 10 interventions et 1 relance par étape. Il n'atteint une bibliothèque existante qu'en ajoutant de nouveau le built-in.
- L'estimation de coût avant lancement ne compte pas l'orchestrateur : c'est une session interactive, dont le coût dépend de la conversation.
