# Chromium headless pour le navigateur de l'agent, piloté par le protocole DevTools

L'ADR-0014 donne à chaque agent un navigateur WebKit, piloté par des scripts injectés et des événements synthétiques. À l'usage, l'agent qui s'en sert bute sur trois limites que WebKit ne permet pas de lever :
- WebKit suspend le rendu d'une vue hors écran (rAF, animations, observers), donc d'un panneau caché.
- Les événements sont synthétiques : `isTrusted` est faux, `:hover` ne s'applique pas, pas de séquence pointer native.
- Chaque action attend environ 450 ms de pauses fixes : WebKit ne signale ni les requêtes ni les navigations qu'une action déclenche.

**Décision.** Le navigateur de l'agent, et seulement lui, devient un Chromium headless piloté par le Chrome DevTools Protocol (CDP). Les navigateurs de l'utilisateur (« Web n », WEB-01) restent sur WKWebView, inchangés.

**Transport et lancement.**
- `--remote-debugging-pipe` : fd 3 et 4, JSON terminé par `\0`. Jamais de port : aucun autre processus ne peut piloter un profil qui porte des sessions.
- Lancement par `posix_spawn` avec `POSIX_SPAWN_CLOEXEC_DEFAULT`.
- Chromium s'arrête quand Loom ferme sa fin du tuyau, plantage de Loom compris.

**Processus et profils.**
- **Un processus par profil de projet**, que le verrou `SingletonLock` impose, partagé par les sessions du projet comme cibles distinctes, chacune avec `newWindow:true`.
- **Un processus privé partagé** pour les revues et les sessions sans projet, avec un contexte de navigation jetable par session.

**Exécution des commandes.**
- Le helper d'instantané de l'ADR-0014 est injecté dans un monde isolé `loom-agent`.
- Les entrées passent par `Input.*` : des événements de confiance.
- L'attente après une action suit les événements du protocole (navigation demandée, chargement, requêtes XHR/Fetch), sans pause fixe.

**Panneau.** Il montre la page par `Page.startScreencast` et relaie souris, clavier, IME et presse-papiers de la personne.

**Choix du moteur.**
- Il est fixé au lancement ou à la reprise d'une session : `LOOM_BROWSER_ENGINE` dans l'environnement de `loom mcp`. La liste des outils et leurs mots sont figés au démarrage du serveur MCP.
- Le réglage offre Automatique (par défaut), Chromium ou WebKit. Sans Chromium, c'est WebKit, qui reste le repli.

**Binaire.** `chrome-headless-shell`, choisi d'office : celui que Loom télécharge **sur un clic** dans les Réglages (Chrome for Testing, version épinglée avec sa taille et son SHA-256 dans l'app, jamais mis à jour seul), sinon celui du cache de Playwright. Un navigateur complet (Chrome for Testing, Chromium, Chrome, Edge) ne sert que choisi par la personne : il se met à jour sous Loom, suit les politiques de sa marque, contacte ses services en arrière-plan, et confie les liens `mailto:` et `news:` d'une page aux apps du système (mesuré ; aucune commande CDP ne l'en empêche, le mode sites locaux non plus) — les Réglages le disent quand il est choisi ; le shell ne le fait jamais. Brave n'est jamais pris d'office.

**Alternatives rejetées :**
- Garder WebKit en réduisant ses pauses : sans événements de navigation ni de réseau, les réduire rend les actions incertaines, et le rendu suspendu demeure.
- Un Chromium avec fenêtre : une fenêtre hors de Loom et une icône dans le Dock, déjà rejetées par l'ADR-0014.
- CEF embarqué : environ 200 Mo dans le bundle, une compilation et une notarisation lourdes.
- Playwright lancé à côté : il dépend de Node, et l'ADR-0014 l'a déjà rejeté.

## Consequences

