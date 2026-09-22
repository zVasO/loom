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
    private var revisionCounter: UInt64 = 0
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
            revisionCounter += 1
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
        revisionCounter += 1
        invalidateTailCache()   // the scrollback reflows: cached lines are stale
    }

    /// The lines of the last snapshot: a row the emulator did not touch since
    /// (SwiftTerm's own update range, kept in `dirtyRows`) is handed back as
    /// is — the O(cols × rows) copy per frame only pays for what changed.
    /// A scroll, a clear, an alternate-screen switch and a resize all mark
    /// every row, as SwiftTerm's own view relies on.
    private var lineCache: [TerminalLine] = []

    public func snapshot() -> TerminalScreen {
        let dirty = takeDirtyRows()
        let reusable = lineCache.count == geometry.rows
        var lines: [TerminalLine] = []
        lines.reserveCapacity(geometry.rows)
        for row in 0..<geometry.rows {
            if reusable, !dirty.contains(row) {
                lines.append(lineCache[row])
                continue
            }
            var cells: [TerminalCell] = []
            cells.reserveCapacity(geometry.cols)
            for col in 0..<geometry.cols {
                guard let charData = terminal.getCharData(col: col, row: row) else { break }
                cells.append(Self.cell(from: charData))
            }
            lines.append(TerminalLine(cells: cells,
                                      isWrapped: terminal.getLine(row: row)?.isWrapped ?? false))
        }
        lineCache = lines
        let cursor = terminal.getCursorLocation()
        return TerminalScreen(geometry: geometry,
                              lines: lines,
                              cursor: CursorPosition(col: cursor.x, row: cursor.y),
                              revision: revisionCounter)
    }

    /// Rows that ever scrolled above the screen — also the absolute index base
    /// that gives history lines a STABLE identity for the view diff.
    ///
    /// ABSOLUTE, not the buffer offset: once the scrollback is full (10,000
    /// lines into a long session) `yDisp` plateaus while the emulator trims a
    /// line off the top for each one pushed. Read as the base, that plateau
    /// handed the SAME identity to a row that had moved up by one every frame —
    /// the view diffed shifting text under fixed ids, and the tail below
    /// stopped seeing "new" rows altogether: a frozen history under a live
    /// screen, blocks apparently duplicated. `totalLinesTrimmed` is the count
    /// the emulator keeps for exactly this, and `getScrollInvariantLine`
    /// already indexes in these absolute terms.
    public var scrollbackRows: Int {
        terminal.getTopVisibleRow() + terminal.buffer.totalLinesTrimmed
    }

    // P0 perf: scrollback lines are immutable once scrolled off — the tail is
    // cached and only the NEW rows are extracted (measured 14.7 ms → ~0 per
    // frame at steady stream). A resize reflows the buffer: cache dropped.
    private var tailCache: [TerminalLine] = []
    private var tailCachedRows = 0

    /// The largest tail ever asked for: the cache is primed with THAT, not
    /// with the cap — a resize or a first attach on a long session extracted
    /// 1000 lines to answer for 400. The cap only bounds its growth.
    private var primedLimit = 0

    public func historyTail(_ limit: Int) -> [TerminalLine] {
        let rows = scrollbackRows   // absolute: keeps growing past the cap
        guard rows > 0 else { return [] }
        if rows < tailCachedRows { invalidateTailCache() }   // defensive: buffer shrank
        let cap = 1000   // internal — callers' varying limits must not starve each other
        // A caller asking for more than the cache was primed with, while
        // older rows exist: start over with the larger window.
        if limit > primedLimit, tailCache.count < min(limit, rows), tailCachedRows > 0 {
            invalidateTailCache()
        }
        primedLimit = max(primedLimit, limit)
        if rows > tailCachedRows {
            let start = max(tailCachedRows, rows - min(primedLimit, cap))
            for row in start..<rows {
                tailCache.append(extractScrollbackLine(row))
            }
            if tailCache.count > cap { tailCache.removeFirst(tailCache.count - cap) }
            tailCachedRows = rows
        }
        // The tail mirrors what the emulator still holds: past the scrollback
        // cap it trims a line per line pushed, and so must the cache (a no-op
        // in production, where the 10,000-line scrollback dwarfs the cap).
        let retained = rows - terminal.buffer.totalLinesTrimmed
        if tailCache.count > retained { tailCache.removeFirst(tailCache.count - retained) }
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

    /// `row` is absolute (lines ever scrolled off), the emulator's own
    /// scroll-invariant numbering — it subtracts what it trimmed itself.
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

    /// Consumed by `snapshot()`: a caller taking them itself would hand the
    /// next snapshot stale rows.
    public func takeDirtyRows() -> IndexSet {
        defer { dirtyRows.removeAll() }
        return dirtyRows
    }

    public var revision: UInt64 { revisionCounter }
    public var cursor: CursorPosition {
        let location = terminal.getCursorLocation()
        return CursorPosition(col: location.x, row: location.y)
    }

    /// Bottom-up, stopping as soon as `limit` lines are in hand: one string
    /// per row read, no cell copies, no snapshot.
    public func visibleTail(_ limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var tail: [String] = []
        var row = geometry.rows - 1
        while row >= 0, tail.count < limit {
            defer { row -= 1 }
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
                .replacingOccurrences(of: "\0", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { tail.append(text) }
        }
        return tail.reversed()
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
