import Foundation

/// A host an extension may reach through `http.fetch`: an exact name
/// (`api.example.com`) or every subdomain of one (`*.atlassian.net`, which
/// does not include `atlassian.net` itself). Nothing looser is expressible —
/// no bare `*`, no `*.com`, no IP address, no port, no path.
public struct HostPattern: Equatable, Sendable, CustomStringConvertible {
    /// Lowercased, without the `*.`.
    public let domain: String
    public let includesSubdomains: Bool

    public enum PatternError: Error, Equatable, CustomStringConvertible {
        case invalid(String, reason: String)

        public var description: String {
            switch self {
            case .invalid(let pattern, let reason): return "\"\(pattern)\" \(reason)"
            }
        }
    }

    public init(_ pattern: String) throws {
        let lowered = pattern.lowercased()
        let wildcard = lowered.hasPrefix("*.")
        let domain = wildcard ? String(lowered.dropFirst(2)) : lowered
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw PatternError.invalid(pattern, reason: wildcard
                ? "is too broad: a wildcard needs a registered domain after it, like *.example.com"
                : "must be a full host name, like api.example.com")
        }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }),
                  label.first != "-", label.last != "-"
            else {
                throw PatternError.invalid(pattern, reason:
                    "must be letters, digits and hyphens between dots (IDN hosts in punycode), with no port or path")
            }
        }
        if let last = labels.last, last.allSatisfy(\.isNumber) {
            throw PatternError.invalid(pattern, reason: "must be a host name, not an IP address")
        }
        self.domain = domain
        self.includesSubdomains = wildcard
    }

    public var description: String { includesSubdomains ? "*.\(domain)" : domain }

    public func matches(host: String) -> Bool {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return includesSubdomains ? host.hasSuffix("." + domain) : host == domain
    }

    /// Whether `url` is one `http.fetch` may reach: HTTPS on the default port,
    /// no credentials in the URL, a host some pattern allows.
    public static func allows(_ url: URL, _ patterns: [HostPattern]) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil
        else { return false }
        return patterns.contains { $0.matches(host: host) }
    }
}