- **WEB-07 :** la révision de l'ADR-0014 vaut pour les deux moteurs du navigateur de l'agent.
- **ADR-0014, parties caduques sous Chromium :**
  - les trois limites du contexte : événements synthétiques, `:hover`, rendu suspendu panneau caché ;
  - les captures pleine page par tranches ;
  - les règles de contenu WebKit du mode sites locaux.

  Elles restent vraies sous WebKit.
- **Mode sites locaux sous Chromium :**
  - le proxy est une socket de Loom sur `127.0.0.1:0` qui accepte puis ferme chaque connexion. Un port « mort » pourrait être pris par un autre processus ;
  - `--proxy-bypass-list` porte `<-loopback>`, la boucle locale explicite et les hôtes autorisés ;
  - QUIC est coupé, WebRTC limité au proxy, la résolution DNS anticipée coupée ;
  - changer le mode ou la liste relance le processus du projet : les pages rechargent, comme sous WebKit ;
  - fermé par défaut : aucun lancement tant que la socket n'écoute pas.
- **Profils sur disque :** un `--user-data-dir` par identifiant de store de projet, sous `agent-browser/chromium/` du dossier de support.
  - Les logins ne passent pas d'un moteur à l'autre.
  - Clear agent browser data et retirer un projet couvrent les deux moteurs.
  - `--use-mock-keychain` laisse les cookies lisibles sur disque. C'est la parité avec WebKit, que l'ADR-0014 accepte déjà.
- **Aucun trafic propre à Chromium :** composants, essais de terrain, Safe Browsing, traduction et métriques sont coupés.
  - Un test vérifie que `--no-sandbox`, `--remote-debugging-port`, `--enable-automation` et `--disable-popup-blocking` ne sont jamais passés.
  - NFR-S : rien n'est téléchargé sans un clic. La version téléchargée est épinglée, avec son SHA-256, dans chaque release.
- **Option `snapshot: "none"` :** les actions peuvent omettre l'instantané de leur réponse (opt-in). La réponse par défaut reste celle de Playwright MCP.
- **Largeur de page :** chaque projet a une largeur par défaut. `browser_resize` ne change que la session.
- **`browser_run_code` :** il n'existe que sous Chromium.
  - Le script de l'agent tourne dans une cible « runner » hors ligne, dans un contexte de navigation séparé, et non dans Loom.
  - Ses appels `page.*` passent par les primitives du moteur, avec les mêmes politiques.
  - Un script qui boucle est arrêté par `Runtime.terminateExecution`.
  - Il est pré-autorisable : il ne donne rien de plus que `browser_evaluate`, les actions et `browser_file_upload` réunis, mais il en enchaîne beaucoup sans instantané intermédiaire. La pastille d'activité montre chaque étape.
- **Mémoire (NFR-M) :** un processus par projet actif, fermé 60 s après sa dernière session ou son dernier panneau.
- **Presse-papiers :** Chromium en garde un par processus, partagé par tous ses contextes — donc par les sessions d'un projet, et par les sessions privées du processus partagé. Les commandes `copy`, `cut` et `paste` ne figurent donc jamais dans les touches de l'agent, et le coller de la personne passe par un événement `paste` et `Input.insertText`, jamais par ce presse-papiers.
- **Panneau interactif :** l'agent passe d'abord. Quand une commande commence, ce que la personne tient remonte et sa saisie attend, avec un avis ; la prise de main est annoncée au fil principal sans être attendue, pour ne rien ajouter à la latence de l'agent. Une réponse suivante dit une fois à l'agent que la personne a utilisé la page. La page ne prend le clavier que sur un clic en elle. Un `<select>` s'ouvre en menu Mac, la liste de Chromium n'apparaissant dans aucune image.
- **Régressions acceptées :**
  - Pas d'outils de développement pour la personne : aucun port.
  - VoiceOver ne lit qu'une image ; WebKit reste sélectionnable pour qui en a besoin.
  - Des connexions Google ou Microsoft peuvent refuser un navigateur automatisé.
  - Glisser-déposer HTML natif et dépôt de fichiers depuis le Finder ne sont pas relayés dans le panneau.
