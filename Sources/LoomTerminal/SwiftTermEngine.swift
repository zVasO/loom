import LoomCore
import Foundation
import SwiftTerm

/// Production adapter for the `TerminalEngine` seam (ADR-0001).
///
/// STRICT confinement (ADR-0007): every method runs on the session's serial
/// queue — the SwiftTerm engine contains no synchronization primitives, despite
/// what its docs claim (docs/research/swiftterm-pty.md §2).
/// The snapshot loops over `getLine(row:)` bounded to the visible lines — never
/// `getBufferAsData()`, which includes the scrollback (research §1.4).
public final class SwiftTermEngine: TerminalEngine {

    private final class HeadlessDelegate: TerminalDelegate {
        // Terminal responses back to the PTY (DA/DSR…). Wired up by SessionRuntime
        // when the "upstream echo" slice lands; until then, collected nowhere.
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
                // Never-written cells are NULs: throughout the value layer, an empty
                // cell is a space (otherwise line endings become control characters).
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

    public func historyTail(_ limit: Int) -> [TerminalLine] {
        let scrollbackRows = terminal.getTopVisibleRow()   // yDisp = number of lines above
        guard scrollbackRows > 0 else { return [] }
        let start = max(0, scrollbackRows - limit)
        return (start..<scrollbackRows).map { row in
            guard let bufferLine = terminal.getScrollInvariantLine(row: row) else {
                return TerminalLine(cells: [])
            }
            let cells = (0..<geometry.cols).map { col -> TerminalCell in
                let charData = bufferLine[col]
                let character = charData.getCharacter()
                return TerminalCell(character: character == "\0" ? " " : character,
                                    style: Self.cellStyle(from: charData.attribute))
            }
            return TerminalLine(cells: cells)
        }
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
