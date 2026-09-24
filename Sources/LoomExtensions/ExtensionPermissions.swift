import Foundation

/// What an extension may reach beyond its own page, as its manifest asks and
/// as the user grants (ADR-0011). Its own storage and its own Keychain secrets
/// are implicit: they reach nothing but the extension itself.
///
/// Decoding is strict: a key this Loom does not know refuses the manifest. An
/// extension written for a newer Loom must be turned away, never silently run
/// with less than it thinks it has.
public struct ExtensionPermissions: Codable, Equatable, Sendable {
    /// Host patterns `http.fetch` may reach, HTTPS only: `api.example.com` or
    /// `*.atlassian.net` (subdomains only, never the bare domain).
    public var network: [String]
    public var sessions: [SessionAccess]
    public var projects: [ProjectAccess]
    /// Runs from Loom's launch, without its view being opened (ADR-0012).
    public var background: Bool
    /// Reaches past its own view: Loom's top bar, or the whole window (ADR-0012).
    public var ui: [UIAccess]

    public enum SessionAccess: String, Codable, CaseIterable, Sendable {
        /// Titles, states, badges, branches of the sessions — the agents API's projection.
        case read
        /// Ask for a session to start; the user confirms each one in Loom.
        case launch
    }

    public enum ProjectAccess: String, Codable, CaseIterable, Sendable {
        /// Project ids and names — never their paths.
        case read
    }

    public enum UIAccess: String, Codable, CaseIterable, Sendable {
        /// A short text in Loom's top bar — a countdown Loom ticks itself.
        case status
        /// One of its pages over the whole window; Loom's own button always dismisses it.
        case overlay
    }

    public static let empty = ExtensionPermissions()

    public init(network: [String] = [], sessions: [SessionAccess] = [], projects: [ProjectAccess] = [],
                background: Bool = false, ui: [UIAccess] = []) {
        self.network = network
        self.sessions = sessions
        self.projects = projects
        self.background = background
        self.ui = ui
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case network, sessions, projects, background, ui
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys.map(\.stringValue).sorted().first(where: { !known.contains($0) }) {
            throw ManifestError.invalid(field: "permissions", reason:
                "\"\(unknown)\" is not a permission this Loom knows (network, sessions, projects, background, ui)")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
        do {
            sessions = try container.decodeIfPresent([SessionAccess].self, forKey: .sessions) ?? []
            projects = try container.decodeIfPresent([ProjectAccess].self, forKey: .projects) ?? []
            background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
            ui = try container.decodeIfPresent([UIAccess].self, forKey: .ui) ?? []
        } catch {
            throw ManifestError.invalid(field: "permissions", reason:
                "sessions takes \"read\" and \"launch\", projects takes \"read\", background is true or false, ui takes \"status\" and \"overlay\"")
        }
    }

    public var isEmpty: Bool {
        network.isEmpty && sessions.isEmpty && projects.isEmpty && !background && ui.isEmpty
    }

    public func validate() throws {
        for pattern in network {
            do {
                _ = try HostPattern(pattern)
            } catch let error as HostPattern.PatternError {
                throw ManifestError.invalid(field: "permissions.network", reason: error.description)
            }
        }
    }

    /// The patterns `http.fetch` checks against; an invalid one never matches.
    public var hostPatterns: [HostPattern] {
        network.compactMap { try? HostPattern($0) }
    }

    /// What this asks for that `granted` does not cover — what a consent
    /// must be asked for. Removing a permission never needs one.
    public func missing(from granted: ExtensionPermissions?) -> ExtensionPermissions {
        let granted = granted ?? .empty
        let grantedHosts = Set(granted.network.map { $0.lowercased() })
        return ExtensionPermissions(
            network: network.filter { !grantedHosts.contains($0.lowercased()) },
            sessions: sessions.filter { !granted.sessions.contains($0) },
            projects: projects.filter { !granted.projects.contains($0) },
            background: background && !granted.background,
            ui: ui.filter { !granted.ui.contains($0) })
    }

    /// What both allow — what an extension actually runs with: the manifest
    /// never gets more than was granted, and a grant never more than is asked.
    public func intersection(_ other: ExtensionPermissions?) -> ExtensionPermissions {
        let other = other ?? .empty
        let otherHosts = Set(other.network.map { $0.lowercased() })
        return ExtensionPermissions(
            network: network.filter { otherHosts.contains($0.lowercased()) },
            sessions: sessions.filter { other.sessions.contains($0) },
            projects: projects.filter { other.projects.contains($0) },
            background: background && other.background,
            ui: ui.filter { other.ui.contains($0) })
    }

    /// Both grants together, each entry once.
    public func union(_ other: ExtensionPermissions) -> ExtensionPermissions {
        let hosts = Set(network.map { $0.lowercased() })
        return ExtensionPermissions(
            network: network + other.network.filter { !hosts.contains($0.lowercased()) },
            sessions: sessions + other.sessions.filter { !sessions.contains($0) },
            projects: projects + other.projects.filter { !projects.contains($0) },
            background: background || other.background,
            ui: ui + other.ui.filter { !ui.contains($0) })
    }

    public func allows(_ requirement: BridgeMethod.Requirement) -> Bool {
        switch requirement {
        case .sessions(let access): return sessions.contains(access)
        case .projects(let access): return projects.contains(access)
        case .network: return !network.isEmpty
        case .ui(let access): return ui.contains(access)
        }
    }

    /// The permissions in plain words, for the consent sheet and Settings.
    public var summary: [String] {
        var lines: [String] = []
        for host in network {
            lines.append("Connect to https://\(host)")
        }
        if projects.contains(.read) {
            lines.append("See your projects' names")
        }
        if sessions.contains(.read) {
            lines.append("See your sessions: titles, states, badges, branches")
        }
        if sessions.contains(.launch) {
            lines.append("Ask to start sessions — you confirm each one")
        }
        if background {
            lines.append("Run in the background while Loom is open")
        }
        if ui.contains(.status) {
            lines.append("Show a short status in Loom's top bar")
        }
        if ui.contains(.overlay) {
            lines.append("Cover Loom with one of its pages — you can always dismiss it")
        }
        return lines
    }
}
