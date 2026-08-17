import Foundation

/// v4 — the PR guided tour. `claude -p --output-format json` wraps its answer
/// in an envelope ({"result": "…"}); the answer itself carries the tour as
/// (possibly fenced) JSON. Both layers are peeled here — pure and tested.
public struct PRTour: Equatable, Sendable {
    public struct Chapter: Equatable, Sendable {
        public let title: String
        public let explanation: String
        public let file: String
    }

    public struct Warning: Equatable, Sendable {
        public let file: String
        public let line: Int?
        public let note: String
    }

    /// The PR in two sentences — the storyteller's opening.
    public let pitch: String
    public let chapters: [Chapter]
    /// "quiet" | "watch" | "dragon" — the playful risk gauge.
    public let riskLevel: String
    public let warnings: [Warning]
}

public enum PRTourParser {

    public static func parse(claudeOutput: String) -> PRTour? {
        guard let envelope = try? JSONSerialization.jsonObject(
                  with: Data(claudeOutput.utf8)) as? [String: Any],
              let result = envelope["result"] as? String else { return nil }
        return parse(tourJSON: result)
    }

    /// Accepts the inner JSON bare or fenced in ```json … ```.
    public static func parse(tourJSON text: String) -> PRTour? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.range(of: "```json") ?? cleaned.range(of: "```") {
            cleaned = String(cleaned[start.upperBound...])
            if let end = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        }
        // Tolerate prose around the object: cut to the outermost braces.
        guard let first = cleaned.firstIndex(of: "{"),
              let last = cleaned.lastIndex(of: "}") else { return nil }
        cleaned = String(cleaned[first...last])
        guard let object = try? JSONSerialization.jsonObject(
                  with: Data(cleaned.utf8)) as? [String: Any],
              let pitch = object["pitch"] as? String else { return nil }
        let chapters = (object["chapters"] as? [[String: Any]] ?? []).compactMap { row in
            (row["title"] as? String).map { title in
                PRTour.Chapter(title: title,
                               explanation: row["explanation"] as? String ?? "",
                               file: row["file"] as? String ?? "")
            }
        }
        let warnings = (object["warnings"] as? [[String: Any]] ?? []).compactMap { row in
            (row["note"] as? String).map { note in
                PRTour.Warning(file: row["file"] as? String ?? "",
                               line: row["line"] as? Int,
                               note: note)
            }
        }
        return PRTour(pitch: pitch, chapters: chapters,
                      riskLevel: object["riskLevel"] as? String ?? "watch",
                      warnings: warnings)
    }
}
