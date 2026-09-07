# Site vitrine

`index.html` est la landing page publique de Loom : un seul fichier, sans étape de
build (CSS et JS inclus, polices via Google Fonts avec repli système).

Ouvrir localement :

```sh
open website/index.html
```

La palette reprend le thème « Dark » intégré à l'app (`Sources/LoomUI/Theme.swift`) ;
la maquette de la vue Sessions dans le hero rejoue un scénario d'états
(`working → needs_input → idle`) pour montrer la détection d'état en action.
