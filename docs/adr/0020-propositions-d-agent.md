# Ce qu'un agent construit est une proposition : il faut ta validation pour que ça tourne

Les workflows (ADR-0017 à 0019) et les reviews planifiées ne se construisaient qu'à la main. On veut qu'un agent puisse aider : qu'une session, ou un « Workflow builder » ouvert depuis l'onglet Workflows, lise la bibliothèque, propose un workflow, ses blocs, ses règles, ses experts et sa planification, et qu'on n'ait plus qu'à relire. Mais un workflow peut lancer une commande sur le code d'une PR, et une planification tourne seule à 9 h : un agent manipulé par le texte d'une PR ne doit pas pouvoir installer du travail qui tourne sans la personne.

## Décision

**Tout ce qu'un agent enregistre est une proposition.**
- `AgentProposal` (dans `LoomCore`) sur `Workflow`, `WorkflowBlock`, `RuleSet`, `Expert` et `ReviewSchedule` dit qui l'a proposée, quand, et garde **la version validée avant la première modification de l'agent** (aucune s'il s'agit d'une création).
- Une seule règle : **seule la version validée fait foi**.
  - Un run ne démarre pas tant que le workflow, ou un bloc, un expert ou un jeu de règles qu'il utilise, attend une validation. Ça couvre aussi les runs lancés par une planification.
  - Une planification proposée ne part pas. Si l'agent a modifié une planification validée, c'est sa version précédente qui continue de tourner.

**L'agent passe par l'API des agents** (ADR-0010), méthodes `library.*` (outils MCP `loom_library_*`, CLI `loom library …`) :
- **Lecture** : la référence du format (générée depuis les valeurs par défaut du modèle) et ce qui existe, sans secret ni versions précédentes.
- **Validation** d'un workflow sans l'enregistrer.
- **Écriture** : des propositions pour chaque type.
- **Lancement** : l'ouverture de la feuille Run préremplie, qui ne part qu'au clic de la personne.
- **Connecteurs** : ils restent **en lecture seule**, parce qu'un serveur MCP lance une commande et que les connecteurs portent des secrets.
- **Bornes** : 50 propositions en attente au plus, 200 étapes par workflow, des entrées de taille bornée.
- **Pré-autorisation** : une proposition est inerte, donc les outils sont pré-autorisés.
- **Disponibilité** : listés dans toutes les sessions, sauf si on les coupe dans les Réglages.

**La personne valide** dans l'onglet Workflows :
- La section **To review** montre chaque proposition, son auteur et un résumé des changements. Les commandes et les outils d'expert ajoutés sont signalés en rouge.
- Elle offre trois actions : Validate, Revert (revenir à la version validée, ou supprimer une création) et Open.
- L'éditeur affiche un bandeau sur un workflow proposé, et les Réglages en affichent un sur une planification proposée.
- Modifier une proposition ne la valide pas : valider est un bouton à part.

**« Create with AI » / « Improve with AI »** ouvre une session visible avec des consignes de constructeur. Elle pose ses questions, lit la référence, valide puis enregistre. La session est rangée sous Sessions › Workflows, et l'éditeur montre le workflow à mesure qu'elle le propose.

## Alternatives rejetées

- **Des écritures actives tout de suite** : un agent manipulé par une PR pourrait programmer une commande quotidienne.
- **Les outils d'écriture réservés à la session du builder** : une autre session reste un vecteur possible, et la garde vaut autant pour toutes.
- **Une copie brouillon à côté de l'original** : deux objets à réconcilier. Garder la version validée dans la proposition suffit pour revenir en arrière.
- **Le jeton global seul** : il est lisible par un shell d'agent. La garde doit donc être la validation, pas le jeton.

## Conséquences

- Les fichiers gagnent un champ `proposal` optionnel. Les anciens se lisent tels quels.
- Les menus de la section Scheduled reviews des PR permettent de retirer une PR revue, d'arrêter une review en cours ou d'effacer le dernier run.
