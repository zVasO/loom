# Une DispatchQueue sérielle dédiée par session pour tout accès au Terminal

La documentation officielle de SwiftTerm affirme que `Terminal` est thread-safe (« the terminal will synchronize internally ») ; l'inspection du code source (v1.18.0) montre qu'il n'existe aucune primitive de synchronisation dans le moteur — le contrat réel, écrit dans les commentaires du code, est du *thread-confinement* (voir docs/research/swiftterm-pty.md §2). Décision : chaque session possède une `DispatchQueue` sérielle dédiée, passée à `HeadlessTerminal(queue:)` ; tout accès à l'instance `Terminal` (feed, resize, snapshot, lecture de buffer) est marshalé sur cette queue, sans exception. Ne jamais se fier à la doc publique de SwiftTerm sur ce point.

## Consequences

- Résout aussi le piège de la queue par défaut (= main queue) et isole les sessions lentes entre elles.
- Les projections `@Observable` pour l'UI sont produites sur la queue de session puis publiées sur le MainActor — jamais de lecture directe du Terminal depuis une vue.
- Tests d'endurance à exécuter sous Thread Sanitizer (point de vigilance : mode DEC 2026, seul endroit où le moteur touche la main queue de lui-même).
