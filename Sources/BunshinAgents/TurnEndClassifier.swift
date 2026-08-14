import Foundation

/// Classifie le `last_assistant_message` du hook `Stop` : l'agent attend-il une réponse ?
/// Le réducteur d'état reçoit le fait (`stop(endsWithQuestion:)`), jamais le texte.
public enum TurnEndClassifier {
    public static func endsWithQuestion(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }

        guard let lastLine = trimmed.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
        else { return false }
        let lowered = lastLine.lowercased()
        return invitationMarkers.contains { lowered.contains($0) }
    }

    /// Formules par lesquelles l'agent rend la main en attendant une décision.
    /// Liste volontairement courte, à enrichir depuis le corpus de vraies sessions
    /// (fixtures §10 du cahier des charges), jamais depuis l'imagination.
    private static let invitationMarkers: [String] = [
        "dis-moi", "dites-moi", "fais-moi savoir", "indique-moi",
        "let me know", "tell me which", "tell me if", "your call",
    ]
}
