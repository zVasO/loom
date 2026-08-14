# Shell out vers le git de l'utilisateur plutôt que libgit2

Les opérations Git (worktrees, status, diff, commit, push) passent par le binaire `git` de l'utilisateur (PATH résolu depuis son shell de login), pas par libgit2. Raison : compatibilité maximale avec sa configuration réelle — credentials helpers, hooks, SSH, includes conditionnels — que libgit2 reproduit mal ou pas du tout. Contrepartie assumée : parsing de sorties texte (porcelain v2) et dépendance à git ≥ 2.39 ; toutes les commandes sont journalisées.
