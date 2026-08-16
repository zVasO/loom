import Testing
import LoomCore
import LoomSessions
import LoomTerminal
import Foundation

// L'interprète du canal de repli STA-02 : pur, un échantillon → une proposition
// (ou rien). Les attendus viennent de la table STA-02 du cahier des charges.

@Suite("HeuristicInterpreter — échantillon → proposition")
struct HeuristicInterpreterTests {

    let interpreter = HeuristicInterpreter(silenceThreshold: .seconds(2))

    private func sample(bytes: Int, silence: Duration, tail: [String],
                        cpu: Double = 0) -> SessionRuntime.ActivitySample {
        SessionRuntime.ActivitySample(at: ContinuousClock().now, bytesSinceLastSample: bytes,
                                      silence: silence, visibleTail: tail, cpuFraction: cpu)
    }

    @Test("des octets qui coulent = l'agent travaille")
    func fluxActif() {
        let proposal = interpreter.propose(sample(bytes: 512, silence: .zero, tail: ["…génération…"]))
        #expect(proposal == .heuristic(.working))
    }

    @Test("silence prolongé sur un motif d'invite = l'agent attend une entrée")
    func silenceSurInvite() {
        for invite in ["❯", "$", "utilisateur@mac ~ %", "continue? (y/n)", "> "] {
            let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                      tail: ["sortie précédente", invite]))
            #expect(proposal == .heuristic(.needsInput), "« \(invite) » est un motif d'invite")
        }
    }

    @Test("silence prolongé sans invite = simplement inactif")
    func silenceSansInvite() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                  tail: ["Compilation terminée."]))
        #expect(proposal == .heuristic(.idle))
    }

    @Test("un bref silence ne propose rien : pas de bruit vers la machine à états")
    func silenceBref() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .milliseconds(400),
                                                  tail: ["…"]))
        #expect(proposal == nil, "en dessous du seuil, aucun signal — l'hystérésis n'a pas à filtrer du bruit")
    }

    @Test("silencieux à l'écran mais CPU actif = l'agent réfléchit, il travaille")
    func silencieuxMaisCpuActif() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                  tail: ["$"], cpu: 0.8))
        #expect(proposal == .heuristic(.working), "le CPU du groupe prime sur le motif d'invite")
    }
}
