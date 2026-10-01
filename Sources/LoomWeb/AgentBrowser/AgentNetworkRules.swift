import Foundation
import LoomExtensions

/// "Local sites only" for the agent's browser (ADR-0014): a WebKit content
/// rule list that blocks every http(s) and ws(s) load except the machine's
/// own addresses and the hosts the person allowed — enforced by WebKit for
/// every request of every page, not by a tool the agent could route around
/// (pure: the JSON is built and pinned by tests; WebKit compiles it).
public enum AgentNetworkRules {

    public static let identifier = "app.loom.agent-browser.local-only"

    /// WebKit's url-filter knows no alternation: one rule per allowed origin
    /// shape. URLs reach the filter normalised, a `/` after the authority.
    public static func json(allowedHosts: [HostPattern]) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://"], "action": ["type": "block"]],
        ]
        func allow(_ hostPattern: String) {
            for scheme in ["https?", "wss?"] {
                rules.append(["trigger": ["url-filter": "^\(scheme)://\(hostPattern)[:/]"],
                              "action": ["type": "ignore-previous-rules"]])
            }
        }
        for loopback in [#"localhost"#, #"[^/:]*\.localhost"#, #"127\.[0-9]*\.[0-9]*\.[0-9]*"#,
                         #"\[::1\]"#, #"0\.0\.0\.0"#] {
            allow(loopback)
        }
        for host in allowedHosts {
            let domain = NSRegularExpression.escapedPattern(for: host.domain)
            allow(host.includesSubdomains ? #"[^/:]*\."# + domain : domain)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The hosts the person typed, one per line or comma-separated; the
    /// invalid ones named so the field can say why.
    public static func parse(_ text: String) -> (hosts: [HostPattern], invalid: [String]) {
        var hosts: [HostPattern] = []
        var invalid: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }) {
            let entry = String(raw).trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if let pattern = try? HostPattern(entry) { hosts.append(pattern) } else { invalid.append(entry) }
        }
        return (hosts, invalid)
    }
}
