# Pas de persistance des PTY au-delà de la vie de l'app en v1

Les PTY sont des enfants de l'app : ils meurent avec elle. Faire survivre les sessions (backend tmux ou daemon) coûte cher et est repoussé en v2, architecturé comme une seconde implémentation de `PTYHost`. La continuité v1 repose sur : transcripts écrits en continu, état sauvé en base, sessions marquées `interrupted` au relancement, et Reprise via le mécanisme natif de l'agent (`claude --resume`). Un utilisateur ne perd donc jamais le *contenu* d'une session, seulement le process vivant.
