# Écrire une extension Loom

Une extension est une page web (HTML, CSS, JavaScript — n'importe quel
framework, avec ou sans build) que Loom affiche dans l'onglet **Extensions** et
qui parle à Loom par `window.loom`. Exemple complet et commenté :
[`Examples/extensions/jira-board/`](../Examples/extensions/jira-board/) — un
board Jira qui démarre une session depuis un ticket. Le pourquoi et les limites
de sécurité : [ADR-0011](adr/0011-extensions-web-isolees.md).

## En cinq minutes

```
mon-extension/
├── loom-extension.json
├── index.html
└── app.js
```

```json
{
  "id": "dev.moi.hello",
  "name": "Hello",
  "version": "0.1.0",
  "loomApi": 1,
  "permissions": { "sessions": ["read"] }
}
```

```html
<!doctype html>
<meta charset="utf-8">
<ul id="sessions"></ul>
<script src="app.js" defer></script>
```

```js
// app.js
async function render() {
  const list = document.getElementById("sessions");
  const sessions = await loom.sessions.list();
  list.replaceChildren(...sessions.map((s) => {
    const li = document.createElement("li");
    li.textContent = `${s.title} — ${s.state}`;
    return li;
  }));
}
loom.on("sessions.changed", render);
render();
```

Puis, dans Loom : **Réglages › Extensions › Link folder (development)…**,
choisir le dossier, approuver les permissions. L'onglet **Extensions** apparaît
dans la barre du haut. Après une modification, le bouton ↻ de la vue (ou
**Reload** dans les réglages) relit le manifeste et recharge la page. Une
extension liée est inspectable : clic droit › *Inspect Element* ouvre le Web
Inspector de Safari.

**Install from folder…** copie le dossier dans
`~/Library/Application Support/Loom/extensions/installed/<id>/` ; **Link**
le sert en place, pour le développement.

## Le manifeste — `loom-extension.json`

| Clé | Obligatoire | Rôle |
|---|---|---|
| `id` | oui | Reverse-DNS en minuscules (`dev.acme.jira-board`) : c'est l'hôte de l'origine de la page, `loom-ext://<id>/`. |
| `name`, `version` | oui | Affichés dans Loom. |
| `loomApi` | oui | Version du pont visée. Loom parle la **1** ; une autre version est refusée. |
| `entry` | non | Page d'entrée, relative au dossier. Défaut : `index.html`. |
| `description`, `author` | non | Affichés à l'installation. |
| `icon` | non | Nom d'un SF Symbol (`rectangle.split.3x1`). |
| `permissions` | non | Voir ci-dessous. Une clé inconnue fait refuser le manifeste. |
| `contributes.commands` | non | `[{ "id": "refresh", "title": "Refresh the board" }]` : commandes listées dans ⌘K. En lancer une ouvre l'extension et lui envoie l'événement `command`. |

## Les permissions

L'utilisateur voit chaque permission en clair avant d'installer. Un manifeste
mis à jour qui en demande davantage attend une nouvelle approbation avant de
tourner ; en retirer n'en demande pas.

| Permission | Donne accès à |
|---|---|
| `"network": ["api.exemple.com", "*.atlassian.net"]` | `loom.http.fetch` vers ces hôtes, en HTTPS uniquement. `*.x.y` couvre les sous-domaines, pas `x.y` lui-même. Ni `*`, ni `*.com`, ni adresse IP, ni port. |
| `"sessions": ["read"]` | `loom.sessions.list/get/open` et les événements de sessions. |
| `"sessions": ["launch"]` | `loom.sessions.launch` — l'utilisateur confirme chaque lancement. |
| `"projects": ["read"]` | `loom.projects.list` : identifiants et noms des projets (jamais leurs chemins). |

Sans permission : le stockage de l'extension (`loom.storage`), ses secrets
(`loom.secrets`), `loom.info`, `loom.ui.openExternal`.

## Ce que la page peut faire, et ce qu'elle ne peut pas

