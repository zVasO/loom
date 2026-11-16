# Les choix que claude demande dans son terminal se lisent sur l'écran et se répondent depuis le chat

Dans la vue conversation (ADR-0023), une demande de permission ne se voyait pas : un bandeau renvoyait au terminal, le seul endroit où claude la dessine. Le fichier de la conversation tient l'appel d'outil en attente, jamais les options proposées (« Yes », « Yes, and don't ask again for… », « No, and tell Claude… »), qui varient selon l'outil et la version de claude.

## Décision

**L'écran du terminal est lu, pas deviné.** `ClaudeTerminalPrompt.parse(lines:)` (LoomAgents, pur et testé) reconnaît, dans les dernières lignes de l'écran, un menu de claude : des options numérotées depuis 1 sans trou, au moins deux, l'une sous le marqueur `❯`, et rien dessous qu'une ligne vide ou une aide courte (« Esc to cancel »). La ligne au-dessus des options est la question ; les lignes au-dessus d'elle, jusqu'au bord du cadre, son contexte (l'outil, la commande, son explication). Une liste numérotée dans une réponse ne passe pas : la boîte de saisie de claude est dessous, et aucun marqueur n'y est.

**Le chat montre ce que l'écran montre, et tape ce que le clavier taperait.** `SessionChatPane` garde la surface du terminal attachée à cadence d'aperçu (200 ms) tant que la session vit, relit le menu quand l'écran change — hors du corps de la vue — et l'affiche en carte au-dessus du champ, un bouton par option. Un clic tape le numéro de l'option dans le terminal, comme on le ferait au clavier. Tant que la carte est là, le champ n'envoie rien : un message tapé répondrait au menu.

**Stop et Envoyer maintenant tapent Échap.** Pendant que claude travaille, Stop envoie Échap — l'interruption de claude. Envoyer maintenant fait de même, attend la fin du tour, puis envoie le message par `submitWhenReady` au lieu de le laisser en file derrière le tour.

## Conséquences

- Une demande dont le dessin change (une version de claude qui numérote autrement, un marqueur nouveau) n'est plus reconnue : le bandeau « claude is asking for a permission in the terminal » revient alors, comme avant.
- La surface attachée produit une image de l'écran toutes les 200 ms même pendant le travail de claude ; c'est le coût de l'aperçu d'une carte de Mission Control.
- Le chat suit aussi le fichier de la conversation par une surveillance du noyau (une source vnode) : ce que claude écrit s'affiche dès que c'est écrit, et le relevé périodique (1 à 2 s) ne reste que pour ce qu'elle manquerait. Un message envoyé s'affiche aussitôt, plus pâle, jusqu'à ce que le fichier le contienne.
