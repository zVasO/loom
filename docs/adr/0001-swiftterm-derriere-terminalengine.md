# SwiftTerm comme moteur terminal, derrière un protocole TerminalEngine

Il fallait un émulateur de terminal complet (xterm-256color, truecolor, IME) utilisable depuis Swift. SwiftTerm est retenu car il fournit parsing, rendu et gestion de process avec une API Swift native ; libghostty-vt est écarté pour la v1 (API C encore en flux, pas de renderer fourni). Tout le code consomme le protocole `TerminalEngine` — jamais SwiftTerm directement — pour rendre une migration ultérieure vers libghostty possible sans toucher au reste de l'app.

## Considered Options

- SwiftTerm : complet, API Swift, maintenu — retenu
- libghostty-vt : parsing excellent mais API instable et sans renderer — reconsidérer en v2
- Émulateur maison : coût prohibitif, hors de question
