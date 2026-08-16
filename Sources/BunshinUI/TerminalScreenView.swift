import AppKit
import BunshinTerminal
import SwiftUI

/// Métriques de la grille terminal : la vue et le PTY doivent parler de la MÊME
/// géométrie (TRM-02) — c'est ici qu'un point devient une cellule.
public enum TerminalMetrics {
    public static let fontSize: CGFloat = 12.5
    static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    public static var cellSize: CGSize {
        let width = ("0" as NSString).size(withAttributes: [.font: nsFont]).width
        let height = ceil(nsFont.ascender - nsFont.descender + nsFont.leading) + 1
        return CGSize(width: width, height: height)
    }

    /// Combien de cellules tiennent dans `size` (padding de la vue déduit).
    public static func grid(fitting size: CGSize, insets: CGFloat = 16) -> (cols: Int, rows: Int) {
        let cell = cellSize
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        return (max(20, Int((size.width - insets) / cell.width)),
                max(4, Int((size.height - insets) / cell.height)))
    }
}

/// Rendu d'un `TerminalScreen` — la vue tire des valeurs, jamais le moteur
/// (ADR-0007/0008). La grille correspond exactement à la géométrie du PTY :
/// aucun défilement, aucun repli — l'agent dessine pour la taille réelle.
public struct TerminalScreenView: View {
    public let screen: TerminalScreen

    public init(screen: TerminalScreen) {
        self.screen = screen
    }

    public var body: some View {
        let cell = TerminalMetrics.cellSize
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(screen.lines.enumerated()), id: \.offset) { _, line in
                Text(attributed(line))
                    .font(.system(size: TerminalMetrics.fontSize, design: .monospaced))
                    .frame(height: cell.height, alignment: .leading)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(DefaultTheme.contentBackground)
    }

    private func attributed(_ line: TerminalLine) -> AttributedString {
        var result = AttributedString()
        for cell in line.cells {
            var piece = AttributedString(String(cell.character))
            piece.foregroundColor = DefaultTheme.terminalColor(cell.style.foreground, isBackground: false)
            let background = DefaultTheme.terminalColor(cell.style.background, isBackground: true)
            if background != .clear { piece.backgroundColor = background }
            if cell.style.attributes.contains(.bold) {
                piece.font = .system(size: TerminalMetrics.fontSize, design: .monospaced).bold()
            }
            result.append(piece)
        }
        return result
    }
}
