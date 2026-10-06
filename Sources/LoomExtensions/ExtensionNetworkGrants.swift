import Foundation

// Hosts granted at use (ADR-0015): an extension whose manifest says
// `"optionalNetwork": true` asks for a site its manifest could not name — a
// feed the user just added — and the user approves it in Loom's own sheet.
// Exact hosts only, a handful at a time, kept per extension in state.json.

/// `network.request` and `network.revoke`: hosts, or https URLs whose host is
/// meant (the SDK already reduces URLs to hosts).
public struct BridgeHostsParams: Codable, Equatable, Sendable {
    public var hosts: [String]
    public init(hosts: [String]) { self.hosts = hosts }

    public static let maxPerRequest = 10

    /// Lowercased, each once, each an exact host name `HostPattern` accepts —
    /// a wildcard is a manifest's to declare, never a page's to ask.
    public func validatedHosts() throws -> [String] {
        guard !hosts.isEmpty, hosts.count <= Self.maxPerRequest else {
            throw BridgeError(.invalidParams, "ask for 1 to \(Self.maxPerRequest) hosts at a time")
        }
        var seen: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !host.hasPrefix("*") else {
                throw BridgeError(.invalidParams, "\"\(raw)\": ask for exact hosts, never a wildcard")
            }
            do {
                _ = try HostPattern(host)
            } catch let error as HostPattern.PatternError {
                throw BridgeError(.invalidParams, error.description)
            }
            if !seen.contains(host) { seen.append(host) }
        }
        return seen
    }
}

/// `network.request`'s answer: what the user allowed, and what not.
public struct BridgeHostsGrant: Codable, Equatable, Sendable {
    public var granted: [String]
    public var denied: [String]
    public init(granted: [String], denied: [String]) {
        self.granted = granted
        self.denied = denied
    }
}

/// `network.granted`: the manifest's hosts, and those the user added.
public struct BridgeHostsList: Codable, Equatable, Sendable {
    public var declared: [String]
    public var granted: [String]
    public init(declared: [String], granted: [String]) {
        self.declared = declared
        self.granted = granted
    }
}
