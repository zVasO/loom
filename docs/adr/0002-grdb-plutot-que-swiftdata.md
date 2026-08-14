# GRDB plutôt que SwiftData pour la persistance

La base locale doit supporter des migrations contrôlées dès la v1, la recherche plein texte (FTS5) et des accès concurrents depuis des services background (acteurs). SwiftData ne donne ni contrôle fin des migrations ni FTS5 ; GRDB donne les trois. Décision : SQLite via GRDB, migrations versionnées dès le premier schéma.
