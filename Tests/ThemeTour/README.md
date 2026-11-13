# Tournée des thèmes

Le contrôle qu'aucun test unitaire ne fait : que Loom reste entier à l'écran sous un thème
importé suivi à la lettre (rayon, espacement, polices, interlettrage, ombres), et qu'un thème
intégré se dessine comme avant. `ThemeTour` (`Sources/LoomApp/ThemeTour.swift`) promène l'app
réelle sous chaque arrêt d'un plan et enregistre ce que l'écran montre de sa fenêtre, écran
après écran : Projets et ses onglets, Sessions (le terminal, puis la vue conversation), panneau
Git, navigateur, Mission Control, PRs, Workflows, Extensions, Réglages section par section,
feuilles d'import, de contexte, de nouvelle session et d'usage, palette.

```sh
swift build
PATH="$PWD/Tests/ThemeTour/bin:$PATH" \
LOOM_AUTOTEST=themes \
LOOM_SUPPORT_DIR="$(mktemp -d)" \
LOOM_TOUR_THEMES="$PWD/Tests/ThemeTour/themes" \
LOOM_TOUR_PROJECT="$PWD" \
LOOM_TOUR_OUT="$PWD/.theme-tour" \
LOOM_TOUR_PLAN="loom:dark,loom:light:core,neo-brutalism:light,violet-bloom:dark,neo-brutalism:dark:colours:core" \
swift run --skip-build LoomApp
```

- `LOOM_SUPPORT_DIR` est obligatoire : la tournée ajoute des thèmes, un projet et des sessions,
  jamais dans vos données. Elle change le thème et l'apparence de l'app le temps de passer, et
  les remet.
- Un arrêt du plan : `thème[:light|dark][:colours][:core]`. Le thème est une famille intégrée
  (`loom`, `dracula`…) ou `<nom>.css` dans `LOOM_TOUR_THEMES`, lu comme le lit la feuille
  d'import. `colours` : le thème suivi pour ses seules couleurs. `core` : les écrans principaux
  seulement.
- `bin/claude` remplace claude là où il n'y en a pas (un runner) : il peint l'écran d'une
  session, et modifie un fichier quand la session a son propre worktree — le panneau Git a un
  diff à montrer. Il écrit aussi une conversation inventée (deux échanges, du Markdown avec
  liste imbriquée, tableau et bloc de code, deux appels d'outils) dans
  `~/.claude/projects/loom-theme-tour/<id de la session>.jsonl`, là où Loom cherche celle
  d'une session native (ADR-0023) : c'est ce que montrent les écrans `chat` et `chat-narrow` (le
  même, à côté du navigateur : la demi-largeur où un tableau doit passer à la ligne). C'est le seul fichier
  que la tournée laisse hors de `LOOM_SUPPORT_DIR` ; le dossier se supprime sans rien casser.
- Les images vont dans `LOOM_TOUR_OUT`, un dossier par arrêt, avec `tour.json` (le design de
  chaque arrêt, ses écrans, les échecs). `screencapture` lit l'écran : il faut que le terminal
  qui lance la tournée y soit autorisé (Réglages Système › Confidentialité › Enregistrement de
  l'écran) ; sinon `LOOM_TOUR_CAPTURE=view` fait dessiner la fenêtre elle-même, sans flou ni
  feuilles.

En CI : Actions › CI › Run workflow, `themes` coché (et `themes_plan` pour un autre plan). Le
job agrandit l'écran du runner, joue la tournée et rend les images dans l'artefact
`theme-tour`.

## Les thèmes d'essai

`themes/*.css` sont dix exports « Tailwind v4 / oklch » de préréglages de
[tweakcn](https://github.com/jnsahaj/tweakcn) (Apache-2.0), choisis pour ce qu'ils poussent à
bout :

| Thème | Ce qu'il éprouve |
| --- | --- |
| `default` | le shadcn de base : rayon 0,625rem, polices système, ombre douce |
| `neo-brutalism` | rayon 0, ombre dure 4 px 4 px opaque, DM Sans + Space Mono |
| `claymorphism` | rayon 1,25rem, ombre diffuse avec étalement, bord de la couleur de la barre latérale |
| `violet-bloom` | rayon 1,4rem, espacement 0,27rem, interlettrage −0,025em |
| `notebook` | police manuscrite à une seule graisse, interlettrage 0,5px |
| `mono` | une mono large pour tout le texte, primaire gris moyen, sans ombre |
| `kodama-grove` | serif large (Merriweather), ombre décalée |
| `pastel-dreams` | rayon 1,5rem, couleurs pâles |
| `sage-garden` | espacement 0,23rem |
| `bubblegum` | Poppins (graisses hors famille), ombre dure 3 px |
