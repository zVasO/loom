import Testing
import BunshinAgents

// Classification du `last_assistant_message` du hook Stop : est-ce que l'agent
// termine son tour en attendant une réponse ? Alimente
// StateEngine.AgentSignal.stop(endsWithQuestion:) — décision CONTEXT.md, validée
// par docs/research/claude-code-hooks.md §4. Fixtures : messages réalistes de
// fins de tour Claude Code, pas des chaînes fabriquées pour l'implémentation.

@Suite("Classification de fin de tour")
struct TurnEndClassifierTests {

    @Test("un tour finissant par une question directe attend une réponse")
    func questionDirecte() {
        let message = """
        J'ai identifié deux approches possibles pour le cache :

        1. Invalidation par TTL, simple mais approximative
        2. Invalidation par événement, précise mais plus complexe

        Laquelle préfères-tu ?
        """
        #expect(TurnEndClassifier.endsWithQuestion(message))
    }

    @Test("un point d'interrogation en milieu de message ne fait pas une question")
    func interrogationEnMilieuDeMessage() {
        let message = """
        Le test « que se passe-t-il si le worktree est supprimé ? » échouait à cause
        d'un chemin en dur. Je l'ai corrigé en résolvant le chemin depuis la fixture.

        Les 42 tests passent, le correctif est committé.
        """
        #expect(!TurnEndClassifier.endsWithQuestion(message),
                "le tour est fini : la carte doit passer à idle, pas réclamer une intervention")
    }

    @Test("une invitation à répondre sans « ? » attend quand même une réponse")
    func invitationSansPointDInterrogation() {
        let fr = """
        Le correctif est prêt sur la branche, les tests passent.

        Dis-moi si tu veux que je l'applique aussi à la branche de release.
        """
        #expect(TurnEndClassifier.endsWithQuestion(fr))

        let en = """
        I've drafted both migration scripts in the worktree.

        Let me know which option you'd like and I'll proceed.
        """
        #expect(TurnEndClassifier.endsWithQuestion(en))
    }
}
