import AppKit
import LoomTerminal
import SwiftUI

/// SES-05bis: typing happens IN the agent's field, not in a bar of our
/// own — every keystroke is translated into terminal bytes and sent to the PTY.
/// Pure translation, separate from the view: it is what carries the tests.
///
/// Two dialects, chosen by what the program negotiated (`TerminalModes`):
/// - legacy xterm: `CSI 1;m X` modifier parameters, `SS3` under DECCKM,
///   `CSI Z` for ⇧Tab, `ESC CR` for a newline inside a prompt;
/// - the kitty keyboard protocol once the program pushed flags — the emulator
///   answers its `CSI ? u` probe, so from then on it expects `CSI … u` reports
///   and the legacy bytes would be misread (⇧Tab as a Tab, Esc as a prefix).
public enum KeyTranslator {

    // MARK: Modifier parameters

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). `nil` when
    /// no modifier is held — the parameter is then omitted altogether.
    public static func modifierParameter(shift: Bool, option: Bool, control: Bool) -> Int? {
        let bits = (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        return bits == 0 ? nil : bits + 1
    }

    // MARK: Encoding

    /// Bytes for one key press, or `nil` for ordinary text: the view then lets
    /// AppKit compose it (dead keys, IME), which is what preserves accents.
    public static func encode(_ key: KeyStroke, modes: TerminalModes,
                              preferences: KeyboardPreferences = KeyboardPreferences(),
                              event: KeyEventKind = .press) -> String? {
        let flags = modes.keyboardEnhancement
        if !flags.isEmpty {
            return Kitty.encode(key, flags: flags, modes: modes, preferences: preferences, event: event)
        }
        guard event != .release else { return nil }   // legacy has no releases
        return Legacy.encode(key, modes: modes, preferences: preferences)
    }

    /// A pasted path may land in a shell as much as in an agent's field: only
    /// a POSIX-safe one travels bare. Single quotes protect everything but a
    /// single quote, which has to leave the quoting to be escaped.
    public static func quoted(path: String) -> String {
        let safe = !path.isEmpty
            && path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+=@:,".contains($0) }
        guard !safe else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A paste, ready for the wire: line endings become CR (what Enter sends,
    /// and what every emulator does), a smuggled end marker is dropped so the
    /// pasted text can never close its own bracket, and the whole is wrapped
    /// only when the program asked for bracketed paste (DECSET 2004).
    public static func paste(_ text: String, bracketed: Bool) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\u{1b}[201~", with: "")
        guard bracketed else { return normalized }
        return "\u{1b}[200~" + normalized + "\u{1b}[201~"
    }

    /// Mac editing shortcuts (⌘) → the sequences claude's input understands.
    /// Letters match on the TYPED character (AZERTY-safe), arrows/backspace on
    /// the key code. nil = not an edit shortcut: the app keeps it (⌘K, ⌘N…).
    public static func command(characters: String, keyCode: UInt16) -> String? {
        switch keyCode {
        case 123: return "\u{01}"        // ⌘← — line start (Ctrl+A)
        case 124: return "\u{05}"        // ⌘→ — line end (Ctrl+E)
        case 51: return "\u{15}"         // ⌘⌫ — kill to line start (Ctrl+U)
        default: break
        }
        switch characters {
        // ⌘A — select the whole input: home, then shift-End extends the
        // selection to the end (degrades to end-of-line on old claude builds).
        case "a": return "\u{01}\u{1b}[1;2F"
        case "z": return "\u{1f}"        // ⌘Z — readline undo
        default: return nil
        }
    }

    // MARK: - Key classification

    /// The keys with a meaning of their own, identified by hardware key code —
    /// independent of the layout, which is why AZERTY needs no special case.
    enum FunctionalKey: Equatable {
        case enter, tab, backspace, escape
        case up, down, left, right, home, end, pageUp, pageDown, delete, insert
        case function(Int)   // F1…F20

        init?(keyCode: UInt16) {
            switch keyCode {
            case 36, 76: self = .enter          // Return, keypad Enter
            case 48: self = .tab
            case 51: self = .backspace
            case 53: self = .escape
            case 126: self = .up
            case 125: self = .down
            case 123: self = .left
            case 124: self = .right
            case 115: self = .home
            case 119: self = .end
            case 116: self = .pageUp
            case 121: self = .pageDown
            case 117: self = .delete          // forward delete
            case 114: self = .insert          // "Help" on Apple keyboards
            case 122: self = .function(1)
            case 120: self = .function(2)
            case 99: self = .function(3)
            case 118: self = .function(4)
            case 96: self = .function(5)
            case 97: self = .function(6)
            case 98: self = .function(7)
            case 100: self = .function(8)
            case 101: self = .function(9)
            case 109: self = .function(10)
            case 103: self = .function(11)
            case 111: self = .function(12)
            case 105: self = .function(13)
            case 107: self = .function(14)
            case 113: self = .function(15)
            case 106: self = .function(16)
            case 64: self = .function(17)
            case 79: self = .function(18)
            case 80: self = .function(19)
            case 90: self = .function(20)
            default: return nil
            }
        }
    }

    /// The layout-independent key a text keystroke stands for: the lowercase
    /// base character, the way both dialects want it (⌃C is `c`, ⇧A is `a`).
    static func baseScalar(of key: KeyStroke) -> UnicodeScalar? {
        guard let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
              !isPrivateUse(scalar), scalar.value >= 0x20
        else { return nil }
        return String(scalar).lowercased().unicodeScalars.first ?? scalar
    }

    /// AppKit spells arrows and function keys as private-use characters.
    static func isPrivateUse(_ scalar: UnicodeScalar) -> Bool {
        (0xF700...0xF8FF).contains(scalar.value)
    }

    /// What a text key produces, when it produced anything printable.
    static func printableText(of key: KeyStroke) -> String? {
        guard !key.characters.isEmpty else { return nil }
        for scalar in key.characters.unicodeScalars
        where scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) || isPrivateUse(scalar) {
            return nil
        }
        return key.characters
    }

    // MARK: - Legacy xterm

    enum Legacy {
        static func encode(_ key: KeyStroke, modes: TerminalModes,
                           preferences: KeyboardPreferences) -> String? {
            if let functional = FunctionalKey(keyCode: key.keyCode) {
                return encodeFunctional(functional, key: key, modes: modes)
            }
            if key.control {
                return encodeControl(key, preferences: preferences)
            }
            if key.option, preferences.optionAsMeta {
                // Meta: ESC then the key as the layout spells it (⌥⇧A → ESC A).
                guard !key.charactersIgnoringModifiers.isEmpty else { return nil }
                return "\u{1b}" + key.charactersIgnoringModifiers
            }
            // Plain text, ⌥ as a compose layer (AZERTY braces, dead keys): AppKit.
            return nil
        }

        private static func encodeFunctional(_ functional: FunctionalKey, key: KeyStroke,
                                             modes: TerminalModes) -> String {
            let modifier = KeyTranslator.modifierParameter(shift: key.shift, option: key.option,
                                                           control: key.control)
            switch functional {
            case .enter:
                // ⇧↩ and ⌥↩: a newline inside the prompt. Legacy xterm has no
                // ⇧↩ of its own, and `ESC CR` (meta+return) is what the agent's
                // input reads as "insert a line" — no /terminal-setup needed.
                return (key.shift || key.option) ? "\u{1b}\r" : "\r"
            case .tab:
                return key.shift ? "\u{1b}[Z" : "\t"
            case .backspace:
                if key.option { return "\u{17}" }      // ⌥⌫ deletes a word (Ctrl+W)
                if key.control { return "\u{08}" }
                return "\u{7f}"
            case .escape:
                return "\u{1b}"
            case .up, .down, .left, .right, .home, .end:
                // ⌥← / ⌥→ alone jump a word, the way every Mac terminal does.
                if key.option, !key.shift, !key.control {
                    if functional == .left { return "\u{1b}b" }
                    if functional == .right { return "\u{1b}f" }
                }
                let letter = cursorLetter(functional)
                if let modifier { return "\u{1b}[1;\(modifier)\(letter)" }
                return modes.applicationCursorKeys ? "\u{1b}O\(letter)" : "\u{1b}[\(letter)"
            case .pageUp, .pageDown, .delete, .insert:
                let number: Int = switch functional {
                case .pageUp: 5
                case .pageDown: 6
                case .delete: 3
                default: 2
                }
                return tilde(number, modifier: modifier)
            case .function(let n):
                if (1...4).contains(n) {
                    let letter = ["P", "Q", "R", "S"][n - 1]
                    if let modifier { return "\u{1b}[1;\(modifier)\(letter)" }
                    return "\u{1b}O\(letter)"
                }
                let numbers = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24,
                               13: 25, 14: 26, 15: 28, 16: 29, 17: 31, 18: 32, 19: 33, 20: 34]
                return tilde(numbers[n] ?? 24, modifier: modifier)
            }
        }

        private static func tilde(_ number: Int, modifier: Int?) -> String {
            if let modifier { return "\u{1b}[\(number);\(modifier)~" }
            return "\u{1b}[\(number)~"
        }

        static func cursorLetter(_ key: FunctionalKey) -> String {
            switch key {
            case .up: "A"
            case .down: "B"
            case .right: "C"
            case .left: "D"
            case .home: "H"
            default: "F"
            }
        }

        /// ⌃ + a key: the C0 control character xterm sends, from the layout's
        /// base character — ⌃C is ETX on AZERTY too. Space and the punctuation
        /// row are the cases `NSEvent.characters` does not fold reliably.
        private static func encodeControl(_ key: KeyStroke,
                                          preferences: KeyboardPreferences) -> String? {
            let meta = (key.option && preferences.optionAsMeta) ? "\u{1b}" : ""
            if key.keyCode == 49 { return meta + "\u{0}" }     // ⌃Space → NUL
            if let base = KeyTranslator.baseScalar(of: key),
               let control = controlCharacter(for: base) {
                return meta + String(UnicodeScalar(control))
            }
            // A layout without an ASCII base (Cyrillic…): AppKit may still
            // have folded the control character for us.
            if let scalar = key.characters.unicodeScalars.first,
               key.characters.unicodeScalars.count == 1, scalar.value < 0x20 {
                return meta + key.characters
            }
            return nil
        }

        /// xterm's table, `_`/`/`/`7` folding to 0x1F included (readline undo).
        static func controlCharacter(for scalar: UnicodeScalar) -> UInt8? {
            switch scalar {
            case "a"..."z": return UInt8(scalar.value - 0x60)
            case " ", "@", "2": return 0x00
            case "[", "3": return 0x1b
            case "\\", "4": return 0x1c
            case "]", "5": return 0x1d
            case "^", "6", "~": return 0x1e
            case "_", "/", "7", "-": return 0x1f
            case "?", "8": return 0x7f
            default: return nil
            }
        }
    }

    // MARK: - kitty keyboard protocol

    /// Mirrors the reference encoder the emulator ships for its own views
    /// (SwiftTerm `KittyKeyboardEncoder`), restricted to what a Mac keyboard
    /// can produce. Codepoints for keys without a Unicode value come from the
    /// protocol's private-use table.
    enum Kitty {
        static func encode(_ key: KeyStroke, flags: KeyboardEnhancement, modes: TerminalModes,
                           preferences: KeyboardPreferences, event: KeyEventKind) -> String? {
            let allKeys = flags.contains(.reportAllKeys)
            let disambiguate = flags.contains(.disambiguate) || allKeys
            let reportEvents = flags.contains(.reportEvents)
            let alternates = flags.contains(.reportAlternates)
            let reportText = allKeys && flags.contains(.reportText)
            if event == .release, !reportEvents { return nil }
            let eventField = eventSuffix(event, reportEvents: reportEvents)

            if let functional = FunctionalKey(keyCode: key.keyCode) {
                if event == .release, !allKeys,
                   [.enter, .tab, .backspace].contains(functional) { return nil }
                // ⌥ on a special key is alt whatever the Meta preference — as in
                // the legacy dialect: ⌥↩ inserts a newline, ⌥⌫ deletes a word,
                // ⌥← jumps a word, on every layout.
                return encodeFunctional(functional, modifiers: modifierBits(key, optionAsMeta: true),
                                        eventField: eventField, disambiguate: disambiguate,
                                        allKeys: allKeys, modes: modes)
            }

            // Text keys. ⌥ without Meta is a compose layer (AZERTY braces, dead
            // keys): the glyph it makes is the key, and AppKit composes it.
            let modifiers = modifierBits(key, optionAsMeta: preferences.optionAsMeta)
            let modified = key.control || (key.option && preferences.optionAsMeta)
            guard let base = KeyTranslator.baseScalar(of: key) else { return nil }
            let shifted = shiftedScalar(of: key, base: base)
            if allKeys {
                // Every key is a report, text riding along when asked. A dead
                // key in progress has no base and returned above: AppKit still
                // composes it, and the composed text goes out raw.
                let attached = (reportText && event != .release && !modified)
                    ? KeyTranslator.printableText(of: key) : nil
                return csiU(Int(base.value), shifted: alternates && key.shift ? shifted : nil,
                            modifiers: modifiers, eventField: eventField, text: attached)
            }
            // Unmodified text is plain text in every dialect: composition keeps it.
            guard modified else { return nil }
            if !disambiguate {
                // Flags without disambiguation (events only): legacy bytes.
                return event == .release ? nil
                    : Legacy.encode(key, modes: modes, preferences: preferences)
            }
            return csiU(Int(base.value), shifted: alternates && key.shift ? shifted : nil,
                        modifiers: modifiers, eventField: eventField, text: nil)
        }

        private static func encodeFunctional(_ functional: FunctionalKey, modifiers: Int,
                                             eventField: String, disambiguate: Bool,
                                             allKeys: Bool, modes: TerminalModes) -> String? {
            let wantsModifiers = modifiers != 0 || !eventField.isEmpty
            switch functional {
            case .escape:
                if disambiguate {
                    return csiU(27, shifted: nil, modifiers: modifiers, eventField: eventField, text: nil)
                }
                return eventField.isEmpty ? "\u{1b}" : nil
            case .enter, .tab, .backspace:
                let codepoint = functional == .enter ? 13 : (functional == .tab ? 9 : 127)
                if allKeys || (disambiguate && wantsModifiers) {
                    return csiU(codepoint, shifted: nil, modifiers: modifiers,
                                eventField: eventField, text: nil)
                }
                guard eventField.isEmpty else { return nil }
                let shift = modifiers & 1 != 0, alt = modifiers & 2 != 0, ctrl = modifiers & 4 != 0
                let bytes: String = switch functional {
                case .enter: "\r"
                case .tab: shift ? "\u{1b}[Z" : "\t"
                default: ctrl ? "\u{08}" : "\u{7f}"
                }
                return alt ? "\u{1b}" + bytes : bytes
            case .up, .down, .left, .right, .home, .end:
                let letter = Legacy.cursorLetter(functional)
                if !disambiguate, !wantsModifiers {
                    return modes.applicationCursorKeys ? "\u{1b}O\(letter)" : "\u{1b}[\(letter)"
                }
                return csiLetter(letter, modifiers: modifiers, eventField: eventField)
            case .pageUp, .pageDown, .delete, .insert:
                let number: Int = switch functional {
                case .pageUp: 5
                case .pageDown: 6
                case .delete: 3
                default: 2
                }
                return csiTilde(number, modifiers: modifiers, eventField: eventField)
            case .function(let n):
                switch n {
                case 1, 2, 4:
                    let letter = n == 1 ? "P" : (n == 2 ? "Q" : "S")
                    if !disambiguate, !wantsModifiers { return "\u{1b}O\(letter)" }
                    return csiLetter(letter, modifiers: modifiers, eventField: eventField)
                case 3:
                    return csiTilde(13, modifiers: modifiers, eventField: eventField)
                case 5...12:
                    let numbers = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
                    return csiTilde(numbers[n] ?? 24, modifiers: modifiers, eventField: eventField)
                default:
                    // F13+ have no legacy form in the protocol: private-use codepoints.
                    return csiU(57376 + (n - 13), shifted: nil, modifiers: modifiers,
                                eventField: eventField, text: nil)
                }
            }
        }

        /// shift 1, alt 2, ctrl 4 — ⌘ never reaches the terminal, caps lock is
        /// not tracked by the key stroke.
        static func modifierBits(_ key: KeyStroke, optionAsMeta: Bool) -> Int {
            (key.shift ? 1 : 0) + ((key.option && optionAsMeta) ? 2 : 0) + (key.control ? 4 : 0)
        }

        private static func eventSuffix(_ event: KeyEventKind, reportEvents: Bool) -> String {
            guard reportEvents, event != .press else { return "" }
            return event == .repeat ? ":2" : ":3"
        }

        /// The character ⇧ produced, when it differs from the base (`a` → `A`).
        private static func shiftedScalar(of key: KeyStroke, base: UnicodeScalar) -> UnicodeScalar? {
            guard key.shift, let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
                  scalar != base, !KeyTranslator.isPrivateUse(scalar)
            else { return nil }
            return scalar
        }

        static func csiU(_ codepoint: Int, shifted: UnicodeScalar?, modifiers: Int,
                         eventField: String, text: String?) -> String {
            var body = "\(codepoint)"
            if let shifted { body += ":\(shifted.value)" }
            let modifiersField = modifiers != 0 || !eventField.isEmpty
            if modifiersField { body += ";\(modifiers + 1)\(eventField)" }
            if let text {
                let codepoints = text.unicodeScalars
                    .filter { $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) }
                    .map { String($0.value) }
                if !codepoints.isEmpty {
                    body += (modifiersField ? ";" : ";;") + codepoints.joined(separator: ":")
                }
            }
            return "\u{1b}[\(body)u"
        }

        private static func csiLetter(_ letter: String, modifiers: Int, eventField: String) -> String {
            guard modifiers != 0 || !eventField.isEmpty else { return "\u{1b}[\(letter)" }
            return "\u{1b}[1;\(modifiers + 1)\(eventField)\(letter)"
        }

        private static func csiTilde(_ number: Int, modifiers: Int, eventField: String) -> String {
            guard modifiers != 0 || !eventField.isEmpty else { return "\u{1b}[\(number)~" }
            return "\u{1b}[\(number);\(modifiers + 1)\(eventField)~"
        }
    }
}

