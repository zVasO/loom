import Testing
import BunshinCore

// Tests au seam convenu : l'interface publique de StateEngine, rien d'autre.
// Les valeurs attendues viennent du cahier des charges (STA-01→05) et du verdict
// du prototype (docs/research/state-engine-prototype.md), pas du code.

@Suite("StateEngine — fusion hooks / heuristiques")
struct StateEngineTests {
    let t0 = ContinuousClock().now

    @Test("un prompt soumis (hook) passe la session en working")
    func promptSoumisPasseEnWorking() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        #expect(s.session == .working)
    }

    @Test("une heuristique n'écrase pas un état posé par un hook dans les 10 s (STA-03)")
    func heuristiqueRejeteeDansLaFenetreHook() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(4)))
        #expect(s.session == .working, "l'agent réfléchit en silence : le silence PTY ne doit pas conclure idle")
    }

    @Test("hors fenêtre hook, une heuristique maintenue au moins 2 s s'applique (STA-02)")
    func heuristiqueAppliqueeApresHysterese() {
        var s = StateEngine.State(session: .starting)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(11)))
        #expect(s.session == .working, "première détection = proposition, pas encore une transition")
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .milliseconds(13_500)))
        #expect(s.session == .idle, "silence maintenu 2,5 s hors fenêtre hook : la session est idle")
    }

    @Test("une proposition périmée ne compte pas comme observation soutenue (STA-02)")
    func propositionPerimeeNeSAppliquePas() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0)
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .seconds(100)))
        #expect(s.session == .working,
                "100 s sans aucune observation : la proposition initiale est périmée, pas confirmée")
        s = StateEngine.reduce(s, .heuristic(.idle), at: t0.advanced(by: .milliseconds(102_500)))
        #expect(s.session == .idle, "la proposition repartie à t+100 s, soutenue 2,5 s, s'applique")
    }

    @Test("l'exit du process conclut : code 0 → completed, code ≠ 0 → failed (STA-05)")
    func exitDuProcessConclut() {
        var ok = StateEngine.State(session: .working)
        ok = StateEngine.reduce(ok, .process(.exited(code: 0)), at: t0)
        #expect(ok.session == .completed)

        var ko = StateEngine.State(session: .working)
        ko = StateEngine.reduce(ko, .process(.exited(code: 2)), at: t0)
        #expect(ko.session == .failed)
    }

    @Test("un état terminal absorbe les signaux tardifs")
    func etatTerminalAbsorbant() {
        var s = StateEngine.State(session: .completed)
        s = StateEngine.reduce(s, .hook(.userPromptSubmit), at: t0)
        #expect(s.session == .completed, "un hook en retard ne ressuscite pas une session terminée")
    }

    @Test("Stop classe la fin de tour : question → needs_input, sinon → idle")
    func stopClasseLaFinDeTour() {
        var q = StateEngine.State(session: .working)
        q = StateEngine.reduce(q, .hook(.stop(awaitsReply: true)), at: t0)
        #expect(q.session == .needsInput, "« … lequel préférez-vous ? » doit badger la carte")

        var done = StateEngine.State(session: .working)
        done = StateEngine.reduce(done, .hook(.stop(awaitsReply: false)), at: t0)
        #expect(done.session == .idle)
    }

    @Test("une demande de permission badge immédiatement, sans délai (STA-04)")
    func permissionBadgeImmediatement() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .hook(.permissionRequested), at: t0)
        #expect(s.session == .needsInput)
    }

    @Test("l'arrêt de l'app interrompt, et seule une session interrompue se reprend (UC-7)")
    func interruptionPuisReprise() {
        var s = StateEngine.State(session: .working)
        s = StateEngine.reduce(s, .process(.interrupted), at: t0)
        #expect(s.session == .interrupted, "kill de l'app : le PTY est mort, la session est candidate à la Reprise")

        s = StateEngine.reduce(s, .user(.resume), at: t0.advanced(by: .seconds(30)))
        #expect(s.session == .starting, "Reprise = relance via --resume, la session redémarre")

        var idle = StateEngine.State(session: .idle)
        idle = StateEngine.reduce(idle, .user(.resume), at: t0)
        #expect(idle.session == .idle, "une session vivante ne se « reprend » pas")
    }
}
