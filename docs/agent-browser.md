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

## Le profil

Le navigateur de l'agent n'a jamais vos cookies. Ses cookies et son stockage forment
le **profil web de l'agent** du projet, partagé par les sessions du projet et gardé
d'une session à l'autre : connectez-vous une fois à l'app testée (choisissez
« Agent browser » dans l'en-tête du panneau), l'agent le restera. Tout ce que vous
connectez ici, l'agent peut s'en servir — n'y ouvrez pas vos comptes personnels.

Une session sans projet et toute revue ou tout guide de PR ont un profil **privé**,
oublié à la fin. Les caches et service workers d'un profil de projet sont vidés au premier usage
de chaque lancement de Loom. **Réglages ▸ Agents ▸ Clear agent browser data** vide
tous les profils d'agent.

## Les outils

Les outils MCP `browser_*` suivent Playwright MCP, que les agents connaissent :

| Outil | Ce qu'il fait |
|---|---|
| `browser_navigate` | Ouvre une adresse (`localhost:5173` en http) et répond l'instantané |
| `browser_snapshot` | L'instantané de la page : l'arbre d'accessibilité, références `e12` comprises |
| `browser_click`, `browser_hover` | Clique, survole un élément (référence ou sélecteur CSS) |
| `browser_type`, `browser_select_option`, `browser_press_key` | Saisie, listes, touches |
| `browser_wait_for` | Attend un temps, ou qu'un texte apparaisse ou disparaisse |
| `browser_console_messages`, `browser_network_requests` | Console, erreurs, fetch/XHR |
| `browser_take_screenshot` | Capture de la page ou d'un élément, rendue en image |
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
- L'envoi de fichiers n'est pas encore là : un sélecteur de fichier attend
  `browser_handle_dialog`, qui l'annule.

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
isolé, la navigation limitée à http(s) et le profil privé des revues bornent ce
qu'elle obtiendrait. Le texte des pages, les instantanés et les captures restent
dans les transcripts de Claude Code (`~/.claude/projects`) et de Loom.
