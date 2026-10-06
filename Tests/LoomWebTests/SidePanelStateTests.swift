import Testing
import Foundation
import LoomWeb

// The side panel's reveal rules. Each open or close resizes the terminal —
// one repaint of claude's conversation — so the agent shows its browser at
// most once per stack, and never against a close by the user.

@Suite("SidePanelState — who opens the browser beside the terminal")
struct SidePanelStateTests {

    private let pane = UUID()

    @Test("the user opens and closes; the button closes only what is open")
    func ouvertureParLUtilisateur() {
        var state = SidePanelState()
        #expect(!state.buttonCloses(agentActiveOffscreen: false))
        state.open(.pane(pane))
        #expect(state.isOpen && state.source == .pane(pane))
        #expect(state.buttonCloses(agentActiveOffscreen: false))
        #expect(!state.buttonCloses(agentActiveOffscreen: true),
                "with the agent busy off screen, the click means: show me")
        state.close()
        #expect(!state.isOpen)
    }

    @Test("panel closed: the agent's first use asks for a reveal, the view settles it once")
    func revelationParLAgentUneSeuleFois() {
        var state = SidePanelState()
        let first = state.agentDidUseBrowser()
        #expect(first)
        #expect(state.pendingReveal && !state.isOpen)
        let second = state.agentDidUseBrowser()
        #expect(!second, "already pending: nothing more")
        state.resolvePendingReveal(terminalFits: true)
        #expect(state.isOpen && state.source == .agent && state.agentRevealed)
        #expect(!state.pendingReveal)
        let third = state.agentDidUseBrowser()
        #expect(!third, "revealed once: never again")
    }

    @Test("closed by the user after the reveal: the agent never reopens it")
    func fermetureParLUtilisateurEstDefinitive() {
        var state = SidePanelState()
        state.agentDidUseBrowser()
        state.resolvePendingReveal(terminalFits: true)
        state.close()
        let first = state.agentDidUseBrowser()
        #expect(!first)
        #expect(!state.isOpen && !state.pendingReveal)
    }

    @Test("panel open on a pane of the user: the first use switches to the agent's browser, once")
    func basculeVersLAgentUneFois() {
        var state = SidePanelState()
        state.open(.pane(pane))
        let first = state.agentDidUseBrowser()
        #expect(first)
        #expect(state.isOpen && state.source == .agent)
        state.open(.pane(pane))
        let second = state.agentDidUseBrowser()
        #expect(!second, "the user went back to their pane: it stays")
        #expect(state.source == .pane(pane))
    }

    @Test("too narrow at reveal time: nothing opens, and a later use may try again")
    func tropEtroitPasDeRevelation() {
        var state = SidePanelState()
        state.agentDidUseBrowser()
        state.resolvePendingReveal(terminalFits: false)
        #expect(!state.isOpen && !state.agentRevealed && !state.pendingReveal)
        let first = state.agentDidUseBrowser()
        #expect(first)
    }

    @Test("the user picking the agent's browser counts as its reveal")
    func choixUtilisateurCompteCommeRevelation() {
        var state = SidePanelState()
        state.open(.agent)
        state.close()
        let first = state.agentDidUseBrowser()
        #expect(!first)
    }

    @Test("a closed pane leaves no panel pointing at it")
    func sourceDisparueFermeLePanneau() {
        var state = SidePanelState()
        state.open(.pane(pane))
        state.sourceRemoved(.pane(UUID()))
        #expect(state.isOpen, "another pane: untouched")
        state.sourceRemoved(.pane(pane))
        #expect(!state.isOpen && state.source == nil)
    }

    @Test("a relaunch remembers only that the agent already revealed its browser")
    func memoireDeRevelation() {
        var state = SidePanelState(agentRevealed: true)
        #expect(!state.isOpen)
        let first = state.agentDidUseBrowser()
        #expect(!first)
    }
}
