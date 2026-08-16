import BunshinTerminal
import SwiftUI

/// Rendu d'un `TerminalScreen` — la vue tire des valeurs, jamais le moteur
/// (ADR-0007/0008). Renderer simple pour la coquille v1 ; le banc 120 Hz
/// décidera s'il faut passer à un rendu par régions sales.
public struct TerminalScreenView: View {
    public let screen: TerminalScreen

    public init(screen: TerminalScreen) {
        self.screen = screen
    }

    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(screen.lines.enumerated()), id: \.offset) { _, line in
                    Text(attributed(line))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .background(DefaultTheme.background)
    }

    private func attributed(_ line: TerminalLine) -> AttributedString {
        var result = AttributedString()
        for cell in line.cells {
            var piece = AttributedString(String(cell.character))
            piece.foregroundColor = DefaultTheme.terminalColor(cell.style.foreground, isBackground: false)
            let background = DefaultTheme.terminalColor(cell.style.background, isBackground: true)
            if background != .clear { piece.backgroundColor = background }
            if cell.style.attributes.contains(.bold) { piece.font = .system(.body, design: .monospaced).bold() }
            result.append(piece)
        }
        return result
    }
}
