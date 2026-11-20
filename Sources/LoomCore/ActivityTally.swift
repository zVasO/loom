import Foundation

/// What a session — or many — reached for: MCP servers, skills, sub-agents,
/// slash commands, hooks and plain tools, counted from claude's own records.
/// A value: built by `ClaudeActivity`, merged across files, read by the
/// activity sheet.
public struct ActivityTally: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case mcp, skill, agent, command, hook, tool
    }

    public struct Count: Equatable, Sendable {
        public var runs = 0
        public var failures = 0

        public init(runs: Int = 0, failures: Int = 0) {
            self.runs = runs
            self.failures = failures
        }
    }

    /// One row of a ranking: a name, how often, how often it failed — and,
    /// for an MCP server, its tools.
    public struct Line: Equatable, Sendable, Identifiable {
        public let name: String
        public let runs: Int
        public let failures: Int
        public let children: [Line]
        public var id: String { name }

        public init(name: String, runs: Int, failures: Int, children: [Line] = []) {
            self.name = name
            self.runs = runs
            self.failures = failures
            self.children = children
        }
    }

    /// Kind → name → count. An MCP tool is named `server__tool`, as claude
    /// names it after `mcp__`.
    public private(set) var counts: [Kind: [String: Count]] = [:]
    /// What the sessions were offered, used or not.
    public var availableSkills: Set<String> = []
    public var availableServers: Set<String> = []

    public init() {}

    public var isEmpty: Bool { counts.values.allSatisfy(\.isEmpty) }

    public mutating func note(_ kind: Kind, _ name: String, failed: Bool = false) {
        guard !name.isEmpty else { return }
        counts[kind, default: [:]][name, default: Count()].runs += 1
        if failed { counts[kind]?[name]?.failures += 1 }
    }

    /// A run already counted turned out to have failed.
    public mutating func fail(_ kind: Kind, _ name: String) {
        guard counts[kind]?[name] != nil else { return }
        counts[kind]?[name]?.failures += 1
    }

    public mutating func merge(_ other: ActivityTally) {
        for (kind, names) in other.counts {
            for (name, count) in names {
                counts[kind, default: [:]][name, default: Count()].runs += count.runs
                counts[kind]?[name]?.failures += count.failures
            }
        }
        availableSkills.formUnion(other.availableSkills)
        availableServers.formUnion(other.availableServers)
    }

    public func total(_ kind: Kind) -> Int {
        (counts[kind] ?? [:]).values.reduce(0) { $0 + $1.runs }
    }

    /// The ranking of a kind: most used first, names breaking ties. MCP
    /// tools are ranked flat here; `servers` groups them.
    public func lines(_ kind: Kind) -> [Line] {
        Self.ranked((counts[kind] ?? [:]).map { Line(name: $0.key, runs: $0.value.runs, failures: $0.value.failures) })
    }

    /// MCP servers, most used first, each with its tools.
    public var servers: [Line] {
        var grouped: [String: [Line]] = [:]
        for (name, count) in counts[.mcp] ?? [:] {
            let (server, tool) = Self.split(mcp: name)
            grouped[server, default: []].append(Line(name: tool, runs: count.runs, failures: count.failures))
        }
        return Self.ranked(grouped.map { server, tools in
            Line(name: server, runs: tools.reduce(0) { $0 + $1.runs },
                 failures: tools.reduce(0) { $0 + $1.failures }, children: Self.ranked(tools))
        })
    }

    /// Offered and never called: what costs context for nothing.
    public var unusedServers: [String] {
        let used = Set((counts[.mcp] ?? [:]).keys.map { Self.split(mcp: $0).server })
        return availableServers.subtracting(used).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var unusedSkills: [String] {
        let used = Set((counts[.skill] ?? [:]).keys)
        return availableSkills.subtracting(used).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// `github__actions_list` → ("github", "actions_list"). A name without a
    /// tool is a server alone.
    public static func split(mcp name: String) -> (server: String, tool: String) {
        guard let range = name.range(of: "__") else { return (name, "") }
        return (String(name[..<range.lowerBound]), String(name[range.upperBound...]))
    }

    private static func ranked(_ lines: [Line]) -> [Line] {
        lines.sorted {
            $0.runs != $1.runs ? $0.runs > $1.runs
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
