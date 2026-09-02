import LoomCore
import Foundation

/// Parses claude's native JSONL into billed turns. Pure — the seam the tests
/// contract against.
///
/// claude writes one `assistant` line PER CONTENT BLOCK of a response, each
/// carrying the same `usage`: without deduplication on (message.id, requestId)
/// costs inflate up to 3×. First occurrence wins.
public enum UsageLedger {

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func turns(fromJSONL text: String) -> [UsageTurn] {
        var seen = Set<String>()
        var turns: [UsageTurn] = []
        for line in text.split(separator: "\n") {
            guard let turn = parse(line: line) else { continue }
            let key = turn.messageID + "|" + turn.requestID
            guard seen.insert(key).inserted else { continue }
            turns.append(turn)
        }
        return turns
    }

    private static func parse(line: Substring) -> UsageTurn? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let stamp = object["timestamp"] as? String,
              let timestamp = fractional.date(from: stamp) ?? plain.date(from: stamp)
        else { return nil }

        let messageID = message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let split = usage["cache_creation"] as? [String: Any]
        let write5m = split?["ephemeral_5m_input_tokens"] as? Int
        let write1h = split?["ephemeral_1h_input_tokens"] as? Int

        return UsageTurn(
            messageID: messageID,
            requestID: object["requestId"] as? String ?? "",
            timestamp: timestamp,
            model: model,
            sessionID: object["sessionId"] as? String ?? "",
            cwd: object["cwd"] as? String,
            input: usage["input_tokens"] as? Int ?? 0,
            cacheWrite5m: split == nil ? creation : (write5m ?? 0),
            cacheWrite1h: split == nil ? 0 : (write1h ?? 0),
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0)
    }
}
