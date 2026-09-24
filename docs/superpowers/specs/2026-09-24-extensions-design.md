# Extensions tierces (onglet « Extensions »)

Date : 2026-09-24 · Statut : validé par l'utilisateur (technologie web, onglet dédié, lancement confirmé, livrable complet avec l'exemple Jira)

## But

Laisser des développeurs brancher leurs outils sur Loom sans que Loom ait à
les intégrer : un board Jira qui démarre une session depuis un ticket, une
boîte Sentry, un tableau de CI. Loom expose une API — le pont `window.loom` — et
une place — l'onglet **Extensions** — ; le reste appartient à l'extension.

## Décisions prises

- **Extensions web** : un dossier (manifeste + HTML/JS/CSS) servi dans un
  `WKWebView` isolé. Jamais de code tiers dans le process de l'app (ADR-0004 :
  app non sandboxée). ADR-0011.
- **Placement v1 : un onglet de premier niveau « Extensions »**, visible dès
  qu'une extension est installée ; une vue par extension. Les commandes du
  manifeste s'ajoutent à ⌘K (section « Extensions »).
- **Lancer une session : oui, toujours confirmé** par une feuille native
  (projet, placement, titre, badges, prompt modifiable), et seulement depuis
  l'extension affichée. ADR-0010 tient : jamais un simple jeton.
- **Permissions déclarées, consenties, strictes** : `network` (hôtes HTTPS),
  `sessions` (`read`, `launch`), `projects` (`read`). Clé inconnue ⇒ manifeste
  refusé. Manifeste qui demande plus ⇒ nouvelle approbation.
- **Aucune écriture d'état ni de métadonnée de session** en v1 : lecture,
  ouverture d'une session vivante, lancement confirmé.
- **Réseau par Loom seulement** (`http.fetch`), sans cookies ; la page elle-même
  n'a aucun accès réseau (CSP + content rule list).
- **Secrets au Trousseau**, stockage JSON plafonné hors du dossier de l'extension.
- **Exemple livré** : `Examples/extensions/jira-board/` (Jira Cloud, API token).

## Architecture

```
 page de l'extension (WKWebView, data store non persistant, loom-ext://<id>/)
   │  window.loom  ── SDK injecté au document-start (LoomSDKScript)
   │  webkit.messageHandlers.loom.postMessage(JSON) → Promise<JSON>
   ▼
 ExtensionMessageHandler (LoomWeb) ── refuse tout sauf la page principale de <id>
   ▼
 ExtensionBridge (LoomExtensions) ── décode, vérifie la permission, répond
   ├─ ExtensionAppServices (AppModel) : projets, sessions, lancement, ouverture
   ├─ ExtensionStorage : data/<id>/storage.json (1 Mo)
   ├─ SecretStore : Trousseau, service app.loom.extension.<id>
   └─ ExtensionHTTPClient : URLSession éphémère, hôtes du manifeste, HTTPS
 AppModel ──(onChange sessions / palette)──▶ ExtensionsModel ──emit──▶ window.__loomEmit
```

### LoomExtensions (nouveau target — LoomCore, LoomAPI)

- `ExtensionManifest` : `loom-extension.json`, `load(from:)`, `validate()` (id
  reverse-DNS minuscule ≤ 100, `entry` .html relatif sans `..` ni fichier caché,
  `loomApi == 1`, icône SF Symbol, commandes uniques). `ManifestError`.
- `ExtensionPermissions` : décodage strict, `missing(from:)`, `intersection(_:)`,
  `allows(_:)`, `summary` (phrases de la feuille de consentement).
- `HostPattern` : hôte exact ou `*.domaine.tld` ; `allows(url, patterns)` =
  https, port 443, sans identifiants.
- Protocole : `BridgeRequest`, `BridgeResponse` (`jsonText`), `BridgeError`
  (codes), `BridgeMethod` (+ `requirement`), modèles, `BridgeEvent`.
