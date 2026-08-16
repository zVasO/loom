import Foundation

/// Classifies the `last_assistant_message` of the `Stop` hook: is the agent awaiting a reply?
/// (direct question, choice to make, invitation to decide — not just a trailing "?".)
/// The state reducer receives the fact (`stop(awaitsReply:)`), never the text.
public enum TurnEndClassifier {
    public static func awaitsUserReply(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }

        guard let lastLine = trimmed.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
        else { return false }
        let lowered = lastLine.lowercased()
        return invitationMarkers.contains { lowered.contains($0) }
    }

    /// Phrasings by which the agent hands back control while awaiting a decision.
    /// Deliberately short list, to be grown from the corpus of real sessions
    /// (fixtures, spec §10), never from imagination.
    private static let invitationMarkers: [String] = [
        "dis-moi", "dites-moi", "fais-moi savoir", "indique-moi",
        "let me know", "tell me which", "tell me if", "your call",
    ]
}
