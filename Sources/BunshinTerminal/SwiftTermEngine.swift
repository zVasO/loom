import BunshinCore
import Foundation
import SwiftTerm

/// Adapter de production du seam `TerminalEngine` (ADR-0001).
///
/// Confinement STRICT (ADR-0007) : toutes les méthodes s'exécutent sur la queue
/// sérielle de la session — le moteur SwiftTerm ne contient aucune primitive de
/// synchronisation malgré ce que sa doc affirme (docs/research/swiftterm-pty.md §2).
/// Le snapshot boucle sur `getLine(row:)` borné aux lignes visibles — jamais
/// `getBufferAsData()`, qui inclut le scrollback (recherche §1.4).
public final class SwiftTermEngine: TerminalEngine {

    private final class HeadlessDelegate: TerminalDelegate {
        // Réponses du terminal vers le PTY (DA/DSR…). Branché par SessionRuntime
        // quand la tranche « écho amont » arrivera ; d'ici là, collectées nulle part.
        var onSend: ((ArraySlice<UInt8>) -> Void)?
        func send(source: Terminal, data: ArraySlice<UInt8>) { onSend?(data) }
    }

    private let terminal: Terminal
    private let headlessDelegate = HeadlessDelegate()
    private var geometry: TerminalGeometry
    private var revision: UInt64 = 0
    private var dirtyRows = IndexSet()

    public init(geometry: TerminalGeometry, scrollback: Int) {
        self.geometry = geometry
        self.terminal = Terminal(
            delegate: headlessDelegate,
            options: TerminalOptions(cols: geometry.cols, rows: geometry.rows, scrollback: scrollback)
        )
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(buffer: bytes)
        if let updated = terminal.getUpdateRange() {
            dirtyRows.insert(integersIn: updated.startY...updated.endY)
            terminal.clearUpdateRange()
            revision += 1
        }
    }

    public func resize(to geometry: TerminalGeometry) {
        self.geometry = geometry
        terminal.resize(cols: geometry.cols, rows: geometry.rows)
        dirtyRows.insert(integersIn: 0..<geometry.rows)
        revision += 1
    }

    public func snapshot() -> TerminalScreen {
        var lines: [TerminalLine] = []
        lines.reserveCapacity(geometry.rows)
        for row in 0..<geometry.rows {
            var cells: [TerminalCell] = []
            cells.reserveCapacity(geometry.cols)
            for col in 0..<geometry.cols {
                guard let charData = terminal.getCharData(col: col, row: row) else { break }
                let character = charData.getCharacter()
                // Les cellules jamais écrites sont des NUL : pour toute la couche valeur,
                // une cellule vide est un espace (sinon les fins de ligne sont du contrôle).
                cells.append(TerminalCell(character: character == "\0" ? " " : character,
                                          style: Self.cellStyle(from: charData.attribute)))
            }
            lines.append(TerminalLine(cells: cells))
        }
        let cursor = terminal.getCursorLocation()
        return TerminalScreen(geometry: geometry,
                              lines: lines,
                              cursor: CursorPosition(col: cursor.x, row: cursor.y),
                              revision: revision)
    }

    public func takeDirtyRows() -> IndexSet {
        defer { dirtyRows.removeAll() }
        return dirtyRows
    }

    public func setScrollback(_ lines: Int) {
        terminal.changeScrollback(lines)
    }

    private static func cellStyle(from attribute: SwiftTerm.Attribute) -> CellStyle {
        CellStyle(foreground: color(from: attribute.fg),
                  background: color(from: attribute.bg),
                  attributes: textAttributes(from: attribute.style))
    }

    private static func color(from color: SwiftTerm.Attribute.Color) -> TerminalColor {
        switch color {
        case .defaultColor, .defaultInvertedColor: .default
        case .ansi256(let code): .ansi(code)
        case .trueColor(let red, let green, let blue): .rgb(red: red, green: green, blue: blue)
        }
    }

    private static func textAttributes(from style: CharacterStyle) -> TextAttributes {
        var attributes: TextAttributes = []
        if style.contains(.bold) { attributes.insert(.bold) }
        if style.contains(.italic) { attributes.insert(.italic) }
        if style.contains(.underline) { attributes.insert(.underline) }
        if style.contains(.inverse) { attributes.insert(.inverse) }
        if style.contains(.dim) { attributes.insert(.dim) }
        if style.contains(.crossedOut) { attributes.insert(.strikethrough) }
        return attributes
    }
}
