# Recherche : hooks et sessions Claude Code

Sources primaires : [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) et [code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference), consultées le 2026-08-14. Toutes les citations proviennent de ces deux pages.

## 1. Événements de hooks pertinents pour Loom

Le catalogue complet compte ~30 événements. Ceux qui portent la détection d'état :

| Événement | Déclenchement (doc) | Usage Loom |
|---|---|---|
| `SessionStart` | « When a session begins or resumes » — matcher `startup`/`resume`/`clear`/`compact`/`fork` | confirmation de démarrage, capture du `session_id` natif |
| `UserPromptSubmit` | à la soumission d'un prompt | transition → `working` |
| `Stop` | « When Claude finishes responding » — une fois par tour | fin de tour → `idle` (ou `needs_input`, voir §4) |
| `StopFailure` | « When the turn ends due to an API error » | signal d'erreur de tour (sans exit du process) |
| `Notification` | « When Claude Code sends a notification » | cœur de `needs_input`, voir §4 |
| `PermissionRequest` | « When a tool call needs a permission decision » | `needs_input` immédiat et précis (payload = outil + input) |
| `SessionEnd` | fin de session — matcher `clear`/`resume`/`logout`/`prompt_input_exit`/… | fermeture propre |

Existent aussi et pourraient enrichir la barre d'état plus tard : `PreToolUse`/`PostToolUse` (activité fine), `PreCompact`/`PostCompact`, `SubagentStart`/`SubagentStop`, `WorktreeCreate`/`WorktreeRemove`, `TaskCreated`/`TaskCompleted`.

## 2. Payloads (stdin JSON)

Champs communs : `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus `prompt_id` (≥ v2.1.196) et `permission_mode` selon l'événement.

Points clés vérifiés :

- **`Stop`** porte `last_assistant_message` (le texte final du tour) et `stop_hook_active`. La doc recommande explicitement `last_assistant_message` plutôt que la lecture du transcript : « The transcript file is written asynchronously and may lag […] Hooks that need the final assistant text of the current turn should use `last_assistant_message` ».
- **`Notification`** porte `notification_type` + `message`. Types documentés : `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`.
- **`SessionStart`** porte `source` (`startup`/`resume`/`clear`/`compact`/`fork`) et `model`.
- **`SessionEnd`** porte `reason`.
- `transcript_path` pointe vers `~/.claude/projects/<slug>/<session>.jsonl` — le transcript natif JSONL de Claude Code, distinct de notre transcript PTY.

## 3. Installation des hooks sans toucher aux settings globaux

Trois mécanismes vérifiés, du plus adapté au moins adapté pour Loom :

1. **Flag `--settings <path-or-json>`** : « Path to a settings JSON file or an inline JSON string. Values you set here override the same keys in your settings.json files for this session. » Accepte un fichier (≤ 2 MiB) ou du JSON inline. Portée : la session lancée, rien d'écrit sur disque utilisateur. **C'est le canal recommandé pour Loom.**
2. `.claude/settings.local.json` dans le worktree : « Gitignored automatically », portée projet. Solution de repli, mais laisse un fichier dans le worktree.
3. Les hooks des différents niveaux **se fusionnent** (ils ne se remplacent pas) : injecter nos hooks via `--settings` n'écrase donc pas les hooks personnels de l'utilisateur — cohabitation garantie.

Types de hooks supportés : `command` (script + args + timeout), mais aussi `http` (POST vers une URL) — à noter : un hook `type: http` vers un petit serveur HTTP local pourrait remplacer le couple binaire-helper + socket Unix. À arbitrer au design (le socket Unix 0600 reste plus simple à sécuriser qu'un port TCP local).

## 4. La question critique : `needs_input` vs `idle`

Le tableau est nettement plus favorable que ce que le cahier des charges anticipait :

- **`needs_input` certain** : `PermissionRequest` (décision d'outil attendue) et `Notification` avec `notification_type` ∈ {`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`}.
- **Fin de tour** : `Stop` = « Claude finishes responding ». Ne distingue pas nativement « travail fini » de « question posée », MAIS le payload contient `last_assistant_message` → une heuristique locale sur le texte final (question directe, demande de choix) peut classer `needs_input` vs `idle` sans regex sur l'écran PTY.
- **`idle_prompt`** : notification émise par Claude Code lui-même après inactivité — signal de rappel exploitable pour re-badger une session restée sans réponse.
- **`agent_completed`** : notification de complétion — candidat pour `completed` logique avant même l'exit du process.

Conclusion : la frontière tranchée dans `CONTEXT.md` (« termine par une question → `needs_input` ») est implémentable via hooks seuls pour Claude Code, avec une seule zone grise restante : la classification du `last_assistant_message` sur `Stop` (heuristique textuelle, à couvrir par fixtures de vraies sessions).

## 5. Reprise et identité de session — découverte qui change le design

- **`--session-id "<uuid>"`** : « Use a specific session ID for the conversation (must be a valid UUID) ». **Loom peut donc imposer l'UUID à la création** au lieu de le capturer via `SessionStart` comme le prévoit le cahier des charges (§6.4). Bénéfice : plus de fenêtre de crash entre lancement et premier hook ; l'ID est connu avant même le fork.
- **`--resume <session-id-or-name>`** : cherche « the current project directory and its git worktrees, then every other project on this machine » (≥ v2.1.223) — compatible avec nos worktrees.
- **`--fork-session`** : reprendre en créant un nouvel ID — utile pour « dupliquer la configuration » (SES-05) à partir d'une session existante.
- **`--continue`** : dernière conversation du répertoire courant — repli si l'ID est perdu.

## Non vérifié / à valider empiriquement

- Le seuil de déclenchement exact de `idle_prompt` (délai, configurabilité) n'est pas précisé sur les pages consultées.
- Comportement réel de la fusion de hooks quand `--settings` définit le même événement que les settings utilisateur (la doc dit « merge », à confirmer par test).
- La disponibilité de `agent_needs_input`/`agent_completed` hors contexte d'agent-teams (à tester : sessions simples).
- Versions minimales : `prompt_id` exige ≥ v2.1.196, recherche `--resume` étendue ≥ v2.1.223 — fixer une version plancher de Claude Code pour Loom (canary check au lancement, cf. risque n°2 du cahier des charges).
