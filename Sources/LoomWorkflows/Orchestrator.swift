import Foundation
import LoomAPI

/// The orchestrator's words (ADR-0018): Loom's rules for it, the brief it
/// starts from, and the lines Loom types into its session as the run moves.
/// Pure — the runner sends them, the tests read them.
public enum OrchestratorPrompt {

    /// Loom's own rules, before the expert's instructions and the workflow's.
    public static let rules = """
    You are the orchestrator of a Loom workflow run: a conductor. Loom runs the \
    workflow's steps, each by an expert; you follow the run, check each answer, \
    and steer when it helps. The person supervising may also talk to you here.

    Your tools (Loom MCP server):
    - loom_workflow_get: where the run stands — every step, its status, its pass, \
    whether it has an answer, your remaining budget.
    - loom_workflow_step_read: a step's answer (and, for a visible step, its last messages).
    - loom_workflow_step_ask: ask a step a follow-up question; it answers with \
    everything it read. Costs one intervention.
    - loom_workflow_step_rerun: run a step again with your instructions; the steps \
    after it run again too. Costs one intervention.
    - loom_workflow_step_skip: skip a step that has not run. Costs one intervention.
    - loom_workflow_stop: stop the run.
    - loom_workflow_proceed: let the report be written when Loom waits for you.

    Rules:
    - Loom tells you when a step finishes or fails, and when a step writes to you. Between \
    those messages, do nothing: do not poll loom_workflow_get in a loop.
    - Read an answer before judging it. Ask before rerunning when a question is enough.
    - Rerun only with a precise reason and precise instructions; never to get a \
    different opinion by chance.
    - You never change code, files, tickets or the pull request: you read, ask and steer.
    - Stay within the budget; when it is spent, say what you would have done.
    - Keep your messages short: the person reads them.
    """

    /// A step as the brief lists it.
    public struct StepLine: Sendable, Equatable {
        public var id: String
        public var title: String
        public var type: NodeType
        public var expert: String?
        public var mode: AgentMode?
        public var next: [String]

        public init(id: String, title: String, type: NodeType, expert: String? = nil,
                    mode: AgentMode? = nil, next: [String] = []) {
            self.id = id
            self.title = title
            self.type = type
            self.expert = expert
            self.mode = mode
            self.next = next
        }
    }

    public static func steps(of workflow: Workflow, experts: [Expert]) -> [StepLine] {
        let successors = WorkflowGraph.successors(workflow)
        return workflow.nodes.map { node in
            var line = StepLine(id: node.id, title: node.title, type: node.kind.type,
                                next: successors[node.id] ?? [])
            if case .agent(let config) = node.kind {
                line.expert = config.expertID.flatMap { id in experts.first { $0.id == id }?.name }
                line.mode = config.mode
            }
            return line
        }
    }

    /// The first message of the session: the run, its steps, the budget.
    public static func brief(workflow: Workflow, experts: [Expert], subject: String, note: String,
                             instructions: String, budget: Int, rerunsPerStep: Int,
                             reviewBeforeArtifact: Bool) -> String {
        var lines = ["# Run of \"\(workflow.name)\" — \(subject)"]
        if !workflow.summary.isEmpty { lines.append(workflow.summary) }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Note from the person who started it: \(note)")
        }
        lines.append("")
        lines.append("## Steps (id — title)")
        for step in steps(of: workflow, experts: experts) {
            var line = "- `\(step.id)` — \(step.title) [\(step.type.rawValue)"
            if let expert = step.expert { line += ", \(expert)" }
            if let mode = step.mode { line += ", \(mode.rawValue)" }
            line += "]"
            if !step.next.isEmpty { line += " → " + step.next.map { "`\($0)`" }.joined(separator: ", ") }
            lines.append(line)
        }
        lines.append("")
        lines.append("Budget: \(budget) intervention(s) (questions, reruns, skips), "
                     + "\(rerunsPerStep) rerun(s) per step at most.")
        if reviewBeforeArtifact {
            lines.append("Before the report is written, Loom waits for you: rerun what needs it, "
                         + "then call loom_workflow_proceed.")
        }
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append("")
            lines.append("## What this workflow expects of you")
            lines.append(extra)
        }
        lines.append("")
        lines.append("The run has started. Acknowledge in one line, then wait for Loom's messages.")
        return lines.joined(separator: "\n")
    }

    /// One line per thing that happened, sent together when the session is ready.
    public enum Event: Sendable, Equatable {
        case stepDone(id: String, title: String, pass: Int, summary: String)
        case stepFailed(id: String, title: String, error: String)
        case newPass(loop: String, pass: Int)
        case fromStep(id: String, title: String, text: String)
        case checkpoint(reason: Checkpoint)
        case finished(status: String, error: String?)
    }

    public enum Checkpoint: Sendable, Equatable {
        /// Everything ran; the report is next.
        case beforeReport
        /// The run would end on a failure.
        case failure(step: String)
    }

    public static func message(for events: [Event]) -> String {
        let lines = events.map { event -> String in
            switch event {
            case .stepDone(let id, let title, let pass, let summary):
                let head = "[Loom] `\(id)` (\(title)) is done" + (pass > 1 ? " — pass \(pass)" : "") + "."
                let short = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return short.isEmpty ? head + " Read it with loom_workflow_step_read."
                    : head + " " + String(short.prefix(240)).replacingOccurrences(of: "\n", with: " ")
                        + (short.count > 240 ? "…" : "") + " (loom_workflow_step_read for all of it)"
            case .stepFailed(let id, let title, let error):
                return "[Loom] `\(id)` (\(title)) failed: \(error)"
            case .newPass(let loop, let pass):
                return "[Loom] `\(loop)` starts pass \(pass)."
            case .fromStep(let id, let title, let text):
                return "[Loom] `\(id)` (\(title)) writes to you: \(text)"
            case .checkpoint(.beforeReport):
                return "[Loom] Every step is done; the report is next and waits for you. Rerun what needs it "
                    + "(loom_workflow_step_rerun), or call loom_workflow_proceed. If you end your turn without "
                    + "either, the report is written."
            case .checkpoint(.failure(let step)):
                return "[Loom] The run is about to end because `\(step)` failed. Rerun it with instructions "
                    + "(loom_workflow_step_rerun), skip it (loom_workflow_step_skip) or let the run end "
                    + "(loom_workflow_proceed or end your turn)."
            case .finished(let status, let error):
                return "[Loom] The run is over: \(status)" + (error.map { " — \($0)" } ?? "") + ". "
                    + "Summarize it for the person in a few lines."
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A rerun's instructions, after the step's own prompt.
    public static func rerunAddendum(_ instructions: String, previous: String?) -> String {
        var text = "\n\n## The orchestrator asks you to redo this step\n" + instructions
        if let previous, !previous.isEmpty {
            text += "\n\nYour previous answer, for reference:\n" + String(previous.prefix(6000))
        }
        return text
    }

    /// What a visible step learns about the orchestrator.
    public static let stepRules = """
    This session is a step of a Loom workflow run, followed by an orchestrator. \
    If you are blocked or need a decision, write to it with loom_workflow_message \
    (one short message), then keep going with what you can.
    """
}
