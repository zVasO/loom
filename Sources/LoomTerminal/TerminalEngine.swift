import LoomCore
import Dispatch
import Foundation

// Terminal engine seam (ADR-0001, decision in docs/design/session-runtime.md).
// Two adapters: SwiftTermEngine (prod) and LineEngine (test); libghostty as a third (v2).
//
// CONFINEMENT CONTRACT (ADR-0007): every method and property is called on the
// session's serial queue, no exceptions. The protocol is deliberately non-Sendable:
// the type states the confinement.

// The factory seam is the `SessionRuntime.Dependencies.makeEngine` closure — a single
// mechanism (ADR-0008). The return channel to the PTY (DA/DSR responses) and the title
// will arrive with the SwiftTerm adapter, dictated by its actual needs, not before.
public protocol TerminalEngine: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(to geometry: TerminalGeometry)
    /// Visible screen only — never the scrollback. Increments `revision`.
    func snapshot() -> TerminalScreen
    /// Rows modified since the last call, resetting the marker.
    func takeDirtyRows() -> IndexSet
    /// Shrinks a detached terminal's footprint (NFR-M) without touching the transcript.
    func setScrollback(_ lines: Int)
    /// The last `limit` lines that have SCROLLED OFF the screen (scrollback tail),
    /// oldest to newest — for view scrolling.
    func historyTail(_ limit: Int) -> [TerminalLine]
    /// Rows above the screen — absolute base giving history lines a stable identity.
    var scrollbackRows: Int { get }
}

public extension TerminalEngine {
    /// Adapters without a scrollback (test line engines) sit at base zero.
    var scrollbackRows: Int { 0 }

}

// MARK: - Screen

/// Immutable value crossing the session queue → MainActor boundary.
public struct TerminalScreen: Sendable, Equatable {
    public let geometry: TerminalGeometry
    public let lines: [TerminalLine]
    public let cursor: CursorPosition
    /// Monotonic per terminal; equal ⇒ nothing to redraw.
    public let revision: UInt64

    public init(geometry: TerminalGeometry, lines: [TerminalLine], cursor: CursorPosition,
                revision: UInt64) {
        self.geometry = geometry
        self.lines = lines
        self.cursor = cursor
        self.revision = revision
    }

    /// `TerminalSurface.screen` is never optional nor empty: before the first
    /// attachment, the view paints this blank screen at the right geometry.
    public static func blank(_ geometry: TerminalGeometry) -> TerminalScreen {
        TerminalScreen(geometry: geometry,
                       lines: Array(repeating: TerminalLine(cells: []), count: geometry.rows),
                       cursor: CursorPosition(col: 0, row: 0),
                       revision: 0)
    }
}

public struct TerminalLine: Sendable, Equatable {
    public let cells: [TerminalCell]
    public init(cells: [TerminalCell]) { self.cells = cells }
    public var text: String { String(cells.map(\.character)) }
}

public struct TerminalCell: Sendable, Equatable {
    public let character: Character
    public let style: CellStyle
    public init(character: Character, style: CellStyle = .init()) {
        self.character = character
        self.style = style
    }
}

public struct CellStyle: Sendable, Equatable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: TextAttributes
    public init(foreground: TerminalColor = .default, background: TerminalColor = .default,
                attributes: TextAttributes = []) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

/// Colors stay symbolic until rendering: the resolved theme (THM-04) translates
/// `ansi(n)` into a concrete color, never the engine.
public enum TerminalColor: Sendable, Equatable {
    case `default`
    case ansi(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

public struct TextAttributes: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = TextAttributes(rawValue: 1 << 0)
    public static let italic = TextAttributes(rawValue: 1 << 1)
    public static let underline = TextAttributes(rawValue: 1 << 2)
    public static let inverse = TextAttributes(rawValue: 1 << 3)
    public static let strikethrough = TextAttributes(rawValue: 1 << 4)
    public static let dim = TextAttributes(rawValue: 1 << 5)
}

public struct CursorPosition: Sendable, Equatable {
    public var col: Int
    public var row: Int
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}
