import Foundation

/// An agent with one domain (PHP, Symfony, security…), reused from workflow
/// to workflow: its instructions go on top of claude's system prompt, its
/// skills and connectors come along, and it may only use the tools it lists
/// — a headless run has nobody to answer a permission prompt.
public struct Expert: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var domain: String
    public var systemPrompt: String
    /// An alias (`opus`, `sonnet`, `haiku`) or a model id; nil is the
    /// workflows' default.
    public var model: String?
    public var skills: [String]
    public var connectorIDs: [UUID]
    public var allowedTools: [String]
    public var color: String

    /// Reading, searching, and the read-only git and gh commands a review uses.
    public static let readOnlyTools = [
        "Read", "Grep", "Glob", "LS",
        "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git status:*)",
        "Bash(git ls-files:*)", "Bash(git blame:*)",
        "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)", "Bash(gh api:*)",
        "Bash(gh issue view:*)",
    ]

    public init(id: UUID = UUID(), name: String, domain: String = "", systemPrompt: String = "",
                model: String? = nil, skills: [String] = [], connectorIDs: [UUID] = [],
                allowedTools: [String] = Expert.readOnlyTools, color: String = "#0D6E74") {
        self.id = id
        self.name = name
        self.domain = domain
        self.systemPrompt = systemPrompt
        self.model = model
        self.skills = skills
        self.connectorIDs = connectorIDs
        self.allowedTools = allowedTools
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Expert",
                  domain: try c.decodeIfPresent(String.self, forKey: .domain) ?? "",
                  systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
                  model: try c.decodeIfPresent(String.self, forKey: .model),
                  skills: try c.decodeIfPresent([String].self, forKey: .skills) ?? [],
                  connectorIDs: try c.decodeIfPresent([UUID].self, forKey: .connectorIDs) ?? [],
                  allowedTools: try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? Expert.readOnlyTools,
                  color: try c.decodeIfPresent(String.self, forKey: .color) ?? "#0D6E74")
    }
}

/// A source of data or tools a step can use: an MCP server Loom starts for
/// the run, one it reaches over HTTP, or one already configured in the
/// user's Claude Code (a remote server signed in through `/mcp`). Secret
/// values never sit in the JSON: `{{secret:KEY}}` names a Keychain entry.
public struct Connector: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ConnectorKind
    /// The secrets the connector reads, by key — their values are in the Keychain.
    public var secretKeys: [String]
    public var notes: String

    public init(id: UUID = UUID(), name: String, kind: ConnectorKind, secretKeys: [String] = [],
                notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.secretKeys = secretKeys
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Connector",
                  kind: try c.decode(ConnectorKind.self, forKey: .kind),
                  secretKeys: try c.decodeIfPresent([String].self, forKey: .secretKeys) ?? [],
                  notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "")
    }

    /// The key under `mcpServers`, and the `mcp__<key>__…` tool prefix:
    /// lowercase letters, digits and dashes.
    public var serverKey: String {
        if case .claudeConfigured(let server) = kind { return server }
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let key = String(mapped).split(separator: "-").joined(separator: "-")
        return key.isEmpty ? "connector" : key
    }

    /// Every tool the connector's server offers, for `--allowedTools`.
    public var toolPattern: String { "mcp__\(serverKey)__*" }

    // MARK: Presets

    public static let atlassianStdioID = UUID(uuidString: "6E0A3C2E-7B4D-4E52-9C51-1A0F3A7D2B01")!
    public static let atlassianRemoteID = UUID(uuidString: "6E0A3C2E-7B4D-4E52-9C51-1A0F3A7D2B02")!

    /// The community `mcp-atlassian` server, started by Loom for each run:
    /// a Jira site, an e-mail, an API token (id.atlassian.com) in the Keychain.
    /// Through a login shell: a GUI app does not see the PATH `uvx` lives on.
    public static func atlassianStdio() -> Connector {
        Connector(id: atlassianStdioID, name: "Atlassian",
                  kind: .mcpStdio(command: "/bin/zsh",
                                  args: ["-lc", "uvx mcp-atlassian"],
                                  env: ["JIRA_URL": "{{secret:JIRA_URL}}",
                                        "JIRA_USERNAME": "{{secret:JIRA_USERNAME}}",
                                        "JIRA_API_TOKEN": "{{secret:JIRA_API_TOKEN}}"]),
                  secretKeys: ["JIRA_URL", "JIRA_USERNAME", "JIRA_API_TOKEN"],
                  notes: "mcp-atlassian (needs uv). JIRA_URL is your site, e.g. https://acme.atlassian.net.")
    }

    /// Atlassian's remote MCP server as the user's Claude Code knows it
    /// (`claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse`,
    /// then `/mcp` to sign in).
    public static func atlassianRemote() -> Connector {
        Connector(id: atlassianRemoteID, name: "Atlassian (Claude Code)",
                  kind: .claudeConfigured(server: "atlassian"),
                  notes: "The server named \"atlassian\" in your Claude Code, signed in with /mcp.")
    }
}