La page tourne dans un `WKWebView` à elle : process sandboxé par WebKit, aucun
cookie partagé avec le navigateur de Loom, rien de persistant hors de
`loom.storage`. Chaque fichier servi porte cette politique de contenu :

```
default-src 'none'; script-src 'self' loom-ext:; style-src 'self' loom-ext: 'unsafe-inline';
img-src 'self' loom-ext: data: blob:; font-src 'self' loom-ext: data:; media-src 'self' loom-ext: data: blob:;
connect-src 'self' loom-ext:; frame-src 'none'; child-src 'none'; worker-src 'none';
object-src 'none'; base-uri 'none'; form-action 'none'
```

En pratique :
- **Tout vient du dossier** : scripts, styles, polices, images. Pas de CDN —
  embarquez vos dépendances (un bundler produit un dossier qui convient).
- **Pas de script inline ni d'`eval`** : `<script src="…">` seulement ; pas de
  `onclick="…"` dans le HTML (utilisez `addEventListener`).
- **Pas de réseau direct** : `fetch("https://…")`, une image distante, un
  WebSocket sont bloqués (deux fois : la politique, puis une liste de blocage
  WebKit). Passez par `loom.http.fetch`.
- **Pas d'iframe, pas de nouvelle fenêtre** ; `alert`/`confirm` ne s'affichent pas.
- **Liens** : un lien `https://` *cliqué par l'utilisateur* s'ouvre dans son
  navigateur ; une navigation lancée par un script ne va nulle part.