/// One keystroke, stripped of AppKit: what the encoder needs and nothing it
/// cannot get in a test.
public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt16
    /// What the layout produced, modifiers applied (`NSEvent.characters`).
    public var characters: String
    /// The key without ⌥/⌃ (`charactersIgnoringModifiers`): `a` for ⌃A, `A` for ⇧A.
    public var charactersIgnoringModifiers: String
    public var shift: Bool
    public var control: Bool
    public var option: Bool

    public init(keyCode: UInt16, characters: String = "", charactersIgnoringModifiers: String? = nil,
                shift: Bool = false, control: Bool = false, option: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.shift = shift
        self.control = control
        self.option = option
    }

    public init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode,
                  characters: event.characters ?? "",
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                  shift: event.modifierFlags.contains(.shift),
                  control: event.modifierFlags.contains(.control),
                  option: event.modifierFlags.contains(.option))
    }
}

public enum KeyEventKind: Equatable, Sendable {
    case press
    case `repeat`
    case release
}

/// What the user chose about the keyboard, not what the program negotiated.
public struct KeyboardPreferences: Equatable, Sendable {
    /// Terminal.app's "Use Option as Meta key". Off by default: on AZERTY the
    /// braces and brackets live under ⌥, and US dead keys (⌥E + E = é) too —
    /// a blanket ESC prefix would take them away.
    public var optionAsMeta: Bool
    public init(optionAsMeta: Bool = false) { self.optionAsMeta = optionAsMeta }

