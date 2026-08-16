# Prototype StateEngine — verdict

**Question posée** : la fusion « hook prioritaire 10 s + hystérésis heuristique 2 s » (STA-02/STA-03) produit-elle l'état juste quand les signaux se contredisent ?

**Verdict (2026-08-14)** : oui. Le réducteur pur `(état, événement horodaté) → état` tient les six scénarios adverses (hook vs heuristique dans la fenêtre, faux positif annulé par hystérésis, question en fin de tour via `last_assistant_message`, permission immédiate sans délai, crash → interrupted → reprise, états terminaux absorbants). Vérifié par 17 assertions Node sur le module extrait.

**Source primaire** : le prototype vit sur la branche `prototype/state-engine` (`prototypes/state-engine.PROTOTYPE.html`, fichier autonome à double-cliquer). Le réducteur validé est à porter tel quel en Swift dans `LoomCore` (premier cycle TDD).
