import Testing
import Foundation
@testable import LoomWorkflows

// A library starts empty now; an older one lets go, once, of the defaults it
// was seeded with — only what is still as shipped and used by nothing left.
@Suite("Shipped defaults — what an older library lets go of")
struct ShippedDefaultsTests {

    private let flow = BuiltInWorkflows.prReview()
    private let experts = BuiltInWorkflows.experts
    private let connectors = BuiltInWorkflows.connectors

    @Test("an untouched seeded library lets go of everything it was seeded with")
    func untouched() {
        let leftovers = BuiltInWorkflows.untouchedLeftovers(workflows: [flow], experts: experts, connectors: connectors)
        #expect(leftovers.workflowIDs == [flow.id])
        #expect(Set(leftovers.expertIDs) == Set(experts.map(\.id)))
        #expect(Set(leftovers.connectorIDs) == Set(connectors.map(\.id)))
    }

    @Test("the dates alone do not make the review the person's own")
    func datesDoNotCount() {
        var stored = flow
        stored.createdAt = Date(timeIntervalSince1970: 0)
        stored.updatedAt = Date(timeIntervalSince1970: 1)
        #expect(BuiltInWorkflows.untouchedLeftovers(workflows: [stored], experts: [], connectors: []).workflowIDs
                == [flow.id])
    }

    @Test("an edited review stays, and so do the experts it still dispatches to")
    func editedReviewStays() {
        var edited = flow
        edited.name = "Ma revue"
        let leftovers = BuiltInWorkflows.untouchedLeftovers(workflows: [edited], experts: experts, connectors: connectors)
        #expect(leftovers.workflowIDs.isEmpty)
        let used = Set(WorkflowBundle.make(edited, experts: experts, connectors: connectors).experts.map(\.id))
        #expect(!used.isEmpty)
        #expect(Set(leftovers.expertIDs).isDisjoint(with: used), "an expert a workflow still uses stays")
    }

    @Test("an edited expert stays; a workflow of the person's own keeps the expert it uses")
    func ownWorkStays() throws {
        var edited = try #require(experts.first)
        edited.systemPrompt += "\nAlways cite the ticket."
        let kept = try #require(experts.last)
        let mine = Workflow(name: "Mine", nodes: [
            WorkflowNode(id: "a", title: "a", kind: .agent(AgentConfig(expertID: kept.id, prompt: "go"))),
        ])
        let library = [edited] + experts.dropFirst()
        let leftovers = BuiltInWorkflows.untouchedLeftovers(workflows: [flow, mine], experts: library,
                                                             connectors: connectors)
        #expect(!leftovers.expertIDs.contains(edited.id), "edited: the person's now")
        #expect(!leftovers.expertIDs.contains(kept.id), "used by a workflow that stays")
        #expect(leftovers.workflowIDs == [flow.id])
    }

    @Test("nothing of the person's own is ever a leftover")
    func ownLibrary() {
        let mine = Workflow(name: "Mine")
        let expert = Expert(name: "Mine", domain: "x", systemPrompt: "y")
        #expect(BuiltInWorkflows.untouchedLeftovers(workflows: [mine], experts: [expert], connectors: []).isEmpty)
    }

    @Test("as shipped still holds after the library's own round trip on disk")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowLibraryStore(directory: directory)
        try store.save(flow)
        for expert in experts { try store.save(expert) }
        for connector in connectors { try store.save(connector) }

        let leftovers = BuiltInWorkflows.untouchedLeftovers(workflows: store.loadWorkflows(), experts: store.loadExperts(),
                                                             connectors: store.loadConnectors(), blocks: store.loadBlocks())
        #expect(leftovers.workflowIDs == [flow.id])
        #expect(Set(leftovers.expertIDs) == Set(experts.map(\.id)))
        #expect(Set(leftovers.connectorIDs) == Set(connectors.map(\.id)))
    }
}