- `SessionChangeDetector` : instantanés → `session.stateChanged` + `sessions.changed`.
- `LoomSDKScript.source` (chaîne brute, colonne 0) ; `BridgeScripts.userScript(boot:)`,
  `emit(_:)` (l'événement voyage en littéral de chaîne JSON).
- `ExtensionWebPolicy` : schéma, CSP, content rule list, décisions de navigation,
  origine des messages. `ExtensionFileResolver` : URL → fichier du dossier.
- `ExtensionStorage`, `SecretStore` (`KeychainSecretStore`, `InMemorySecretStore`),
  `SecretPolicy`.
- `HTTPProxyPolicy`, `ExtensionHTTPClient`, `RedirectGuard`.
- `ExtensionBridge` (routeur, `@MainActor`) et `ExtensionAppServices`.
- `ExtensionRegistry` : `installed/`, `state.json`, `data/` ; `scan`, `inspect`,
  `install`, `link`, `remove`, `setEnabled`, `approve`, `storageFile(for:)`.

### LoomWeb (+ LoomExtensions)

- `ExtensionWebHost` (`@MainActor @Observable`) : configuration (store non
  persistant, scheme handler, message handler, user script), compilation de la
  rule list (fail closed), `load`, `reload`, `emit` (tampon jusqu'au
  `didFinish`), `updateUserScript`, `tearDown`. Délégués navigation et UI :
  `ExtensionWebPolicy.decide`.
- `ExtensionSchemeHandler` (synchrone, CSP sur chaque réponse, 404 sinon),
  `ExtensionMessageHandler` (`WKScriptMessageHandlerWithReply`).
- `ExtensionWebView` : conteneur dont la seule sous-vue est échangée.

### LoomApp

- `ExtensionsModel` : registre, hôtes créés à la première vue, ponts, feuille
  de consentement, lancement en attente (continuation résolue une fois),
  diffusion du thème et des sessions, commandes ⌘K.
- `ExtensionsAPI.swift` : `AppModel: ExtensionAppServices` (projection
  `APISession` partagée avec l'API agents) ; `publishSessionSnapshot()`.
- `AppModel.launchSession(…, title:, badges:)` : paramètres ajoutés avec défauts.
- Vues : `ExtensionsView`, `ExtensionLaunchSheet`, `ExtensionConsentSheet`,
  section Réglages › Extensions ; `MainTab.extensions`, `NavTab`, palette.

## Gestion des erreurs

- Manifeste illisible, id et dossier en désaccord, lien cassé : un
  `ExtensionProblem` listé dans les réglages ; le reste se charge.
- Rule list non compilable, navigation en échec : message dans la vue, bouton Retry.
- Pont : toujours une réponse `{id, error:{code, message}}`, jamais une exception
  qui traverse ; un refus avant répartition (mauvais cadre) rejette la promesse
  avec `"code: message"`, que le SDK convertit en `LoomError`.
- Process WebContent tué : rechargement.
- Lancement : annulé si l'extension est déchargée pendant que la feuille attend.

## Tests

Swift Testing (`Tests/LoomExtensionsTests/`) :
- `ManifestTests`, `HostPatternTests`, `PermissionsTests` : identifiants, entrées,
  versions, permissions inconnues, jokers, consentement, intersection.
- `BridgeProtocolTests`, `SessionChangeDetectorTests` : enveloppes, exigences,
  émission (aller-retour, titre hostile), script d'amorçage, détection.
- `WebPolicyTests` : fichiers servis et refusés (hôte étranger, `..`, encodé,
  caché, dossier, lien symbolique sortant), navigation, origine, rule list, CSP.
- `ExtensionStorageTests`, `SecretStoreTests` (Trousseau réel si `LOOM_KEYCHAIN_TESTS=1`).
- `HTTPProxyPolicyTests`, `ExtensionHTTPClientTests` (stub `URLProtocol`).
- `ExtensionBridgeTests` (faux `ExtensionAppServices`) : requête malformée,
  méthode inconnue, hors permission, lancement hors premier plan, stockage et
  secrets, réseau hors liste, ouverture externe.
- `ExtensionRegistryTests` : installation, consentement après mise à jour,
  jamais plus que demandé, désactivation, suppression (le dossier lié survit),
  conflits et problèmes, copie déposée à la main.

JavaScript (`Examples/extensions/tests/`, `npm test`) :
- `sdk.test.mjs` : le SDK extrait de la source Swift, sous Node (`vm`).
- `jira-board.test.mjs` : l'exemple dans Chromium (Playwright), avec la CSP
  extraite de la source Swift, un faux pont et un faux Jira.
- `npm run typecheck` : `tsc --checkJs --strict` contre `loom.d.ts`.

### Validation sur le Mac

1. `swift build 2>&1 | tee build.log` ; `grep -i "nearly matches" build.log` ne
   doit rien afficher (un délégué WebKit mal signé n'est jamais appelé).
2. `swift test --filter LoomExtensionsTests`, puis `swift test` ;
   `LOOM_KEYCHAIN_TESTS=1 swift test --filter SecretStoreTests` (accepter l'invite).
3. `LOOM_SUPPORT_DIR=/tmp/loom-ext swift run -c release LoomApp` ; Réglages ›
   Extensions › *Link folder* › `Examples/extensions/jira-board` : la feuille
   liste trois permissions ; après approbation, l'onglet Extensions apparaît.
4. Web Inspector sur la vue (clic droit › Inspect Element), dans la console :
   `fetch("https://example.com")` bloqué ; `new Image().src = "https://example.com/x"`
   bloqué (onglet Réseau) ; une iframe vers https bloquée ;
   `await loom.http.fetch("https://example.com")` → `forbidden` ;
   `await loom.call("nope")` → `unknownMethod` ; un lien `https://` cliqué
   s'ouvre dans le navigateur par défaut.
5. Avec un vrai Jira Cloud : configuration, board, colonnes, cartes ; choisir le
   projet Loom ; *Start a session* ouvre la feuille (prompt modifiable) ;
   *Cancel* → rien ne démarre ; *Launch* → session `KEY · résumé` avec le badge
   `KEY`, dont la pastille suit working → needs input → idle.
6. Console : `setTimeout(() => loom.sessions.launch({prompt: "x"}).catch(e => console.log(e.code)), 5000)`
   puis changer d'onglet : `forbidden`.
7. Changer de thème (⌘K) : l'extension se recolore en direct. ⌘K › *Refresh the
   Jira board* recharge le board.
8. Ajouter un hôte au manifeste lié puis *Reload* : l'extension attend une
   approbation. Désactiver : la vue s'arrête. Supprimer : Trousseaux d'accès
   ne trouve plus `app.loom.extension.dev.loom.jira-board`, `data/` a disparu,
   le dossier source est intact.
9. Moniteur d'activité : un process WebContent par extension ouverte, aucun avant.

## Hors périmètre

Extensions d'arrière-plan (sans vue), emplacements dans un projet ou le
panneau d'une session, `sessions.setTitle`/`setBadges`, catalogue, mises à
jour, signature, CLI `loom ext`, rechargement à chaud par FSEvents, images
distantes, `http://localhost`, secrets substitués côté natif (le jeton ne
passerait jamais par le JavaScript), WebSocket et SSE, notifications,
`alert`/`confirm`, OAuth Jira (3LO), reprise d'une session dormante depuis une
extension.
