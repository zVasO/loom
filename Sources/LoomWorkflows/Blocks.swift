import Foundation
import LoomAPI

/// Named rules to tick on a block, a step or a link (ADR-0019): "Cite
/// path:line", "Write in French" — written once, used everywhere.
public struct RuleSet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rules: [String]

    public init(id: UUID = UUID(), name: String, rules: [String] = []) {
        self.id = id
        self.name = name
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Rules",
                  rules: try c.decodeIfPresent([String].self, forKey: .rules) ?? [])
    }
}

/// A box of the palette the user made (ADR-0019): an agent step with its
/// prompt, fields, verdict, rules and settings, placed in any workflow as
/// often as wanted. Placed steps follow it: they name it, never copy it.
public struct WorkflowBlock: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    /// `#RRGGBB`, its mark in the palette and on its steps.
    public var color: String
    /// The step it makes; its `blockID`, `rules` and `ruleSetIDs` are unused.
    public var template: AgentConfig
    public var rules: [String]
    public var ruleSetIDs: [UUID]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, summary: String = "", color: String = "#6E56CF",
                template: AgentConfig = AgentConfig(prompt: "", output: [OutputField("summary", .text)]),
                rules: [String] = [], ruleSetIDs: [UUID] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.color = color
        self.template = template
        self.rules = rules
        self.ruleSetIDs = ruleSetIDs
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Block",
                  summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
                  color: try c.decodeIfPresent(String.self, forKey: .color) ?? "#6E56CF",
                  template: try c.decodeIfPresent(AgentConfig.self, forKey: .template)
                    ?? AgentConfig(prompt: "", output: [OutputField("summary", .text)]),
                  rules: try c.decodeIfPresent([String].self, forKey: .rules) ?? [],
                  ruleSetIDs: try c.decodeIfPresent([UUID].self, forKey: .ruleSetIDs) ?? [],
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date())
    }

    /// A block from a step: its prompt, fields, verdict and settings; the
    /// step's rules become the block's.
    public static func from(_ config: AgentConfig, name: String) -> WorkflowBlock {
        var template = config
        template.blockID = nil
        template.rules = []
        template.ruleSetIDs = []
        return WorkflowBlock(name: name, template: template, rules: config.rules, ruleSetIDs: config.ruleSetIDs)
    }
}

/// What a step placed from a block runs: the block, then this use's own
/// instructions and overrides. Pure — the runner, the validator, the
/// estimate and the editor read the same thing.
public enum BlockResolver {

    public static func block(of config: AgentConfig, in blocks: [WorkflowBlock]) -> WorkflowBlock? {
        config.blockID.flatMap { id in blocks.first { $0.id == id } }
    }

    /// The step as it runs. A step from a deleted block runs as written
    /// (the validator says so first).
    public static func effective(_ config: AgentConfig, blocks: [WorkflowBlock]) -> AgentConfig {
        guard let found = Self.block(of: config, in: blocks) else { return config }
        var result = found.template
        result.blockID = found.id
        let own = config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            result.prompt = found.template.prompt + "\n\n## For this step\n" + own
        }
        result.expertID = config.expertID ?? found.template.expertID
        result.model = config.model ?? found.template.model
        result.skills = Array(Set(found.template.skills + config.skills)).sorted()
        result.connectorIDs = found.template.connectorIDs
            + config.connectorIDs.filter { !found.template.connectorIDs.contains($0) }
        // The rules are composed apart (RuleComposer): they say where they come from.
        result.rules = config.rules
        result.ruleSetIDs = config.ruleSetIDs
        return result
    }

    /// The verdict options a step answers, whatever its kind: its links may
    /// follow one of them. Empty: it has no verdict.
    public static func verdictOptions(of node: WorkflowNode, blocks: [WorkflowBlock]) -> [String] {
        switch node.kind {
        case .agent(let config):
            return effective(config, blocks: blocks).verdict?.cleanOptions ?? []
        case .forEach(let config):
            return effective(config.agent, blocks: blocks).verdict?.cleanOptions ?? []
        case .approval(let config):
            return config.cleanOptions
        case .command:
            return CommandConfig.verdictOptions
        default:
            return []
        }
    }
}

/// The rules a step runs with, grouped by where they come from (ADR-0019).
public enum RuleComposer {

    public struct Group: Equatable, Sendable {
        /// "the block «Revue PHP»", "this step", "the rule set «Style»",
        /// "the link from `intent`".
        public var source: String
        public var rules: [String]
    }

    /// Without a state (the editor), every link into the step counts; with
    /// one, only the links the run took, and the ways back up it went round.
    public static func groups(for node: WorkflowNode, in workflow: Workflow, blocks: [WorkflowBlock],
                              ruleSets: [RuleSet], state: RunState? = nil) -> [Group] {
        let config: AgentConfig
        switch node.kind {
        case .agent(let agent): config = agent
        case .forEach(let each): config = each.agent
        default: config = AgentConfig()
        }
        var groups: [Group] = []
        func add(_ source: String, _ rules: [String], sets: [UUID]) {
            let clean = rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !clean.isEmpty { groups.append(Group(source: source, rules: clean)) }
            for id in sets {
                guard let set = ruleSets.first(where: { $0.id == id }) else { continue }
                let rules = set.rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !rules.isEmpty, !groups.contains(where: { $0.source == "the rule set «\(set.name)»" }) {
                    groups.append(Group(source: "the rule set «\(set.name)»", rules: rules))
                }
            }
        }
        if let block = BlockResolver.block(of: config, in: blocks) {
            add("the block «\(block.name)»", block.rules, sets: block.ruleSetIDs)
        }
        add("this step", config.rules, sets: config.ruleSetIDs)
        let planner = state.map { _ in WorkflowPlanner(workflow) }
        for edge in workflow.edges where edge.to == node.id {
            if let state, let planner {
                if edge.isRetry {
                    guard (state.iterations[WorkflowPlanner.retryKey(edge)] ?? 0) > 0 else { continue }
                } else if !planner.isTaken(edge, in: state) {
                    continue
                }
            }
            let source = edge.isRetry ? "the way back from `\(edge.from)`" : "the link from `\(edge.from)`"
            add(source, edge.rules, sets: edge.ruleSetIDs)
        }
        return groups
    }

    /// The section appended to the step's system prompt.
    public static func instructions(_ groups: [Group]) -> String {
        guard !groups.isEmpty else { return "" }
        var lines = ["## Rules for this step", "Follow every rule below."]
        for group in groups {
            lines.append("")
            lines.append("From \(group.source):")
            lines += group.rules.map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// What a step sent back up learns: which step sent it, with what verdict and why.
    public static func retryNotes(for node: String, in workflow: Workflow, state: RunState) -> String {
        var notes: [String] = []
        for edge in workflow.retryEdges where edge.to == node {
            let done = state.iterations[WorkflowPlanner.retryKey(edge)] ?? 0
            guard done > 0, let last = state.history[edge.from]?.last else { continue }
            let verdict = last["verdict"]?.plainText ?? ""
            let reason = last["verdictReason"]?.plainText ?? ""
            notes.append("- Round \(done + 1): `\(edge.from)` answered «\(verdict)»"
                         + (reason.isEmpty ? "." : ": \(reason)"))
        }
        guard !notes.isEmpty else { return "" }
        return "## This step runs again\n" + notes.joined(separator: "\n")
            + "\nTake it into account: answer what was found lacking."
    }
}