- **Pas un contexte sécurisé** : `crypto.subtle` peut manquer. `btoa` et
  `TextEncoder` suffisent pour une authentification Basic (voir l'exemple Jira).
- **Données tierces** : un ticket, un commentaire sont écrits par d'autres —
  rendez-les avec `textContent`, jamais `innerHTML`.

## L'API — `window.loom`

Types complets : [`Examples/extensions/loom.d.ts`](../Examples/extensions/loom.d.ts)
(`/// <reference path="…/loom.d.ts" />` et `// @ts-check` dans un fichier JS).
Chaque appel renvoie une promesse ; un refus la rejette avec une `LoomError`
dont `code` vaut `invalidRequest`, `unknownMethod`, `invalidParams`,
`forbidden`, `notFound`, `conflict`, `network`, `tooLarge` ou `internalError`.

| Appel | Permission | Résultat |
|---|---|---|
| `loom.info()` | — | `{ loomApi, appVersion, extensionId, theme }` |
| `loom.projects.list()` | `projects: read` | `[{ id, name }]` |
| `loom.sessions.list({ includeArchived? })` | `sessions: read` | `[Session]` — la projection de l'API agents : `id, title, state, projectID, branch, worktreePath, badges, createdAt` |
| `loom.sessions.get(id)` | `sessions: read` | `Session` |
| `loom.sessions.open(id)` | `sessions: read` | Affiche une session vivante dans Loom. |
| `loom.sessions.launch({ prompt, projectId?, title?, badges?, placement? })` | `sessions: launch` | `{ launched, sessionId? }` — voir ci-dessous. |
| `loom.http.fetch(url, { method?, headers?, body? })` | `network` | `{ status, ok, url, headers, body, bodyEncoding, text(), json() }` |
| `loom.secrets.get/set/delete(key[, value])` | — | Trousseau macOS, propre à l'extension. Clé : 1–64 caractères `A-Z a-z 0-9 . _ -` ; valeur ≤ 8 Ko. |
| `loom.storage.get/set/delete(key[, value])` | — | Toute valeur JSON ; 1 Mo au total pour l'extension. |
| `loom.ui.openExternal(url)` | — | Ouvre une URL `https://` dans le navigateur de l'utilisateur. |
| `loom.on(event, callback)` | selon l'événement | Renvoie une fonction de désabonnement. |
| `loom.call(method, params)` | — | L'appel brut, pour une méthode que le SDK n'enveloppe pas. |

### Lancer une session

```js
const result = await loom.sessions.launch({
  projectId,                       // d'un loom.projects.list() ; modifiable dans la feuille
  prompt: "Corrige PROJ-42 : …",   // ce que claude reçoit — affiché, modifiable
  title: "PROJ-42 · Login cassé",
  badges: ["PROJ-42"],
  placement: "worktree",           // ou "folder" ; défaut : le choix du projet
});
if (result.launched) remember(result.sessionId);
```

Loom ouvre une feuille native qui montre tout — projet, placement, titre,
badges, prompt — et **rien ne démarre sans le clic de l'utilisateur** ; annuler
renvoie `{ launched: false }`. L'appel n'est accepté que si l'extension est
affichée au premier plan (sinon `forbidden`), et un seul lancement attend à la
fois (sinon `conflict`).

### `http.fetch`

```js
const response = await loom.http.fetch("https://acme.atlassian.net/rest/api/3/myself", {
  headers: { Authorization: "Basic " + btoa(email + ":" + token), Accept: "application/json" },
});
if (response.ok) console.log(response.json());
```

Un `body` objet part en JSON (avec `Content-Type: application/json`). Les
en-têtes `Cookie`, `Host`, `Origin`, `Sec-*`, `Proxy-*` sont retirés ; aucune
réponse ne dépose de cookie. Plafonds : 1 Mo envoyé, 8 Mo reçus, 30 s.
Une redirection vers un hôte non déclaré n'est pas suivie : la réponse 3xx
revient telle quelle. Un corps non textuel revient en base64
(`bodyEncoding: "base64"`) ; `text()` le décode.

### Événements

| Événement | Charge utile | Permission |
|---|---|---|
| `session.stateChanged` | `{ sessionId, state, previous }` | `sessions: read` |
| `sessions.changed` | `{ sessions: [Session] }` — à chaque changement (titre, badge, session ouverte ou fermée) | `sessions: read` |
| `theme.changed` | `{ isLight, tokens }` | — |
| `command` | `{ id }` — une commande du manifeste lancée depuis ⌘K | — |
| `*` | `(name, payload)` — tous | — |

### Le thème

Les 16 couleurs du thème de Loom sont posées sur `<html>` en variables CSS
`--loom-<nom>` et suivent les changements en direct :
`--loom-background`, `--loom-content-background`, `--loom-surface`,
`--loom-surface-raised`, `--loom-card-border`, `--loom-accent`,
`--loom-accent-text`, `--loom-primary-text`, `--loom-secondary-text`,
`--loom-muted-text`, `--loom-branch`, `--loom-danger`, `--loom-group-header`,
`--loom-state-working`, `--loom-state-needs-input`, `--loom-state-idle`.
`<html data-loom-appearance="light|dark">` et `color-scheme` sont posés aussi.
Prévoyez des valeurs de repli (`var(--loom-accent, #7c83ff)`) : la page reste
lisible hors de Loom.

## Tester hors de Loom

`Examples/extensions/tests/` montre comment : le SDK et la politique de
contenu sont lus depuis les sources Swift, la page tourne dans Chromium
(Playwright) avec un faux pont `webkit.messageHandlers.loom` qui répond comme
Loom — et, pour l'exemple, comme Jira.

```sh
cd Examples/extensions
npm test              # node --test tests/*.test.mjs
npm run typecheck     # tsc --checkJs sur l'exemple Jira
```

## Où vivent les données

| Quoi | Où |
|---|---|
| Extensions installées | `~/Library/Application Support/Loom/extensions/installed/<id>/` |
| Activation, permissions accordées, dossiers liés | `…/extensions/state.json` |
| `loom.storage` | `…/extensions/data/<id>/storage.json` |
| `loom.secrets` | Trousseau de session, service `app.loom.extension.<id>` |

Supprimer une extension efface sa copie, son stockage et ses secrets — jamais
le dossier source d'une extension liée.
