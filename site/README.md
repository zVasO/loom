# Landing page de Loom

Page statique, sans build : `index.html` (HTML, CSS et JS inline) et `favicon.svg`
(copie de `Assets/loom-icon-small.svg`, qui sert aussi de logo dans la page).

```sh
python3 -m http.server -d site 8080   # puis http://localhost:8080
```

Déploiement : le workflow `.github/workflows/pages.yml` publie le dossier `site/` sur
GitHub Pages à chaque push sur `main` qui le modifie (ou à la main, depuis l'onglet
Actions). Pages doit être activé une fois dans les réglages du dépôt, avec « GitHub
Actions » comme source. Ailleurs (Netlify, S3…), servir le dossier tel quel.

## Dépendances externes

- Geist et Geist Mono via Google Fonts, avec repli système.
- GSAP 3.12.5 et son plugin ScrollTrigger via cdnjs. Si le CDN ne répond pas, la page
  s'affiche au bout de 3,5 s avec des animations CSS plus simples : rien n'est bloqué.

## Contenu

La page ne présente que ce qui est dans l'app, et ne montre aucune donnée inventée
(ni session, ni PR, ni chiffre d'usage). Loom n'a pas de binaire publié : l'appel à
l'action est la compilation depuis les sources. Ce qui est « vivant » vient du code :

- la démo d'état rejoue la table de transitions de `Sources/LoomCore/StateEngine.swift` ;
- les 24 thèmes de l'aperçu portent les couleurs de `ThemeStore.swift` et
  `ThemeGallery.swift` (variantes sombres), recopiées dans `THEMES` ;
- les vingt outils `browser_*`, les raccourcis et les étapes des quatre gabarits de
  workflow sont ceux du code.

Quand l'un de ces éléments change dans l'app, le reporter ici à la main.

## Design system

- Sombre uniquement. Surfaces : noir OLED `#000000`, zinc `#09090B` / `#121214`,
  filets à 9 % de la couleur du texte.
- Couleurs : tokens de **Loom Dark** (`Sources/LoomUI/ThemeStore.swift`). Accent
  `#E8945C` pour les appels à l'action, les états actifs et la lumière des
  animations ; la sémantique des états (`working` `#4CC38A`, `needs_input`
  `#E5B455`, `idle` `#6AA2E8`, échec `#E5646C`) ne sert qu'aux statuts.
- Type : Geist pour le texte, Geist Mono en capitales pour les libellés.
- Mise en page : un cadre central à filets verticaux, des sections en cellules, des
  croix aux intersections, un bento à bordures partagées.
- Icônes : tracés Lucide inline, `stroke-width: 1.5`.

## Mouvement

- **Héros** : un canvas où des sessions circulent sur la grille (vert, `working`).
  L'une s'arrête et passe à l'ambre (`needs_input`) ; un clic dessus lui « répond ».
- **Entrée en scène** : titre lettre par lettre, puis le reste en cascade.
- **Défilement** : bandeau qui accélère avec la vitesse, titres dont les mots
  s'allument, cartes en cascade, traits de lumière sur le cadre.
- **Scènes épinglées** (écran d'au moins 861 px de large et 640 px de haut pour la
  première, 961 × 700 pour la seconde) : la section « États » se fige et chaque cran
  de défilement envoie un hook ; la section « Workflows » se fige et les quatre
  gabarits défilent à l'horizontale. En dessous de ces tailles, tout reste empilé.
- `prefers-reduced-motion` coupe toutes les animations ; la page reste complète.
