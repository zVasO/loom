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
    /// May ask the user, one site at a time, for hosts its manifest could not
    /// name — the feeds a user adds (ADR-0015). Each one is granted in its own
    /// sheet, never here.
    public var optionalNetwork: Bool
    /// Text answers from Claude, with the user's Claude Code account (ADR-0015).
    public var claude: [ClaudeAccess]

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

    public enum ClaudeAccess: String, Codable, CaseIterable, Sendable {
        /// A prompt in, text out — no tools, no files, no transcript.
        case complete
    }

    public static let empty = ExtensionPermissions()

    public init(network: [String] = [], sessions: [SessionAccess] = [], projects: [ProjectAccess] = [],
                background: Bool = false, ui: [UIAccess] = [],
                optionalNetwork: Bool = false, claude: [ClaudeAccess] = []) {
        self.network = network
        self.sessions = sessions
        self.projects = projects
        self.background = background
        self.ui = ui
        self.optionalNetwork = optionalNetwork
        self.claude = claude
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case network, sessions, projects, background, ui, optionalNetwork, claude
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
                "\"\(unknown)\" is not a permission this Loom knows (network, sessions, projects, background, ui, optionalNetwork, claude)")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
        do {
            sessions = try container.decodeIfPresent([SessionAccess].self, forKey: .sessions) ?? []
            projects = try container.decodeIfPresent([ProjectAccess].self, forKey: .projects) ?? []
            background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
            ui = try container.decodeIfPresent([UIAccess].self, forKey: .ui) ?? []
            optionalNetwork = try container.decodeIfPresent(Bool.self, forKey: .optionalNetwork) ?? false
            claude = try container.decodeIfPresent([ClaudeAccess].self, forKey: .claude) ?? []
        } catch {
            throw ManifestError.invalid(field: "permissions", reason:
                "sessions takes \"read\" and \"launch\", projects takes \"read\", background and optionalNetwork are true or false, ui takes \"status\" and \"overlay\", claude takes \"complete\"")
        }
    }

    /// Only what is set: a grant written by this Loom stays readable by an
    /// older one — which refuses a key it does not know, and would drop every
    /// grant in state.json with it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !network.isEmpty { try container.encode(network, forKey: .network) }
        if !sessions.isEmpty { try container.encode(sessions, forKey: .sessions) }
        if !projects.isEmpty { try container.encode(projects, forKey: .projects) }
        if background { try container.encode(background, forKey: .background) }
        if !ui.isEmpty { try container.encode(ui, forKey: .ui) }
        if optionalNetwork { try container.encode(optionalNetwork, forKey: .optionalNetwork) }
        if !claude.isEmpty { try container.encode(claude, forKey: .claude) }
    }

    public var isEmpty: Bool {
        network.isEmpty && sessions.isEmpty && projects.isEmpty && !background && ui.isEmpty
            && !optionalNetwork && claude.isEmpty
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
            ui: ui.filter { !granted.ui.contains($0) },
            optionalNetwork: optionalNetwork && !granted.optionalNetwork,
            claude: claude.filter { !granted.claude.contains($0) })
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
            ui: ui.filter { other.ui.contains($0) },
            optionalNetwork: optionalNetwork && other.optionalNetwork,
            claude: claude.filter { other.claude.contains($0) })
    }

    /// Both grants together, each entry once.
    public func union(_ other: ExtensionPermissions) -> ExtensionPermissions {
        let hosts = Set(network.map { $0.lowercased() })
        return ExtensionPermissions(
            network: network + other.network.filter { !hosts.contains($0.lowercased()) },
            sessions: sessions + other.sessions.filter { !sessions.contains($0) },
            projects: projects + other.projects.filter { !projects.contains($0) },
            background: background || other.background,
            ui: ui + other.ui.filter { !ui.contains($0) },
            optionalNetwork: optionalNetwork || other.optionalNetwork,
            claude: claude + other.claude.filter { !claude.contains($0) })
    }

    public func allows(_ requirement: BridgeMethod.Requirement) -> Bool {
        switch requirement {
        case .sessions(let access): return sessions.contains(access)
        case .projects(let access): return projects.contains(access)
        // Hosts granted later are still hosts: `http.fetch` checks each URL.
        case .network: return !network.isEmpty || optionalNetwork
        case .ui(let access): return ui.contains(access)
        case .optionalNetwork: return optionalNetwork
        case .claude(let access): return claude.contains(access)
        }
    }

    /// The permissions in plain words, for the consent sheet and Settings.
    public var summary: [String] {
        var lines: [String] = []
        for host in network {
            lines.append("Connect to https://\(host)")
        }
        if optionalNetwork {
            lines.append("Ask you for other sites, one at a time — you approve each (HTTPS only)")
        }
        if claude.contains(.complete) {
            lines.append("Ask Claude for text answers with your Claude Code account, in the background too — no tools, no files; it counts toward your plan's usage")
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
