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
        guard let url = BrowserController.normalize(input) else {
            throw AgentError.invalid("not an address: \(input)")
        }
        guard decide(url: url, isMainFrame: true) == .allow else {
            throw AgentError.invalid("the agent's browser opens http(s) addresses only, not \(url.scheme ?? "this"):")
        }
        return url
    }
}
