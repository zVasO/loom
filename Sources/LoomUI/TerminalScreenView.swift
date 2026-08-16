import AppKit
import LoomTerminal
import SwiftUI

/// Métriques de la grille terminal : la vue et le PTY doivent parler de la MÊME
/// géométrie (TRM-02) — c'est ici qu'un point devient une cellule.
public enum TerminalMetrics {
    public static let fontSize: CGFloat = 12.5
    static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    /// Mesure sur une SONDE de 100 caractères via TextKit : l'avance d'un glyphe
    /// mono est fractionnaire (≈7,52 pt à 12,5) — la mesurer sur un seul caractère
    /// arrondit, et l'erreur ×100 colonnes faisait annoncer au PTY plus de colonnes
    /// que la vue n'en affiche : texte rogné à droite.
    public static let cellSize: CGSize = {
        let probe = NSAttributedString(string: String(repeating: "0", count: 100),
                                       attributes: [.font: nsFont])
        let measured = probe.size()
        return CGSize(width: measured.width / 100,
                      height: ceil(measured.height) + 1)
    }()

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
    public let history: [TerminalLine]
    /// Collé en bas pendant le stream ; remonter dans l'historique décroche,
    /// revenir en bas raccroche (suivi de la géométrie de défilement).
    @State private var pinnedToBottom = true

    public init(screen: TerminalScreen, history: [TerminalLine] = []) {
        self.screen = screen
        self.history = history
    }

    public var body: some View {
        let cell = TerminalMetrics.cellSize
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, line in
                        row(line, height: cell.height)
                    }
                    ForEach(Array(screen.lines.enumerated()), id: \.offset) { index, line in
                        row(line, height: cell.height,
                            cursorCol: index == screen.cursor.row ? screen.cursor.col : nil)
                    }
                    Color.clear.frame(height: 0).id("bas")   // marqueur d’ancrage : hauteur nulle, sinon il rogne le haut
                }
                .padding(8)
            }
            .scrollGeometryPinning($pinnedToBottom)
            .onChange(of: screen.revision) {
                if pinnedToBottom { proxy.scrollTo("bas", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bas", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(DefaultTheme.contentBackground)
    }

    /// `cursorCol` : le curseur du terminal, dessiné par NOUS (l'agent ne peint
    /// que ses cellules) — sans lui, on taperait en aveugle dans son champ.
    private func row(_ line: TerminalLine, height: CGFloat, cursorCol: Int? = nil) -> some View {
        Text(attributed(line))
            .font(.system(size: TerminalMetrics.fontSize, design: .monospaced))
            .textSelection(.enabled)   // sélection à la souris + ⌘C
            .frame(height: height, alignment: .leading)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .topLeading) {
                if let col = cursorCol {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DefaultTheme.accent.opacity(0.55))
                        .frame(width: TerminalMetrics.cellSize.width, height: height - 2)
                        .offset(x: CGFloat(col) * TerminalMetrics.cellSize.width, y: 1)
                }
            }
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


private extension View {
    /// macOS 15+ : suit la position réelle de défilement pour décider de l'ancrage
    /// bas ; en deçà, on reste toujours collé (repli honnête).
    @ViewBuilder
    func scrollGeometryPinning(_ pinned: Binding<Bool>) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, isAtBottom in
                pinned.wrappedValue = isAtBottom
            }
        } else {
            self
        }
    }
}
