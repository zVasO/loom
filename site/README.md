# Landing page de Loom

Page statique, sans build : `index.html` (HTML, CSS et JS inline) et `favicon.svg`
(copie de `Assets/loom-icon-small.svg`). Seule dépendance externe : Geist et
Geist Mono via Google Fonts, avec repli système.

```sh
python3 -m http.server -d site 8080   # puis http://localhost:8080
```

Déploiement : servir le dossier `site/` tel quel (GitHub Pages, Netlify, S3…).

## Design system

- Surfaces : noir OLED `#000000`, zinc `#09090b` / `#121214`, bordures hairline
  `rgba(255,255,255,.08)`.
- Couleurs : tokens de **Loom Dark** (`Sources/LoomUI/ThemeStore.swift`). Accent
  unique `#E8945C` réservé aux CTA et états actifs ; la sémantique des états
  (`working` `#4CC38A`, `needs_input` `#E5B455`, `idle` `#6AA2E8`, échec
  `#E5646C`) ne sert qu'aux badges de statut, comme dans l'app.
- Type : Geist pour le texte, Geist Mono en capitales pour données, compteurs et
  métadonnées.
- Motion : 150–200 ms, `cubic-bezier(0.16, 1, 0.3, 1)`, spotlight au survol des
  cartes, `prefers-reduced-motion` respecté.
- Icônes : tracés Lucide inline, `stroke-width: 1.5`.

Interactif : la démo Mission control simule des transitions d'état (cliquer
« Répondre » / « Reprendre », ↑↓ et ↵ au clavier), la palette s'ouvre avec
⌘K, Ctrl+K ou `/`.
