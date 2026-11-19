# Loom Daily — plugin Obsidian

Toutes les 30 minutes, quelques lignes dans la note du jour sur ce qu'ont fait les sessions
Claude Code du Mac — celles de Loom comprises, qui en sont. Rien n'a bougé : rien n'est demandé,
rien n'est écrit.

```markdown
## Loom
- 10:30
  - **loom (claude/fix-cache)** : test de connexion instable corrigé en remettant l'état à zéro dans `reset()`.
  - **site** : page de tarifs passée en grille, déployée en préproduction.
```

## Comment

- Le plugin lit les conversations là où claude les garde (`~/.claude/projects/<dossier>/<session>.jsonl`),
  depuis l'endroit où il s'était arrêté : messages, réponses, et une ligne par outil
  (`Bash: swift test`, `Edit: Sources/App.swift`).
- Il demande à `claude -p` (modèle `haiku` par défaut) une puce par session, puis l'ajoute sous la
  section `## Loom` de la note du jour, créée si elle manque. Le nom et le dossier de la note sont ceux
  du plugin « Daily notes » d'Obsidian, sauf réglage contraire.
- Un passage qui échoue (claude introuvable, réseau) ne perd rien : le suivant reprend la même activité.
- Ses propres appels à claude tournent dans un dossier temporaire à part, jamais résumé.

## Installer

```sh
mkdir -p "<coffre>/.obsidian/plugins/loom-daily"
cp Integrations/obsidian-loom-daily/{manifest.json,main.js} "<coffre>/.obsidian/plugins/loom-daily/"
```

Puis Obsidian › Réglages › Modules complémentaires › activer « Loom Daily ». Ordinateur seulement :
le plugin lit des fichiers et lance `claude`.

## Réglages (dans Obsidian)

| Réglage | Par défaut |
| --- | --- |
| Résumer automatiquement | oui |
| Toutes les (minutes) | 30 (5 au moins) |
| Section | `## Loom` |
| Langue | French |
| Modèle | `haiku` |
| claude | trouvé dans `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin` |
| Conversations | `~/.claude/projects` |
| Dossier et format de la note du jour | ceux du plugin « Daily notes » |

La commande « Loom Daily: Summarize the sessions now » (palette d'Obsidian) fait un passage tout de
suite. Le premier passage part du début de la journée.

## Tests

`npm test` ici : la partie pure (lecture d'une conversation, consigne, insertion dans la note), sans
Obsidian.
