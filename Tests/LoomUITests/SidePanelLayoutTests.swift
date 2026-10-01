import Testing
import CoreGraphics
import LoomUI

// The side panel's geometry. Every width the terminal column takes reaches
// the PTY — one repaint of claude's conversation per resize — so the layout
// keeps the terminal at its 80-column floor and refuses splits it cannot
// give a real terminal. The floor is passed explicitly: the app derives it
// from a font measured at run time.

@Suite("SidePanelLayout — terminal and browser side by side")
struct SidePanelLayoutTests {

    private let floor: CGFloat = 620

    @Test("never dragged: the panel takes its default share")
    func partParDefaut() {
        let layout = SidePanelLayout.resolve(available: 1500, preferredPanelWidth: nil, terminalMinimum: floor)
        #expect(layout.showsPanel && layout.fits)
        #expect(layout.panelWidth == (1500 * SidePanelLayout.defaultPanelFraction).rounded())
        #expect(layout.terminalWidth + SidePanelLayout.handleWidth + layout.panelWidth == 1500)
    }

    @Test("a dragged width is kept while both minimums hold")
    func largeurPrefereeRespectee() {
        let layout = SidePanelLayout.resolve(available: 1500, preferredPanelWidth: 500, terminalMinimum: floor)
        #expect(layout.panelWidth == 500)
        #expect(layout.terminalWidth == 1500 - SidePanelLayout.handleWidth - 500)
    }

    @Test("the panel is bounded by its own minimum and by the terminal's floor")
    func panneauBorne() {
        let wide = SidePanelLayout.resolve(available: 1500, preferredPanelWidth: 2000, terminalMinimum: floor)
        #expect(wide.terminalWidth == floor, "the terminal keeps its 80 columns")
        #expect(wide.fits)
        let narrow = SidePanelLayout.resolve(available: 1500, preferredPanelWidth: 100, terminalMinimum: floor)
        #expect(narrow.panelWidth == SidePanelLayout.minimumPanelWidth)
    }

    @Test("too narrow for both: the panel keeps its minimum and says it does not fit")
    func fenetreTropEtroite() {
        let layout = SidePanelLayout.resolve(available: 700, preferredPanelWidth: nil, terminalMinimum: floor)
        #expect(layout.showsPanel)
        #expect(!layout.fits, "an automatic reveal must not happen here")
        #expect(layout.panelWidth == SidePanelLayout.minimumPanelWidth)
        #expect(layout.terminalWidth >= SidePanelLayout.terminalFloor)
    }

    @Test("a degenerate width shows no split at all — the terminal is never fitted to a sliver")
    func largeurDegenereeSansSplit() {
        for available: CGFloat in [0, 300, 520] {
            let layout = SidePanelLayout.resolve(available: available, preferredPanelWidth: 400,
                                                 terminalMinimum: floor)
            #expect(!layout.showsPanel, "\(available) pt")
            #expect(layout.terminalWidth == available)
        }
    }
}

@Suite("TerminalFitPolicy — when a measured size becomes a PTY resize")
struct TerminalFitPolicyTests {

    private let size = CGSize(width: 800, height: 600)

    @Test("a suspended pane never fits, whatever its size")
    func suspenduNeFitJamais() {
        #expect(TerminalFitPolicy.decide(size: size, suspended: true, isFirstFitForSurface: true) == .skip)
        #expect(TerminalFitPolicy.decide(size: size, suspended: true, isFirstFitForSurface: false) == .skip)
    }

    @Test("under the minimum pane size nothing is applied")
    func tropPetitIgnore() {
        let tiny = CGSize(width: 159, height: 600)
        #expect(TerminalFitPolicy.decide(size: tiny, suspended: false, isFirstFitForSurface: true) == .skip)
        #expect(TerminalFitPolicy.decide(size: .zero, suspended: false, isFirstFitForSurface: false) == .skip)
    }

    @Test("the first fit of a surface is immediate, the next ones wait for the size to settle")
    func premierImmediatEnsuiteDiffere() {
        #expect(TerminalFitPolicy.decide(size: size, suspended: false, isFirstFitForSurface: true) == .immediate)
        #expect(TerminalFitPolicy.decide(size: size, suspended: false, isFirstFitForSurface: false) == .debounced)
    }
}
