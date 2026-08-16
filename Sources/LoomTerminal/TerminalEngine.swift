import LoomCore
import Dispatch
import Foundation

// Seam du moteur terminal (ADR-0001, décision docs/design/session-runtime.md).
// Deux adapters : SwiftTermEngine (prod) et LineEngine (test) ; libghostty en troisième (v2).
//
// CONTRAT DE CONFINEMENT (ADR-0007) : toutes les méthodes et propriétés sont appelées
// sur la queue sérielle de la session, sans exception. Le protocole est volontairement
// non-Sendable : le type dit le confinement.

// Le seam de fabrique est la closure `SessionRuntime.Dependencies.makeEngine` — un seul
// mécanisme (ADR-0008). Le canal de retour vers le PTY (réponses DA/DSR) et le titre
// arriveront avec l'adapter SwiftTerm, dictés par ses besoins réels, pas avant.
public protocol TerminalEngine: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(to geometry: TerminalGeometry)
    /// Écran visible uniquement — jamais le scrollback. Incrémente `revision`.
    func snapshot() -> TerminalScreen
    /// Lignes modifiées depuis le dernier appel, et remise à zéro du marqueur.
    func takeDirtyRows() -> IndexSet
    /// Réduit l'empreinte d'un terminal détaché (NFR-M) sans toucher au transcript.
    func setScrollback(_ lines: Int)
    /// Les `limit` dernières lignes SORTIES de l'écran (queue du scrollback),
    /// de la plus ancienne à la plus récente — pour le défilement de la vue.
    func historyTail(_ limit: Int) -> [TerminalLine]
}

// MARK: - Écran

/// Valeur immuable traversant la frontière queue de session → MainActor.
public struct TerminalScreen: Sendable, Equatable {
    public let geometry: TerminalGeometry
    public let lines: [TerminalLine]
    public let cursor: CursorPosition
    /// Monotone par terminal ; égal ⇒ rien à redessiner.
    public let revision: UInt64

    public init(geometry: TerminalGeometry, lines: [TerminalLine], cursor: CursorPosition,
                revision: UInt64) {
        self.geometry = geometry
        self.lines = lines
        self.cursor = cursor
        self.revision = revision
    }

    /// `TerminalSurface.screen` n'est jamais optionnel ni vide : avant le premier
    /// attachement, la vue peint cet écran vierge à la bonne géométrie.
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

/// Les couleurs restent symboliques jusqu'au rendu : c'est le thème résolu (THM-04)
/// qui traduit `ansi(n)` en couleur concrète, jamais le moteur.
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
