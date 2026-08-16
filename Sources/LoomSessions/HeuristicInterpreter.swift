import LoomCore
import LoomTerminal
import Foundation

/// Canal de repli STA-02 (agents sans hooks — Codex, Gemini) : traduit un
/// échantillon d'activité en proposition d'état. Pur et sans mémoire — le lissage
/// (hystérésis, fenêtre de priorité hook) appartient au StateEngine, pas à lui.
/// Les motifs d'invite sont volontairement dans un tableau éditable : le cahier des
/// charges prévoit leur mise à jour sans release (risque n°1, fichier de définitions).
public struct HeuristicInterpreter: Sendable {

    public var silenceThreshold: Duration
    /// L'agent peut être muet à l'écran mais en pleine réflexion : au-delà de ce
    /// seuil CPU (groupe de process), le silence ne vaut pas inactivité.
    public var busyCPUFraction: Double
    public var promptPatterns: [String]

    public init(silenceThreshold: Duration = .seconds(2),
                busyCPUFraction: Double = 0.15,
                promptPatterns: [String] = HeuristicInterpreter.defaultPromptPatterns) {
        self.silenceThreshold = silenceThreshold
        self.busyCPUFraction = busyCPUFraction
        self.promptPatterns = promptPatterns
    }

    /// Fins de ligne typiques d'un shell ou d'un agent qui attend une saisie.
    public static let defaultPromptPatterns = [
        #"[$%>❯]\s*$"#,          // invites shell : $, %, >, ❯
        #"\(y/n\)\s*$"#,         // confirmations
        #"\?\s*$"#,              // question affichée à l'écran
    ]

    public func propose(_ sample: SessionRuntime.ActivitySample) -> StateEngine.Event? {
        if sample.bytesSinceLastSample > 0 { return .heuristic(.working) }
        guard sample.silence >= silenceThreshold else { return nil }
        if sample.cpuFraction >= busyCPUFraction { return .heuristic(.working) }
        if let lastLine = sample.visibleTail.last, matchesPrompt(lastLine) {
            return .heuristic(.needsInput)
        }
        return .heuristic(.idle)
    }

    private func matchesPrompt(_ line: String) -> Bool {
        promptPatterns.contains { pattern in
            line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