    public static let userDefaultsKey = "loom.terminal.optionAsMeta"
}

/// Invisible zone under the terminal: as first responder it pushes every keystroke
/// to the PTY — typing lives in the agent's field. Ordinary keys
/// go through `interpretKeyEvents` to compose dead keys (ê, î…),
/// ⌘ shortcuts stay with the system, ⌘V pastes into the agent's field.
public struct KeyCaptureView: NSViewRepresentable {
    /// What the program negotiated: the mouse, bracketed paste, cursor keys,
    /// keyboard protocol. Read at frame cadence off the surface.
    let modes: TerminalModes
    let preferences: KeyboardPreferences
    let onWheel: ((WheelDirection, Int, Int) -> Void)?
    /// A click the agent asked for, at the cell under the pointer (0-based).
    let onClick: ((Int, Int) -> Void)?
    /// The selected text, or nil when there is no selection.
    let onCopy: (() -> String?)?
    /// How many characters actually reached the pasteboard.
    let onCopied: ((Int) -> Void)?
    /// The pane gained (true) or lost keyboard focus — for DECSET 1004.
    let onFocus: ((Bool) -> Void)?
    let onText: (String) -> Void

    /// `onText` comes last so the trailing-closure form still means "the keystrokes".
    public init(modes: TerminalModes = .none,
                preferences: KeyboardPreferences = KeyboardPreferences(),
                onWheel: ((WheelDirection, Int, Int) -> Void)? = nil,
                onClick: ((Int, Int) -> Void)? = nil,
                onCopy: (() -> String?)? = nil,
                onCopied: ((Int) -> Void)? = nil,
                onFocus: ((Bool) -> Void)? = nil,
                onText: @escaping (String) -> Void) {
        self.modes = modes
        self.preferences = preferences
        self.onWheel = onWheel
        self.onClick = onClick
        self.onCopy = onCopy
        self.onCopied = onCopied
        self.onFocus = onFocus
        self.onText = onText
    }