public enum ConnectorKind: Codable, Equatable, Sendable {
    case mcpStdio(command: String, args: [String], env: [String: String])
    case mcpHTTP(url: String, headers: [String: String])
    case claudeConfigured(server: String)

    enum CodingKeys: String, CodingKey { case type, command, args, env, url, headers, server }

    public var typeName: String {
        switch self {
        case .mcpStdio: "mcpStdio"
        case .mcpHTTP: "mcpHTTP"
        case .claudeConfigured: "claudeConfigured"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "mcpHTTP":
            self = .mcpHTTP(url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                            headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:])
        case "claudeConfigured":
            self = .claudeConfigured(server: try c.decodeIfPresent(String.self, forKey: .server) ?? "")
        default:
            self = .mcpStdio(command: try c.decodeIfPresent(String.self, forKey: .command) ?? "",
                             args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                             env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .mcpStdio(let command, let args, let env):
            try c.encode(command, forKey: .command)
            try c.encode(args, forKey: .args)
            try c.encode(env, forKey: .env)
        case .mcpHTTP(let url, let headers):
            try c.encode(url, forKey: .url)
            try c.encode(headers, forKey: .headers)
        case .claudeConfigured(let server):
            try c.encode(server, forKey: .server)
        }
    }
}

/// What a step's connectors become on claude's command line.
public struct ConnectorWiring: Equatable, Sendable {
    /// The inline `--mcp-config`, nil when no server is Loom's to start.
    public var mcpConfig: String?
    /// `--strict-mcp-config`: only the step's servers — impossible when one
    /// of them is the user's own Claude Code configuration.
    public var strict: Bool
    /// `mcp__<server>__*` for each connector.
    public var toolPatterns: [String]
    /// `{{secret:KEY}}` references with no value in the Keychain.
    public var missingSecrets: [String]

    /// `secret(connectorID, key)` reads the Keychain; nil is a missing secret.
    public static func wire(_ connectors: [Connector],
                            secret: (UUID, String) -> String?) -> ConnectorWiring {
        var servers: [String: Any] = [:]
        var missing: [String] = []
        var userConfigured = false
        for connector in connectors {
            func resolve(_ text: String) -> String {
                SecretReference.substitute(text) { key in
                    if let value = secret(connector.id, key) { return value }
                    missing.append("\(connector.name): \(key)")
                    return ""
                }
            }
            switch connector.kind {
            case .mcpStdio(let command, let args, let env):
                servers[connector.serverKey] = ["command": resolve(command),
                                                "args": args.map(resolve),
                                                "env": env.mapValues(resolve)]
            case .mcpHTTP(let url, let headers):
                servers[connector.serverKey] = ["type": "http", "url": resolve(url),
                                                "headers": headers.mapValues(resolve)]
            case .claudeConfigured:
                userConfigured = true
            }
        }
        var json: String?
        if !servers.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                                  options: [.sortedKeys, .withoutEscapingSlashes]) {
            json = String(decoding: data, as: UTF8.self)
        }
        return ConnectorWiring(mcpConfig: json, strict: !userConfigured && json != nil,
                               toolPatterns: connectors.map(\.toolPattern),
                               missingSecrets: missing)
    }
}

/// `{{secret:KEY}}` in a connector's fields.
public enum SecretReference {
    public static func keys(in text: String) -> [String] {
        var keys: [String] = []
        _ = substitute(text) { key in keys.append(key); return "" }
        return keys
    }

    public static func substitute(_ text: String, value: (String) -> String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{secret:") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let key = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += value(key)
            rest = after[close.upperBound...]
        }
        return result + rest
    }
}
