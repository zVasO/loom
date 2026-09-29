# Icône de Loom

Style « verre liquide », dans la même famille que l'icône de Dbdd : trois
cartes de terminal en verre posées en éventail, celle de devant teintée de
l'orange de l'accent avec son invite `>_` — plusieurs sessions en parallèle.

- `loom-icon.svg` : le maître 1024 × 1024.
- `loom-icon-small.svg` : la même icône simplifiée pour 32 px et moins (sans
  lueur, verre plus opaque), pour rester nette au lieu d'être réduite.
- `loom.icns` : chaque taille (16 à 1024, @1x et @2x) est un rendu du SVG à sa
  taille exacte ; 16 et 32 px viennent de `loom-icon-small.svg`. Le release
  wizard la copie dans `Loom.app/Contents/Resources` (`CFBundleIconFile`).
- `loom-logo-1024.png` : rendu 1024 du maître.
- `Sources/LoomApp/Resources/loom-logo.png` : rendu 256, posé comme icône du
  Dock au lancement (même sous `swift run`) et affiché par `LogoMark`.

Les rendus ont été faits avec Chromium headless, fond transparent, à la taille
exacte de chaque emplacement.
