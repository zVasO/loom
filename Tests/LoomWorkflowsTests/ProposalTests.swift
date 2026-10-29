import Testing
import Foundation
import LoomAPI
import LoomCore
@testable import LoomWorkflows

// An agent's changes are proposals (ADR-0020): inert until the person
// validates them; the version validated before is what counts meanwhile.
@Suite("Agents' proposals")
struct ProposalTests {

    private func start() -> WorkflowNode { WorkflowNode(id: "start", title: "Start", kind: .start(StartConfig())) }

    @Test("a creation counts for nothing until validated; reverted, it is gone")
    func creation() {
        let created = Workflow.proposing(Workflow(name: "New"), over: nil, by: "builder", sessionID: "s1")
        #expect(created.isProposed)
        #expect(created.proposal?.by == "builder" && created.proposal?.sessionID == "s1")
        #expect(created.accepted == nil)
        #expect(created.reverted() == nil)
        let validated = created.validated()
        #expect(!validated.isProposed && validated.accepted == validated)
    }

    @Test("a change to a validated workflow keeps the one before; a second change keeps it still")
    func changes() {
        let original = Workflow(name: "Review", nodes: [start()])
        var first = original
        first.name = "Review v2"
        let proposed = Workflow.proposing(first, over: original, by: "agent")
        #expect(proposed.accepted == original)
        var second = proposed
        second.name = "Review v3"
        let again = Workflow.proposing(second, over: proposed, by: "agent")
        #expect(again.name == "Review v3")
        #expect(again.accepted == original, "the version to go back to is the one the person validated")
        #expect(again.reverted() == original)
        #expect(again.validated().name == "Review v3")
        let data = try! WorkflowJSON.encoder.encode(again)
        let decoded = try! WorkflowJSON.decoder.decode(Workflow.self, from: data)
        #expect(decoded.proposal?.previous?.name == "Review", "the previous version survives the file")
        let bare = try! WorkflowJSON.decoder.decode(Workflow.self, from: Data(#"{"name":"old"}"#.utf8))
        #expect(bare.proposal == nil)
    }

    @Test("a workflow using anything still proposed lists it")
    func pending() {
        let block = WorkflowBlock.proposing(WorkflowBlock(name: "Revue PHP"), over: nil, by: "agent")
        let expert = Expert.proposing(Expert(name: "PHP"), over: nil, by: "agent")
        let workflow = Workflow(name: "W", nodes: [start(), WorkflowNode(id: "a", title: "A", kind: .agent(
            AgentConfig(expertID: expert.id, blockID: block.id)))])
        let bundle = WorkflowBundle.make(workflow, experts: [expert], connectors: [], blocks: [block], ruleSets: [])
        #expect(bundle.pendingProposals == ["the block «Revue PHP»", "the expert «PHP»"])
        let proposed = Workflow.proposing(workflow, over: nil, by: "agent")
        #expect(WorkflowValidator.validate(proposed).contains { $0.message.hasPrefix("Proposed by agent") })
    }

    @Test("the summary of a change flags commands and new tools")
    func diff() {
        let old = Workflow(name: "W", nodes: [start()], edges: [])
        var new = old
        new.nodes.append(WorkflowNode(id: "tests", title: "Tests", kind: .command(
            CommandConfig(command: "vendor/bin/phpunit\nmore", allowOnPullRequests: true))))
        new.edges.append(WorkflowEdge(from: "start", to: "tests"))
        let changes = ProposalDiff.workflow(new, previous: old)
        #expect(changes.contains { $0.text == "Step added: `tests` (command, «Tests»)." })
        let command = changes.first { $0.flagged }
        #expect(command?.text == "Command `tests`: vendor/bin/phpunit — runs on pull requests (their code)")
        #expect(changes.contains { $0.text.hasPrefix("Links: 1 added") })
        #expect(ProposalDiff.workflow(old, previous: old).map(\.text) == ["Positions or layout only."])
        #expect(ProposalDiff.workflow(new, previous: nil).contains { $0.flagged }, "a new workflow shows its commands too")

        let expert = Expert(name: "PHP")
        var wider = expert
        wider.allowedTools.append("Bash(rm:*)")
        let flagged = ProposalDiff.expert(wider, previous: expert).filter(\.flagged)
        #expect(flagged.first?.text.contains("Bash(rm:*)") == true)
    }

    @Test("the reference covers every step type, and its example is a valid workflow")
    func reference() throws {
        let text = WorkflowReference.markdown()
        for type in NodeType.allCases {
            #expect(text.contains("### `\(type.rawValue)`"), "\(type.rawValue)")
            let node = WorkflowReference.defaultNode(type)
            let data = try WorkflowJSON.encoder.encode(node)
            #expect(try WorkflowJSON.decoder.decode(WorkflowNode.self, from: data) == node)
        }
        #expect(text.contains("PROPOSAL"))
        let example = WorkflowReference.example
        let errors = WorkflowValidator.validate(example).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
        #expect(BuilderPrompt.opening(improving: example).contains(example.id.uuidString))
        #expect(BuilderPrompt.instructions.contains("loom_library_reference"))
    }
}
