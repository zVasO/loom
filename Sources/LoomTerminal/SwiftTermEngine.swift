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

    /// Everything the terminal answers on its own — DA/DSR, and above all the
    /// mouse reports a full-screen agent asked for. Left unplugged, that agent is
    /// answered by silence, and since it repaints rather than scrolls there is no
    /// scrollback of ours to fall back on: the pane simply cannot be scrolled.
    public var onUpstream: ((ArraySlice<UInt8>) -> Void)? {
        get { headlessDelegate.onSend }
        set { headlessDelegate.onSend = newValue }
    }

    public var mouseReporting: Bool { terminal.mouseMode != .off }

    /// What the program negotiated, read straight off the emulator. SwiftTerm
    /// answers the kitty `CSI ? u` probe itself, so a program that pushes
    /// flags expects `CSI … u` reports from then on — the encoder must know.
    public var modes: TerminalModes {
        TerminalModes(applicationCursorKeys: terminal.applicationCursor,
                      bracketedPaste: terminal.bracketedPasteMode,
                      mouseReporting: terminal.mouseMode != .off,
                      keyboardEnhancement: KeyboardEnhancement(
                          rawValue: terminal.keyboardEnhancementFlags.rawValue))
    }

    /// SwiftTerm remembers the state and emits `CSI I` / `CSI O` only while the
    /// program asked for focus events (DECSET 1004) — nothing to gate here.
    public func setFocus(_ focused: Bool) {
        terminal.setTerminalFocus(focused)
    }

    public func sendWheel(_ direction: WheelDirection, atCol col: Int, row: Int) {
        guard terminal.mouseMode != .off else { return }
        let flags = terminal.encodeButton(button: direction == .up ? 4 : 5,
                                          release: false, shift: false,
                                          meta: false, control: false)
        terminal.sendEvent(buttonFlags: flags, x: col, y: row)
    }

    /// A click is a PAIR on the wire: the program acts on the release, and one
    /// left unsent leaves it holding a button forever.
    public func sendClick(atCol col: Int, row: Int) {
        guard terminal.mouseMode != .off else { return }
        for release in [false, true] {
            let flags = terminal.encodeButton(button: 0, release: release,
                                              shift: false, meta: false,
                                              control: false)
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
    }

    public func resize(to geometry: TerminalGeometry) {
        self.geometry = geometry
        terminal.resize(cols: geometry.cols, rows: geometry.rows)
        dirtyRows.insert(integersIn: 0..<geometry.rows)
        revision += 1
        invalidateTailCache()   // the scrollback reflows: cached lines are stale
    }

    public func snapshot() -> TerminalScreen {
        var lines: [TerminalLine] = []
        lines.reserveCapacity(geometry.rows)
        for row in 0..<geometry.rows {
            var cells: [TerminalCell] = []
            cells.reserveCapacity(geometry.cols)
            for col in 0..<geometry.cols {
                guard let charData = terminal.getCharData(col: col, row: row) else { break }
                cells.append(Self.cell(from: charData))
            }
            lines.append(TerminalLine(cells: cells,
                                      isWrapped: terminal.getLine(row: row)?.isWrapped ?? false))
        }
        let cursor = terminal.getCursorLocation()
        return TerminalScreen(geometry: geometry,
                              lines: lines,
                              cursor: CursorPosition(col: cursor.x, row: cursor.y),
                              revision: revision)
    }

    /// Rows currently above the screen — also the absolute index base that
    /// gives history lines a STABLE identity for the view diff.
    public var scrollbackRows: Int { terminal.getTopVisibleRow() }

    // P0 perf: scrollback lines are immutable once scrolled off — the tail is
    // cached and only the NEW rows are extracted (measured 14.7 ms → ~0 per
    // frame at steady stream). A resize reflows the buffer: cache dropped.
    private var tailCache: [TerminalLine] = []
    private var tailCachedRows = 0

    public func historyTail(_ limit: Int) -> [TerminalLine] {
        let rows = terminal.getTopVisibleRow()   // yDisp = number of lines above
        guard rows > 0 else { return [] }
        if rows < tailCachedRows { invalidateTailCache() }   // defensive: buffer shrank
        if rows > tailCachedRows {
            let cap = 1000   // internal — callers' varying limits must not starve each other
            // Priming against a large existing scrollback only extracts the cap.
            let start = max(tailCachedRows, rows - cap)
            for row in start..<rows {
                tailCache.append(extractScrollbackLine(row))
            }
            if tailCache.count > cap { tailCache.removeFirst(tailCache.count - cap) }
            tailCachedRows = rows
        }
        return tailCache.suffix(limit)
    }

    /// Never-written cells are NULs: throughout the value layer, an empty cell
    /// is a space (otherwise line endings become control characters).
    private static func cell(from charData: CharData) -> TerminalCell {
        let character = charData.getCharacter()
        return TerminalCell(character: character == "\0" ? " " : character,
                            style: cellStyle(from: charData.attribute),
                            link: linkTarget(of: charData))
    }

    /// An OSC 8 payload is `params;URI` — only the URI is the target.
    private static func linkTarget(of charData: CharData) -> String? {
        guard charData.hasPayload, let payload = charData.getPayload() as? String,
              let separator = payload.firstIndex(of: ";")
        else { return nil }
        let target = String(payload[payload.index(after: separator)...])
        return target.isEmpty ? nil : target
    }

    private func extractScrollbackLine(_ row: Int) -> TerminalLine {
        guard let bufferLine = terminal.getScrollInvariantLine(row: row) else {
            return TerminalLine(cells: [])
        }
        let cells = (0..<geometry.cols).map { Self.cell(from: bufferLine[$0]) }
        return TerminalLine(cells: cells, isWrapped: bufferLine.isWrapped)
    }

    private func invalidateTailCache() {
        tailCache = []
        tailCachedRows = 0
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
