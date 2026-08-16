import Testing
import LoomAgents

// Classification of the Stop hook's `last_assistant_message`: does the agent end
// its turn expecting a reply? Feeds StateEngine.AgentSignal.stop(endsWithQuestion:)
// — CONTEXT.md decision, validated by docs/research/claude-code-hooks.md §4.
// Fixtures: realistic Claude Code turn endings, not strings crafted for the
// implementation. French fixtures deliberately exercise the French marker path.

@Suite("Turn-end classification")
struct TurnEndClassifierTests {

    @Test("a turn ending with a direct question awaits a reply")
    func questionDirecte() {
        let message = """
        I identified two possible approaches for the cache:

        1. TTL invalidation, simple but approximate
        2. Event-driven invalidation, precise but more complex

        Which one do you prefer?
        """
        #expect(TurnEndClassifier.awaitsUserReply(message))
    }

    @Test("a question mark mid-message does not make a question")
    func interrogationEnMilieuDeMessage() {
        let message = """
        The test "what happens if the worktree is deleted?" was failing because of
        a hardcoded path. I fixed it by resolving the path from the fixture.

        All 42 tests pass, the fix is committed.
        """
        #expect(!TurnEndClassifier.awaitsUserReply(message),
                "the turn is over: the card must go idle, not demand an intervention")
    }

    @Test("an invitation to reply without a trailing question mark still awaits a reply")
    func invitationSansPointDInterrogation() {
        // Kept in French: exercises the French invitation markers ("dis-moi …").
        let fr = """
        Le correctif est prêt sur la branche, les tests passent.

        Dis-moi si tu veux que je l'applique aussi à la branche de release.
        """
        #expect(TurnEndClassifier.awaitsUserReply(fr))

        let en = """
        I've drafted both migration scripts in the worktree.

        Let me know which option you'd like and I'll proceed.
        """
        #expect(TurnEndClassifier.awaitsUserReply(en))
    }
}
