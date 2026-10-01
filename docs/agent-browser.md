# Le navigateur de l'agent

Chaque session claude a son propre navigateur, que son agent pilote pour tester ce
qu'il construit : ouvrir le serveur de dev, cliquer, remplir, lire la console et les
requêtes, prendre une capture. La décision et ses garde-fous : [ADR-0014](adr/0014-navigateur-de-l-agent-isole-par-projet.md).

## Le regarder

- **Le panneau latéral** (bouton à droite du titre de la session, ou ⌘⇧B) affiche un
  navigateur à côté du terminal. Son en-tête choisit lequel : le navigateur de
  l'agent, ou un des navigateurs « Web n » de la pile, qui restent les vôtres.
- La première fois que l'agent touche une page, le panneau s'ouvre sur son
  navigateur — une seule fois, et seulement si le terminal garde ses 80 colonnes.
  Refermé par vous, il ne se rouvre plus de lui-même : un **point qui pulse** sur le
  bouton dit que l'agent travaille hors de vue, et le clic vous le montre.
- Pendant une commande, une pastille en haut de la page dit ce que fait l'agent.
  Un dialogue de la page (`alert`, `confirm`, `prompt`) s'affiche en bandeau
  « <hôte> says: » : l'agent ou vous pouvez y répondre.
- La carte de la session dans la barre latérale montre un globe quand son agent
  navigue ; dans l'onglet PR, l'en-tête du tiroir aussi.
- **La largeur de la page** : le menu à droite de la légende (« Fit », 1024 px,
  1280 px). Le terminal garde ses 80 colonnes, le panneau est souvent étroit :
  sans cela, l'agent testerait la mise en page mobile. Une largeur choisie est
  mise à l'échelle dans le panneau et retenue pour le projet ; l'agent la règle
  lui-même avec `browser_resize`.

## Le profil

Le navigateur de l'agent n'a jamais vos cookies. Ses cookies et son stockage forment
le **profil web de l'agent** du projet, partagé par les sessions du projet et gardé
d'une session à l'autre : connectez-vous une fois à l'app testée (choisissez
« Agent browser » dans l'en-tête du panneau), l'agent le restera. Tout ce que vous
connectez ici, l'agent peut s'en servir — n'y ouvrez pas vos comptes personnels.

Une session sans projet et toute revue ou tout guide de PR ont un profil **privé**,
oublié à la fin. Les caches et service workers d'un profil de projet sont vidés au
premier usage de chaque lancement de Loom, avant qu'une de ses pages ne charge.
Retirer un projet supprime son profil (au lancement suivant si une session s'en
sert encore). **Réglages ▸ Agents ▸ Clear agent browser data** vide tous les
profils d'agent.

## Sites locaux seulement

**Réglages ▸ Agents ▸ Agent browser: local sites only** (désactivé par défaut)
borne les navigateurs d'agent aux adresses de votre machine — `localhost`,
`127.0.0.1`, `*.localhost`, `[::1]` — et aux hôtes que vous listez dessous
(`api.example.com`, `*.staging.example.com`) : l'API ou la page de connexion dont
l'app testée a besoin. Pages, scripts, images, requêtes et WebSockets passent tous
par ces règles, appliquées par WebKit, donc hors de portée de l'agent comme de la
page. Une page refusée l'est avec un mot dans `### Events`. Le réglage vaut
aussitôt pour les chargements suivants ; si les règles ne peuvent être mises en
place, rien ne charge.

## Les outils

Les outils MCP `browser_*` suivent Playwright MCP, que les agents connaissent :

| Outil | Ce qu'il fait |
|---|---|
| `browser_navigate` | Ouvre une adresse (`localhost:5173` en http) et répond l'instantané |
| `browser_snapshot` | L'instantané de la page : l'arbre d'accessibilité, références `e12` comprises |
| `browser_click`, `browser_hover` | Clique, survole un élément (référence ou sélecteur CSS) |
| `browser_type`, `browser_select_option`, `browser_press_key` | Saisie (`slowly` : touche par touche, pour une autocomplétion), listes, touches |
| `browser_fill_form` | Plusieurs champs d'un coup : textes, cases, listes, curseurs |
| `browser_file_upload` | Répond au sélecteur de fichier que la page a ouvert |
| `browser_resize` | La largeur de la page en pixels CSS (375, 768, 1280…), mise à l'échelle dans le panneau |
| `browser_wait_for` | Attend un temps, ou qu'un texte apparaisse ou disparaisse |
| `browser_console_messages`, `browser_network_requests` | Console, erreurs, fetch/XHR |
| `browser_take_screenshot` | Capture de la page visible, d'un élément ou de toute la page (`fullPage`), rendue en image |
| `browser_evaluate` | Une fonction JavaScript dans la page, son résultat en JSON |
| `browser_handle_dialog`, `browser_tabs`, `browser_navigate_back`, `browser_close` | Le reste |

Chaque action répond l'instantané de la page qui en résulte. Depuis un shell :
`loom browser navigate localhost:5173`, `loom browser click e12`,
`loom browser take_screenshot --out shot.png` — `loom docs` donne tout.

## Les limites

- Les événements sont synthétiques : pas de `:hover` CSS, pas de glisser natif ;
  Tab, Entrée, Espace et le défilement sont émulés. Un code qui exige
  `event.isTrusted` les refuse.
- Les iframes d'une autre origine ne sont pas inspectables.
- Panneau masqué, la page tourne mais WebKit suspend son rendu (animations,
  `requestAnimationFrame`) : `### Page` l'indique.
- Les captures ne voient pas WebGL ni la vidéo.
- Une capture pleine page fait défiler la page tranche par tranche, puis la
  remet où elle était : un en-tête fixe apparaît dans chaque tranche, et au-delà
  de 8 000 pixels CSS la capture s'arrête.
- `browser_file_upload` ne prend que des fichiers du dossier de travail de la
  session, ou du dossier que son refus indique (Loom y range ce que l'agent veut
  envoyer d'ailleurs) : envoyer un fichier à une page, c'est le faire sortir de
  la machine.

## Dépannage

- « nothing is listening on localhost:5173 » : le serveur de dev ne tourne pas.
- Un serveur en https auto-signé échoue ; un serveur de dev local parle http.
- En développement (`swift run`, sans Info.plist), préférez `localhost` à
  `127.0.0.1` : App Transport Security peut refuser une adresse IP en http.
- Les outils n'apparaissent pas : une session déjà lancée les reçoit à sa reprise.

## Sécurité et confidentialité

Les outils de Loom tournent sans demande de permission par défaut (Réglages ▸
Agents ▸ Run Loom's tools without asking), pour qu'un test ne s'arrête pas à
chaque clic. Une page peut chercher à manipuler l'agent par son texte : le profil
isolé, la navigation limitée à http(s), le profil privé des revues et, si vous
l'activez, le mode sites locaux bornent ce qu'elle obtiendrait — avec lui, ce
que l'agent a lu ne peut partir que vers votre machine et les hôtes listés. Le texte des pages, les instantanés et les captures restent
dans les transcripts de Claude Code (`~/.claude/projects`) et de Loom.
