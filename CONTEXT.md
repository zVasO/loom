# Loom

Application macOS native qui orchestre des sessions d'agents de codage CLI : chaque session vit dans un terminal persistant sur son propre worktree Git, avec détection d'état en temps réel et historique complet.

## Language

### Cœur

**Projet** :
Un dossier local (généralement un repo Git) auquel se rattachent des sessions.
_Avoid_ : workspace, repo (« repo » désigne le dépôt Git lui-même, pas le concept Loom)

**Session** :
L'unité centrale : un agent CLI exécuté dans un terminal persistant, attaché à un répertoire de travail, avec un cycle de vie et un transcript. C'est toujours la session *Loom* ; pour celle du CLI, dire « session native ».
_Avoid_ : tâche, task, conversation

**Session native** :
La session interne au CLI de l'agent (ex. l'ID que `claude --resume` accepte). Une Session Loom référence au plus une session native.
_Avoid_ : session agent, session Claude (ambigu avec Session)

**Agent** :
Le programme CLI hébergé par une session (Claude Code, Codex, Gemini CLI). Loom l'héberge, ne le remplace pas.
_Avoid_ : bot, modèle, IA

**Terminal principal** :
Le terminal d'une session qui héberge le process de l'agent.

**Terminal secondaire** :
Un shell libre supplémentaire ouvert dans le même worktree qu'une session.
_Avoid_ : onglet (terme UI, pas domaine)

**Worktree** :
Checkout Git isolé créé pour une session, sur sa propre branche. Détruit ou conservé indépendamment de la session.

**Transcript** :
L'enregistrement intégral et continu de la sortie d'un terminal, conservé après la fin de la session.
_Avoid_ : log, historique (« historique » = la liste des sessions passées)

**Reprise** :
Relance d'une session `interrupted` via le mécanisme natif de l'agent (ex. `claude --resume <session native>`).
_Avoid_ : restauration (les PTY ne survivent pas ; on reprend la conversation, pas le process)

**Fenêtre de contexte** :
La taille d'entrée maximale du modèle qui sert une session (200k ou 1M tokens selon le modèle), lue dans les enregistrements natifs de l'agent. C'est la référence du pourcentage affiché par l'anneau de l'en-tête de session.
_Avoid_ : quota, limite (la limite d'usage est autre chose)

**Badge** :
Étiquette courte et colorée portée par une session (`PR #42`, `review`, `wip`). Une session en porte zéro ou plusieurs, dans l'ordre d'attribution ; les définitions (nom + couleur) sont globales à l'app. Une métadonnée, jamais un état.
_Avoid_ : label, tag

### États de session

**working** :
L'agent produit activement (génération, exécution d'outils).

**needs_input** :
L'agent est bloqué en attente d'une action de l'utilisateur : question posée, demande de permission. C'est l'état qui déclenche badge et notification.
_Avoid_ : waiting, blocked

**idle** :
L'agent a terminé son tour sans rien demander ; le process vit toujours et accepte un nouveau prompt.
Frontière `idle`/`needs_input` : un agent qui termine son tour par une question est `needs_input`, pas `idle`. Validé pour Claude Code : hooks `PermissionRequest`/`Notification` pour les blocages certains, classification du `last_assistant_message` de `Stop` pour les questions de fin de tour (voir docs/research/claude-code-hooks.md §4).

**completed / failed** :
Le process de l'agent s'est terminé (exit 0 / exit ≠ 0). États terminaux du process, pas de la session (une session `completed` reste consultable).

**interrupted** :
La session était vivante quand l'app s'est arrêtée ; candidate à la Reprise.

**archived** :
La session est sortie des vues actives par l'utilisateur ; transcript et métadonnées restent consultables.
_Avoid_ : supprimée (l'archivage ne détruit rien)

### Détection d'état

**Hook** :
Signal émis par l'agent lui-même (mécanisme de hooks de son CLI) vers l'app. Source d'état prioritaire.

**Heuristique** :
Inférence d'état par observation externe (silence du flux, motifs de prompt, CPU). Source de repli, jamais prioritaire sur un hook récent.

**Source** :
L'origine d'une transition d'état : hook, heuristique, process (exit), ou utilisateur. Toute transition est journalisée avec sa source.

### Personnalisation

**Skill** :
Dossier d'instructions réutilisable par un agent (ex. `SKILL.md`), à portée globale ou projet. Loom les affiche et les gère, ne les exécute jamais.

**Rule** :
Fichier d'instructions injecté en contexte par l'agent (ex. `CLAUDE.md`), à portée globale ou projet.
_Avoid_ : mémoire, config

**Shadowing** :
Situation où un skill projet porte le même nom qu'un skill global et le remplace pour ce projet.

**Thème** :
Ensemble de couleurs couvrant deux espaces : UI et Terminal. Résolu en cascade : thème global → override projet → hérité par les sessions.

**Override projet** :
Choix d'un projet de dévier du thème global — soit thème complet, soit accent seul.

**Accent** :
La couleur signature d'un projet, portée par ses cartes de session ; le repère visuel « je suis dans quel projet ? ».

### Extensions

**Extension** :
Une page web tierce (HTML/JS/CSS) que Loom affiche dans l'onglet Extensions, isolée dans sa propre vue web, et qui ne parle à Loom que par le pont. Installée (copiée) ou liée (servie depuis son dossier, pour le développement).
_Avoid_ : plugin, add-on, intégration

**Manifeste** :
Le fichier `loom-extension.json` d'une extension : son identité, sa page d'entrée, la version du pont visée, ses permissions, ses commandes.

**Pont** :
`window.loom` : l'API qu'une extension appelle, et les événements qu'elle reçoit. Chaque appel est vérifié côté Loom.
_Avoid_ : SDK (le SDK n'est que l'enveloppe JavaScript du pont)

**Permission** :
Ce qu'une extension demande dans son manifeste au-delà de sa propre page : des hôtes réseau, la lecture ou le lancement de sessions, la lecture des projets.

**Autorisation** :
Les permissions que l'utilisateur a accordées. Une extension tourne avec ce que son manifeste demande *et* que l'autorisation couvre ; un manifeste qui demande plus attend une nouvelle autorisation.
_Avoid_ : grant, consentement (le consentement est le geste, l'autorisation son résultat)
