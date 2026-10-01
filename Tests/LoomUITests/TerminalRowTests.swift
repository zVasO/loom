import Testing
import Foundation
import SwiftUI
import LoomTerminal
@testable import LoomUI

// Reverse video: how a TUI that hid the cursor draws its own caret and
// highlights. Without it, hiding our block (DECTCEM) left the caret invisible.
@MainActor
@Suite("TerminalRow — cell styles")
struct TerminalRowTests {

    private func run(_ style: CellStyle) -> AttributedString.Runs.Run? {
        TerminalRow.attributed(TerminalLine(cells: [TerminalCell(character: "x", style: style)])).runs.first
    }

    @Test("an inverse cell in default colours paints the text colour behind the pane colour")
    func inverseDefault() {
        let inverse = run(CellStyle(attributes: [.inverse]))
        #expect(inverse?.backgroundColor == DefaultTheme.primaryText)
        #expect(inverse?.foregroundColor == DefaultTheme.contentBackground)
    }

    @Test("an inverse cell swaps explicit colours")
    func inverseExplicit() {
        let inverse = run(CellStyle(foreground: .ansi(1), background: .ansi(4), attributes: [.inverse]))
        #expect(inverse?.foregroundColor == DefaultTheme.terminalColor(.ansi(4), isBackground: false))
        #expect(inverse?.backgroundColor == DefaultTheme.terminalColor(.ansi(1), isBackground: false))
    }

    @Test("a plain cell keeps its colours and no background")
    func plain() {
        let plain = run(CellStyle(foreground: .ansi(2)))
        #expect(plain?.foregroundColor == DefaultTheme.terminalColor(.ansi(2), isBackground: false))
        #expect(plain?.backgroundColor == nil)
    }
}
