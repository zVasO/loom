import Foundation

/// Where the agent's browser may go (pure, tested). A page cannot steer it to
/// a local file or a custom scheme — `window.open('file:///…')` included: a
/// load the app itself starts would grant the page's process read access.
public enum AgentNavigationPolicy {

    public enum Decision: Equatable, Sendable {
        case allow
        case cancel
    }

    public static func decide(url: URL?, isMainFrame: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return isMainFrame ? .cancel : .allow }
        switch scheme {
        case "http", "https":
            return .allow
        case "about":
            let address = url.absoluteString.lowercased()
            if address == "about:blank" { return .allow }
            return !isMainFrame && address.hasPrefix("about:srcdoc") ? .allow : .cancel
        case "data", "blob":
            // A frame's inline content, never a page of its own.
            return isMainFrame ? .cancel : .allow
        default:
            return .cancel
        }
    }

    /// What `browser_navigate` and `browser_tabs new` accept: the address bar's
    /// rules (loopback hosts in http), then the policy — no file:, data:,
    /// javascript: or custom scheme.
    public static func navigationURL(_ input: String) throws -> URL {
        // "javascript:…", "data:…": a scheme the agent named is refused as
        // such — the address bar would search for it, which is never what an
        // agent asked. "host:port" is not a scheme.
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains("://"),
           let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme != "http", scheme != "https", trimmed.lowercased() != "about:blank" {
            let rest = trimmed[trimmed.index(after: colon)...]
            let port = rest.prefix(while: \.isNumber)
            let isPort = !port.isEmpty && (rest.dropFirst(port.count).first.map { "/?#".contains($0) } ?? true)
            if !isPort {
                throw AgentError.invalid("the agent's browser opens http(s) addresses only, not \(scheme):")
            }
        }
        guard let url = BrowserController.normalize(input) else {
            throw AgentError.invalid("not an address: \(input)")
        }
        guard decide(url: url, isMainFrame: true) == .allow else {
            throw AgentError.invalid("the agent's browser opens http(s) addresses only, not \(url.scheme ?? "this"):")
        }
        return url
    }
}
