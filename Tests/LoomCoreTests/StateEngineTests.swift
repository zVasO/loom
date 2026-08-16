import Testing
import LoomCore

// Tests at the agreed seam: StateEngine's public interface, nothing else.
// Expected values come from the spec (STA-01→05) and the prototype's verdict
// (docs/research/state-engine-prototype.md), not from the code.

@Suite("StateEngine — hooks / heuristics fusion")
struct StateEngineTests {
    let t0 = ContinuousClock().now

    @Test("a submitted prompt (hook) moves the session to working")
    func promptSoumisPasseEnWorking() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        #expect(s.session == .working)
    }

    @Test("a heuristic does not overwrite a hook-set state within 10 s (STA-03)")
    func heuristiqueRejeteeDansLaFenetreHook() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(4)))
        #expect(s.session == .working, "the agent is thinking silently: PTY silence must not conclude idle")
    }

    @Test("outside the hook window, a heuristic sustained at least 2 s applies (STA-02)")
    func heuristiqueAppliqueeApresHysterese() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(11)))
        #expect(s.session == .working, "first detection = a proposal, not yet a transition")
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .milliseconds(13_500)))
        #expect(s.session == .idle, "silence sustained 2.5 s outside the hook window: the session is idle")
    }

    @Test("a stale proposal does not count as a sustained observation (STA-02)")
    func propositionPerimeeNeSAppliquePas() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(100)))
        #expect(s.session == .working,
                "100 s without any observation: the initial proposal is stale, not confirmed")
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .milliseconds(102_500)))
        #expect(s.session == .idle, "the proposal restarted at t+100 s, sustained 2.5 s, applies")
    }

    @Test("process exit concludes: code 0 → completed, code ≠ 0 → failed (STA-05)")
    func exitDuProcessConclut() {
        var ok = StateEngine.State(session: .working)
        ok = StateEngine.reduce(ok, .process(.exited(code: 0)), at: t0)
        #expect(ok.session == .completed)

        var ko = StateEngine.State(session: .working)
        ko = StateEngine.reduce(ko, .process(.exited(code: 2)), at: t0)
        #expect(ko.session == .failed)
    }

    @Test("a terminal state absorbs late signals")
    func etatTerminalAbsorbant() {
        var s = StateEngine.State(session: .completed)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        #expect(s.session == .completed, "a late hook does not resurrect a finished session")
    }

    @Test("Stop classifies the turn end: question → needs_input, otherwise → idle")
    func stopClasseLaFinDeTour() {
        var q = StateEngine.State(session: .working)
        q = StateEngine.reduce(q, .hook(.stop(awaitsReply: true)), at: t0)
        #expect(q.session == .needsInput, "\"… which one do you prefer?\" must badge the card")

        var done = StateEngine.State(session: .working)
        done = StateEngine.reduce(done, .hook(.stop(awaitsReply: false)), at: t0)
        #expect(done.session == .idle)
    }

    @Test("a permission request badges immediately, no delay (STA-04)")
    func permissionBadgeImmediatement() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .hook(.permissionRequested), at: t0)
        #expect(s.session == .needsInput)
    }

    @Test("archiving a finished session: the only action that crosses a terminal state (SES-07)")
    func archivageDepuisTerminal() {
        var s = StateEngine.State(session: .completed)
        s = StateEngine.reduce(s, .user(.archive), at: t0)
        #expect(s.session == .archived, "the nominal archive case IS the finished session")

        var live = StateEngine.State(session: .idle)
        live = StateEngine.reduce(live, .user(.archive), at: t0)
        #expect(live.session == .archived, "a live session can be archived too")
    }

    @Test("app shutdown interrupts, and only an interrupted session can resume (UC-7)")
    func interruptionPuisReprise() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .process(.interrupted), at: t0)
        #expect(s.session == .interrupted, "app killed: the PTY is dead, the session is a Resume candidate")

        s = StateEngine.reduce(s, .user(.resume), at: t0.advanced(by: .seconds(30)))
        #expect(s.session == .starting, "Resume = relaunch via --resume, the session restarts")

        var idle = StateEngine.State(session: .idle)
        idle = StateEngine.reduce(idle, .user(.resume), at: t0)
        #expect(idle.session == .idle, "a live session does not \"resume\"")
    }
}
