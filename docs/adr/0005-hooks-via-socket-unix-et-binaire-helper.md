# Détection d'état par hooks agent via socket Unix et binaire helper

Le canal principal de détection d'état est constitué des hooks de l'agent (Claude Code : Notification, Stop, SessionStart…) qui notifient l'app via un socket Unix local (permissions 0600, token par session), en appelant un petit binaire helper `bunshin-hook` installé par l'app. Alternatives rejetées : fichiers sentinelles et polling (fragiles, latents), `nc -U` en shell (moins robuste que le binaire). Les hooks sont injectés au niveau de la session/du worktree, jamais dans les settings globaux de l'utilisateur sans consentement.

## Consequences

- Les agents sans hooks (Codex, Gemini) retombent sur des heuristiques PTY ; la priorité hook > heuristique est câblée dans la machine à états.
- Le helper doit être versionné avec l'app et son protocole (JSON par ligne : token, sessionId, event, data) stable.
