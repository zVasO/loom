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

    /// The terminal's own voice back to the program: DA/DSR replies, mouse reports.
    /// Set once by the runtime, invoked on the session queue like everything else.
    var onUpstream: ((ArraySlice<UInt8>) -> Void)? { get set }

    /// The input modes the program switched on — what the key encoder and the
    /// paste path must honour. A value: it crosses to the MainActor as-is.
    var modes: TerminalModes { get }

    /// True while the program tracks the mouse (DECSET 1000-1003). It then owns the
    /// wheel: a full-screen program repaints rather than scrolls, so it holds the
    /// only viewport there is to move.
    var mouseReporting: Bool { get }

    /// One wheel notch at a cell position (0-based) — the unit a tracking program
    /// counts. Silent when nothing is tracking.
    func sendWheel(_ direction: WheelDirection, atCol col: Int, row: Int)

    /// One left click at a cell position (0-based): press AND release, the pair a
    /// tracking program waits for. Silent when nothing is tracking.
    func sendClick(atCol col: Int, row: Int)

    /// The host view gained or lost keyboard focus. A program that asked for
    /// focus events (DECSET 1004) is told `CSI I` / `CSI O`; silent otherwise.
    func setFocus(_ focused: Bool)
}

public extension TerminalEngine {
    /// Adapters without a scrollback (test line engines) sit at base zero.
    var scrollbackRows: Int { 0 }

    /// Adapters that parse no mode switching sit in the legacy defaults.
    var modes: TerminalModes { .none }
    /// Kept as a shim: the mouse is one of the modes.
    var mouseReporting: Bool { modes.mouseReporting }
    func sendWheel(_ direction: WheelDirection, atCol col: Int, row: Int) {}
    func sendClick(atCol col: Int, row: Int) {}
    func setFocus(_ focused: Bool) {}
}

// MARK: - Input modes

/// The DEC private modes and keyboard protocol a program negotiates, read by
/// the key encoder. Snapshot at frame cadence, like the screen (ADR-0008).
public struct TerminalModes: Sendable, Equatable {
    /// DECSET ?1 (DECCKM): arrows and Home/End go out as SS3, not CSI.
    public var applicationCursorKeys: Bool
    /// DECSET ?2004: a paste is wrapped in `CSI 200~` … `CSI 201~`.
    public var bracketedPaste: Bool
    /// DECSET ?1000–?1003: the program tracks the mouse.
    public var mouseReporting: Bool
    /// The kitty keyboard protocol flags the program pushed (`CSI > flags u`).
    /// Empty = legacy xterm encoding.
    public var keyboardEnhancement: KeyboardEnhancement

    public init(applicationCursorKeys: Bool = false, bracketedPaste: Bool = false,
                mouseReporting: Bool = false, keyboardEnhancement: KeyboardEnhancement = []) {
        self.applicationCursorKeys = applicationCursorKeys
        self.bracketedPaste = bracketedPaste
        self.mouseReporting = mouseReporting
        self.keyboardEnhancement = keyboardEnhancement
    }

    public static let none = TerminalModes()
}

/// Progressive-enhancement flags of the kitty keyboard protocol. Raw values are
/// the protocol's own bits, so the emulator's flags copy over untouched.
public struct KeyboardEnhancement: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Esc, and every modified key, become unambiguous `CSI … u` reports.
    public static let disambiguate = KeyboardEnhancement(rawValue: 1 << 0)
    /// Key releases and repeats are reported, not only presses.
    public static let reportEvents = KeyboardEnhancement(rawValue: 1 << 1)
    /// Shifted key codes ride along (`CSI 97:65;2 u`).
    public static let reportAlternates = KeyboardEnhancement(rawValue: 1 << 2)
    /// Plain text keys are reported as escape codes too.
    public static let reportAllKeys = KeyboardEnhancement(rawValue: 1 << 3)
    /// The text a key produces is appended to its report.
    public static let reportText = KeyboardEnhancement(rawValue: 1 << 4)
}

/// A wheel notch, as a tracking program sees it (buttons 4 and 5).
public enum WheelDirection: Sendable {
    case up
    case down
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
    /// This row is the soft-wrapped continuation of the one above: a URL, or
    /// any other run, straddles the boundary instead of ending at it.
    public let isWrapped: Bool
    public init(cells: [TerminalCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }
    public var text: String { String(cells.map(\.character)) }
}

public struct TerminalCell: Sendable, Equatable {
    public let character: Character
    public let style: CellStyle
    /// OSC 8 target. Carried per cell because the view only ever sees values,
    /// never the emulator (ADR-0007/0008) — it cannot ask it afterwards.
    public let link: String?
    public init(character: Character, style: CellStyle = .init(), link: String? = nil) {
        self.character = character
        self.style = style
        self.link = link
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
