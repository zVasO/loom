# SessionRuntime orienté snapshot, sans registre d'observateurs en v1

Trois designs concurrents de `SessionRuntime` ont été produits sous contraintes opposées (docs/design/candidates/) et arbitrés dans docs/design/session-runtime.md. Décision : l'API appelant du candidat C (`launch`/`events`/`stop` + `TerminalSurface` `@Observable` dont `screen` n'est jamais vide), la forme de seam PTY du candidat B (`PTYEvent`, capabilities, pas de descripteur de fichier — prépare tmux v2 sans le payer), et le **rejet** du registre `StreamObserver` de B : un seam à un seul usage réel est de l'indirection (« un adapter = seam hypothétique ») ; transcript et échantillonnage sont câblés directement. Si la recherche live ou la réplication iOS se confirment en v2, reprendre B §1.5.

## Consequences

- L'interface parie que Bunshin dessine le terminal depuis des valeurs (`TerminalScreen`). Le spike M0 doit valider un rendu 120 Hz depuis snapshots sur session en streaming continu ; si le banc échoue, c'est ce design qu'on revoit, pas ses appelants.
- La surface de test convenue est l'interface publique de `SessionRuntime` + `TerminalSurface`, avec `ScriptedPTYHost` et une horloge de test ; aucun test ne franchit la queue de session.
