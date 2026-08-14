# App non sandboxée, distribuée hors Mac App Store

Le sandbox macOS interdit ce dont l'app a besoin : forkpty avec process enfants arbitraires, exécution du git de l'utilisateur, écriture de worktrees n'importe où sur le disque. Décision : app non sandboxée, distribution Developer ID + notarisation, Hardened Runtime activé en compensation. Conséquence : pas de Mac App Store, mises à jour via Sparkle.
