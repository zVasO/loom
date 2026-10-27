import Foundation

/// A JSON object read out of what an agent wrote: as written, inside a
/// wrapping ``` fence, or with prose around it. Shared by every report Loom
/// imports from claude (scheduled reviews, workflow steps).
public enum LenientJSON {

    /// The object's bytes, tried as written first: a value may carry its own
    /// ```suggestion fences, which must not be mistaken for a wrapping one.
    /// Then without a wrapping fence, then cut to the outermost braces.
    public static func objectData(in text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if trimmed.hasPrefix("```"), let open = trimmed.firstIndex(of: "\n") {
            var inner = String(trimmed[trimmed.index(after: open)...])
            if let close = inner.range(of: "```", options: .backwards) {
                inner = String(inner[..<close.lowerBound])
            }
            candidates.append(inner)
        }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            candidates.append(String(trimmed[first...last]))
        }
        for candidate in candidates {
            let data = Data(candidate.utf8)
            if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
        }
        return nil
    }

    public static func object(in text: String) -> [String: Any]? {
        objectData(in: text).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
