import Testing
import LoomCore
import LoomSessions
import LoomTerminal
import Foundation

// The interpreter of the STA-02 fallback channel: pure, one sample → one proposal
// (or nothing). Expectations come from the STA-02 table in the spec.

@Suite("HeuristicInterpreter — sample → proposal")
struct HeuristicInterpreterTests {

    let interpreter = HeuristicInterpreter(silenceThreshold: .seconds(2))

    private func sample(bytes: Int, silence: Duration, tail: [String],
                        cpu: Double = 0) -> SessionRuntime.ActivitySample {
        SessionRuntime.ActivitySample(at: ContinuousClock().now, bytesSinceLastSample: bytes,
                                      silence: silence, visibleTail: tail, cpuFraction: cpu)
    }

    @Test("bytes flowing = the agent is working")
    func fluxActif() {
        let proposal = interpreter.propose(sample(bytes: 512, silence: .zero, tail: ["…generating…"]))
        #expect(proposal == .heuristic(.working))
    }

    @Test("prolonged silence on a prompt pattern = the agent awaits input")
    func silenceSurInvite() {
        for invite in ["❯", "$", "user@mac ~ %", "continue? (y/n)", "> "] {
            let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                      tail: ["previous output", invite]))
            #expect(proposal == .heuristic(.needsInput), "\"\(invite)\" is a prompt pattern")
        }
    }

    @Test("prolonged silence without a prompt = simply idle")
    func silenceSansInvite() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                  tail: ["Build finished."]))
        #expect(proposal == .heuristic(.idle))
    }

    @Test("a brief silence proposes nothing: no noise toward the state machine")
    func silenceBref() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .milliseconds(400),
                                                  tail: ["…"]))
        #expect(proposal == nil, "below the threshold, no signal — hysteresis has no noise to filter")
    }

    @Test("silent on screen but CPU busy = the agent is thinking, it is working")
    func silencieuxMaisCpuActif() {
        let proposal = interpreter.propose(sample(bytes: 0, silence: .seconds(3),
                                                  tail: ["$"], cpu: 0.8))
        #expect(proposal == .heuristic(.working), "the process group's CPU wins over the prompt pattern")
    }
}
