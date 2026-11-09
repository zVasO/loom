# Charte graphique

La charte de la landing page (`site/index.html`) appliquée à l'app. Elle vit dans
les tokens et les composants de `LoomUI` : une vue qui s'en sert l'applique sans
rien coder de plus.

## Surfaces et couleurs

- **Loom Dark** est OLED : fond `#000000`, surfaces `#09090B` et `#121214`. Les
  autres thèmes gardent leurs propres surfaces.
- **Bordures** : un filet de 1 pt à 8 % de la couleur du texte (`DefaultTheme.line`),
  13 % et 21 % pour les états survolé et actif (`line2`, `line3`). `cardBorder`
  renvoie `line` : toute bordure existante est un filet.
- **Lavis de ligne** : 2,5 % au survol, 4,5 % à la sélection (`wash`, `wash2`).
- **Accent** : réservé aux appels à l'action et à ce qui est actif. Les couleurs
  d'état (`working`, `needs_input`, `idle`, échec) ne servent qu'aux statuts.

## Typographie

- Texte en police système (SF Pro), titres 13 pt medium.
- Données, compteurs, métadonnées, titres de section : mono en capitales,
  10,5 à 11 pt, crénage de 5 % (`MonoLabel`, en-têtes de section).

## Géométrie

- Rayons : 10 pour une carte ou une fenêtre, 6 pour un contrôle, 4 pour un
  onglet ou une touche, 3 pour un tag.
- Tableaux denses : lignes de 38 pt, cellules à 10 pt de marge (`FleetKit`).

## Icônes

`AppIcon(nomSFSymbol, size:)` dessine le glyphe Lucide qui lui correspond (trait
1,5, `LucideIcon`), sinon le symbole en graisse fine. Dans un `Menu`, un `Picker`
ou un `Label` de menu, garder `Image(systemName:)` : macOS n'y dessine que des
images système.

## Mouvement

`Animation.hover` : `cubic-bezier(0.16, 1, 0.3, 1)` en 160 ms. Au survol, la
surface monte d'un cran et le filet s'éclaircit d'un cran ; pas de fondu lent ni
de rebond.

## Composants

`NavTab` (onglet avec icône), `StatusTag` (● HOOKS ONLINE), `KeyCap` (touche),
`StatusLabel` (● working), `MonoTag` (branche), `AccentButton`, `GhostButton`,
`BarIconButton` ; côté app, `FleetKit` (tableau, terminal, journal, pied de
statut) pour Mission Control et le panneau de flotte.