    public func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        configure(view)
        return view
    }

    public func updateNSView(_ view: CaptureNSView, context: Context) {
        configure(view)
        // Reclaiming focus when nothing is focused anymore — never by stealing it
        // from an active text field (renaming, palette…). A click inside the pane
        // is handled by the mouse monitor instead, which leaves the press itself
        // alone so a selection drag can start on it.
        guard view.focusIsIdle() else { return }
        DispatchQueue.main.async { [weak view] in view?.reclaimFocusIfIdle(acceptingUnset: true) }
    }

    private func configure(_ view: CaptureNSView) {
        view.onText = onText
        view.onWheel = onWheel
        view.onClick = onClick
        view.onCopy = onCopy
        view.onCopied = onCopied
        view.onFocus = onFocus
        view.modes = modes
        view.preferences = preferences
    }

    public final class CaptureNSView: NSView {
        var onText: ((String) -> Void)?
        var onWheel: ((WheelDirection, Int, Int) -> Void)?
        var onClick: ((Int, Int) -> Void)?
        var onCopy: (() -> String?)?
        var onCopied: ((Int) -> Void)?
        var onFocus: ((Bool) -> Void)?
        var modes = TerminalModes.none
        var preferences = KeyboardPreferences()
        private var mouseReporting: Bool { modes.mouseReporting }
        private var clickMonitor: Any?
        private var releaseMonitor: Any?
        private var wheelMonitor: Any?
        private var responderObservation: NSKeyValueObservation?
        private var keyWindowObservers: [NSObjectProtocol] = []
        /// The focus last reported to the program — one report per transition,
        /// however many responder swaps happened in between.
        private var reportedFocus: Bool?
        /// Where the press landed, kept until the release decides what it was.
        private var press: (point: NSPoint, col: Int, row: Int)?
        /// A hand never holds perfectly still: below this, the pointer did not travel.
        private static let tapSlop: CGFloat = 3
        /// Sub-notch trackpad pixels, kept between events.
        private var wheelResidual: CGFloat = 0
        /// A flick of the trackpad must not become a burst the agent has to
        /// throttle: past this, the extra notches buy nothing but PTY traffic.
        private static let maxNotchesPerEvent = 8

        public override var acceptsFirstResponder: Bool { true }

        /// Nothing owns the keyboard: the window itself is the first responder — or,
        /// with `acceptingUnset`, no one is at all, which is what the window reports
        /// while a freshly inserted view's layout settles.
        fileprivate func focusIsIdle(acceptingUnset: Bool = false) -> Bool {
            guard let window else { return false }
            if window.firstResponder === window { return true }
            return acceptingUnset && window.firstResponder == nil
        }

        /// The one way this view takes the keyboard back: only when nothing owns it,
        /// never by stealing it from a text field the user is typing in.
        fileprivate func reclaimFocusIfIdle(acceptingUnset: Bool = false) {
            guard focusIsIdle(acceptingUnset: acceptingUnset), let window else { return }
            window.makeFirstResponder(self)
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardownFocusWatchers()
            guard let window else { return }
            window.makeFirstResponder(self)
            // Opening a terminal from an icon inserts this view mid-event: the
            // first grab can be refused while layout settles. Retry shortly —
            // idempotent, and never steals from a field the user focused since
            // (the KVO path already guards that case).
            for delay in [0.05, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reclaimFocusIfIdle(acceptingUnset: true)
                }
            }
            // FOCUS BUG FIX — two ways typing used to die, both independent of
            // SwiftUI updates (an idle session produces none, so updateNSView
            // could stay silent forever):
            // 1. A dismissed text field (commit message, palette…) dropped the
            //    first responder back to the window and nothing reclaimed it.
            //    KVO on firstResponder reclaims the instant focus lands on
            //    "nothing" — and never steals from a real text field.
            responderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reclaimFocusIfIdle()
                    self.reportFocusIfChanged()
                }
            }
            // The program may ask for focus events (DECSET 1004): the window
            // going key or resigning is a transition too, not only the responder.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyWindowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.reportFocusIfChanged()
                    })
            }
            // 2. Clicking the transcript is consumed by text selection — the
            //    SwiftUI tap never fired. A local monitor sees every click in
            //    the window; one inside our bounds refocuses the terminal
            //    (async: the selection interaction still runs first).
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                self.press = nil
                if self.bounds.contains(point) {
                    let cell = self.gridPosition(of: point)
                    self.press = (point: point, col: cell.col, row: cell.row)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.window?.makeFirstResponder(self)
                    }
                }
                return event
            }
            // 4. The agent also draws TARGETS — a close box, a file row, a "jump
            //    to bottom". Nothing but a click reaches them: those actions carry
            //    no keybinding at all. The click is decided on the RELEASE, because
            //    only then is it known whether the pointer travelled: a press that
            //    moved was a selection, and the agent must hear nothing of it.
            releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, let press = self.press else { return event }
                self.press = nil
                guard self.mouseReporting, let onClick = self.onClick,
                      event.window === self.window
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let cell = self.gridPosition(of: point)
                guard TerminalClick.isTap(from: press.point, to: point,
                                          sameCell: cell.col == press.col && cell.row == press.row,
                                          slop: Self.tapSlop)
                else { return event }
                onClick(cell.col, cell.row)
                return event
            }
            // 3. A full-screen agent REPAINTS its viewport instead of scrolling
            //    it: our scrollback stays empty, our ScrollView has nothing to
            //    move, and the agent asked for the wheel to scroll itself. A
            //    monitor sees the event before the ScrollView does — going
            //    through the responder chain would already be too late.
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.mouseReporting, let onWheel = self.onWheel,
                      event.window === self.window
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let notches = self.notches(from: event)
                if notches != 0 {
                    let cell = self.gridPosition(of: point)
                    let direction: WheelDirection = notches > 0 ? .up : .down
                    for _ in 0..<min(abs(notches), Self.maxNotchesPerEvent) {
                        onWheel(direction, cell.col, cell.row)
                    }
                }
                return nil
            }
            reportFocusIfChanged()
        }

        /// Focus, as a program sees it: this view is the first responder AND
        /// the window is key. Reported once per change of that combined state.
        private func reportFocusIfChanged() {
            let focused = window.map { $0.isKeyWindow && $0.firstResponder === self } ?? false
            guard focused != reportedFocus else { return }
            reportedFocus = focused
            onFocus?(focused)
        }

        public override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            DispatchQueue.main.async { [weak self] in self?.reportFocusIfChanged() }
            return became
        }

        public override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            DispatchQueue.main.async { [weak self] in self?.reportFocusIfChanged() }
            return resigned
        }

        /// Trackpads deliver pixels, mice deliver lines: both become NOTCHES, the
        /// unit a tracking program counts — one cell of travel per notch, so the
        /// pane scrolls at the speed the text is drawn.
        private func notches(from event: NSEvent) -> Int {
            guard event.hasPreciseScrollingDeltas else {
                return Int(event.scrollingDeltaY.rounded())
            }
            if event.phase == .began { wheelResidual = 0 }
            wheelResidual += event.scrollingDeltaY
            let step = TerminalMetrics.cellSize.height
            let whole = (wheelResidual / step).rounded(.towardZero)
            wheelResidual -= whole * step
            return Int(whole)
        }

        /// View point → terminal cell (0-based). The grid starts inside the
        /// padding the screen view draws, the same one `TerminalMetrics.grid` deducts.
        private func gridPosition(of point: NSPoint) -> (col: Int, row: Int) {
            let cell = TerminalMetrics.cellSize
            let inset = TerminalMetrics.gridInset
            let grid = TerminalMetrics.grid(fitting: bounds.size)
            let column = Int((point.x - inset) / cell.width)
            let row = Int((bounds.height - point.y - inset) / cell.height)
            return (col: min(max(0, column), grid.cols - 1),
                    row: min(max(0, row), grid.rows - 1))
        }

        private func teardownFocusWatchers() {
            responderObservation?.invalidate()
            responderObservation = nil
            for observer in keyWindowObservers { NotificationCenter.default.removeObserver(observer) }
            keyWindowObservers = []
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
            releaseMonitor = nil
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }

        deinit {
            responderObservation?.invalidate()
            for observer in keyWindowObservers { NotificationCenter.default.removeObserver(observer) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }

        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        /// Nothing claims a cursor since text selection became ours.
        public override func resetCursorRects() {
            addCursorRect(bounds, cursor: .iBeam)
        }

        /// Edit ▸ Copy finds this through the responder chain — the view keeps
        /// itself first responder, and the standard Edit menu is untouched.
        @objc func copy(_ sender: Any?) {
            copySelection()
        }

        /// ⌘V means three different things depending on what was copied.
        /// Copied FILES come first: a terminal wants their paths, and a Finder
        /// copy also carries a bare filename as text, which would win otherwise.
        /// A raw image — a screenshot — is left to the agent, which reads the
        /// pasteboard itself; 0x16 is the gesture it listens for.
        private func paste() -> Bool {
            let pasteboard = NSPasteboard.general
            let filesOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: filesOnly) as? [URL],
               !urls.isEmpty {
                let paths = urls.map { KeyTranslator.quoted(path: $0.path) }.joined(separator: " ")
                onText?(KeyTranslator.paste(paths, bracketed: modes.bracketedPaste))
                return true
            }
            // Bracketed when the program asked, so a multi-line paste is one
            // block, not N submits.
            if let text = pasteboard.string(forType: .string) {
                onText?(KeyTranslator.paste(text, bracketed: modes.bracketedPaste))
                return true
            }
            if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
                onText?("\u{16}")
                return true
            }
            return false
        }

        private func copySelection() {
            guard let text = onCopy?(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onCopied?(text.count)
        }

        /// ⌘ → the app; everything the encoder knows (special keys with any
        /// modifier, control combinations, Meta, the kitty dialect) → the PTY;
        /// plain text → AppKit composition, which is what keeps dead keys alive.
        public override func keyDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.command) else {
                super.keyDown(with: event)
                return
            }
            if let bytes = KeyTranslator.encode(KeyStroke(event), modes: modes,
                                                preferences: preferences,
                                                event: event.isARepeat ? .repeat : .press) {
                onText?(bytes)
                return
            }
            interpretKeyEvents([event])
        }

        /// Only a program that pushed the kitty "report events" flag hears releases.
        public override func keyUp(with event: NSEvent) {
            guard modes.keyboardEnhancement.contains(.reportEvents),
                  !event.modifierFlags.contains(.command),
                  let bytes = KeyTranslator.encode(KeyStroke(event), modes: modes,
                                                   preferences: preferences, event: .release)
            else {
                super.keyUp(with: event)
                return
            }
            onText?(bytes)
        }

        public override func insertText(_ insertString: Any) {
            if let text = insertString as? String {
                onText?(text)
            } else if let attributed = insertString as? NSAttributedString {
                onText?(attributed.string)
            }
        }

        public override func doCommand(by selector: Selector) {
            // The editing selectors are already covered by the special keys;
            // we absorb the rest without triggering the system beep.
        }

        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control) else {
                return super.performKeyEquivalent(with: event)
            }
            let characters = event.charactersIgnoringModifiers ?? ""
            if characters == "v" { return paste() }
            // ⌘C is swallowed WHETHER OR NOT there is a selection. Letting it
            // through on an empty one leaves the key equivalent unclaimed, and it
            // falls to keyDown → super → noResponder → beep. `.textSelection`
            // used to absorb that; nothing does since it left.
            if characters == "c" {
                copySelection()
                return true
            }
            // Mac editing shortcuts (⌘A, ⌘Z, ⌘←/→, ⌘⌫) — everything else
            // (⌘K, ⌘N, ⌘T…) falls through to the app's own commands.
            if let bytes = KeyTranslator.command(characters: characters, keyCode: event.keyCode) {
                onText?(bytes)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Greys out Edit ▸ Copy when there is nothing selected.
extension KeyCaptureView.CaptureNSView: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return true }
        return onCopy?()?.isEmpty == false
    }
}
