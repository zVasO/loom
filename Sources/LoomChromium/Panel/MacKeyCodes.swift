import Foundation

// A Mac keyboard's physical keys as a page's KeyboardEvent reads them, the
// way Chrome on a Mac reports them (panel design §2, Keyboard):
//
// - `code`: the physical key (Chromium's dom_code_data.inc, Mac column);
// - `key`: a name for a key that types nothing ("Enter", "ArrowLeft",
//   "Shift"), else the character typed — with Control or Command, the
//   character under no modifier (⌃A reads "a", not U+0001);
// - `windowsVirtualKeyCode` (`keyCode` in the page): Chromium's
//   KeyboardCodeFromNSEvent — an ASCII letter or digit among the characters
//   ignoring modifiers decides (AZERTY's physical KeyQ typing "a" is 65, "A"),
//   otherwise the physical key's US mapping (AZERTY's "&" is Digit1, 49). A
//   numeric-keypad key always takes its physical code (Numpad1 is 97), as
//   Blink's IsKeypadEvent rule does;
// - `location`: 1 left, 2 right (modifiers), 3 numeric keypad, else 0.
//
// `KeyTranslator.FunctionalKey` in LoomUI is the terminal's and internal; it
// is not reused.

/// A key as the page's KeyboardEvent reads it.
public struct KeyIdentity: Equatable, Hashable, Sendable {
    public var key: String
    public var code: String
    public var windowsKeyCode: Int
    /// `KeyboardEvent.location`: 1 left, 2 right, 3 numpad, 0 otherwise.
    public var location: Int

    public init(key: String, code: String, windowsKeyCode: Int, location: Int = 0) {
        self.key = key
        self.code = code
        self.windowsKeyCode = windowsKeyCode
        self.location = location
    }
}

public enum MacKeyCodes {

    /// One physical key: its DOM code, the Windows virtual key code of its
    /// US mapping, its name when it types nothing, its location.
    public struct Entry: Equatable, Sendable {
        public let code: String
        public let windowsKeyCode: Int
        public let namedKey: String?
        public let location: Int

        public init(code: String, windowsKeyCode: Int, namedKey: String? = nil, location: Int = 0) {
            self.code = code
            self.windowsKeyCode = windowsKeyCode
            self.namedKey = namedKey
            self.location = location
        }
    }

    // The virtual key codes the panel's own logic names (Carbon's kVK_*).
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let backspace: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let rightCommand: UInt16 = 0x36
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let rightShift: UInt16 = 0x3C
    public static let rightOption: UInt16 = 0x3D
    public static let rightControl: UInt16 = 0x3E
    public static let keypadEnter: UInt16 = 0x4C
    public static let forwardDelete: UInt16 = 0x75
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E

    private static func physical(_ code: String, _ windowsKeyCode: Int, _ namedKey: String? = nil,
                                 _ location: Int = 0) -> Entry {
        Entry(code: code, windowsKeyCode: windowsKeyCode, namedKey: namedKey, location: location)
    }

    /// Mac virtual key code → the key. Keys missing here (Fn alone, unknown
    /// hardware) read as code "", keyCode 0.
    public static let table: [UInt16: Entry] = [
        // Letters and digits (ANSI positions).
        0x00: physical("KeyA", 65), 0x01: physical("KeyS", 83), 0x02: physical("KeyD", 68), 0x03: physical("KeyF", 70),
        0x04: physical("KeyH", 72), 0x05: physical("KeyG", 71), 0x06: physical("KeyZ", 90), 0x07: physical("KeyX", 88),
        0x08: physical("KeyC", 67), 0x09: physical("KeyV", 86), 0x0B: physical("KeyB", 66), 0x0C: physical("KeyQ", 81),
        0x0D: physical("KeyW", 87), 0x0E: physical("KeyE", 69), 0x0F: physical("KeyR", 82), 0x10: physical("KeyY", 89),
        0x11: physical("KeyT", 84), 0x1F: physical("KeyO", 79), 0x20: physical("KeyU", 85), 0x22: physical("KeyI", 73),
        0x23: physical("KeyP", 80), 0x25: physical("KeyL", 76), 0x26: physical("KeyJ", 74), 0x28: physical("KeyK", 75),
        0x2D: physical("KeyN", 78), 0x2E: physical("KeyM", 77),
        0x12: physical("Digit1", 49), 0x13: physical("Digit2", 50), 0x14: physical("Digit3", 51), 0x15: physical("Digit4", 52),
        0x16: physical("Digit6", 54), 0x17: physical("Digit5", 53), 0x19: physical("Digit9", 57), 0x1A: physical("Digit7", 55),
        0x1C: physical("Digit8", 56), 0x1D: physical("Digit0", 48),
        // Punctuation, US mapping.
        0x18: physical("Equal", 187), 0x1B: physical("Minus", 189), 0x1E: physical("BracketRight", 221),
        0x21: physical("BracketLeft", 219), 0x27: physical("Quote", 222), 0x29: physical("Semicolon", 186),
        0x2A: physical("Backslash", 220), 0x2B: physical("Comma", 188), 0x2C: physical("Slash", 191),
        0x2F: physical("Period", 190), 0x32: physical("Backquote", 192), 0x0A: physical("IntlBackslash", 192),
        0x31: physical("Space", 32),
        // JIS.
        0x5D: physical("IntlYen", 220), 0x5E: physical("IntlRo", 226), 0x66: physical("Lang2", 0, "Eisu"),
        0x68: physical("Lang1", 21, "KanaMode"),
        // Keys that type nothing.
        0x24: physical("Enter", 13, "Enter"), 0x30: physical("Tab", 9, "Tab"), 0x33: physical("Backspace", 8, "Backspace"),
        0x35: physical("Escape", 27, "Escape"), 0x75: physical("Delete", 46, "Delete"), 0x72: physical("Insert", 45, "Insert"),
        0x73: physical("Home", 36, "Home"), 0x77: physical("End", 35, "End"), 0x74: physical("PageUp", 33, "PageUp"),
        0x79: physical("PageDown", 34, "PageDown"), 0x7B: physical("ArrowLeft", 37, "ArrowLeft"),
        0x7C: physical("ArrowRight", 39, "ArrowRight"), 0x7D: physical("ArrowDown", 40, "ArrowDown"),
        0x7E: physical("ArrowUp", 38, "ArrowUp"), 0x6E: physical("ContextMenu", 93, "ContextMenu"),
        0x48: physical("AudioVolumeUp", 175, "AudioVolumeUp"), 0x49: physical("AudioVolumeDown", 174, "AudioVolumeDown"),
        0x4A: physical("AudioVolumeMute", 173, "AudioVolumeMute"),
        // Function keys.
        0x7A: physical("F1", 112, "F1"), 0x78: physical("F2", 113, "F2"), 0x63: physical("F3", 114, "F3"),
        0x76: physical("F4", 115, "F4"), 0x60: physical("F5", 116, "F5"), 0x61: physical("F6", 117, "F6"),
        0x62: physical("F7", 118, "F7"), 0x64: physical("F8", 119, "F8"), 0x65: physical("F9", 120, "F9"),
        0x6D: physical("F10", 121, "F10"), 0x67: physical("F11", 122, "F11"), 0x6F: physical("F12", 123, "F12"),
        0x69: physical("F13", 124, "F13"), 0x6B: physical("F14", 125, "F14"), 0x71: physical("F15", 126, "F15"),
        0x6A: physical("F16", 127, "F16"), 0x40: physical("F17", 128, "F17"), 0x4F: physical("F18", 129, "F18"),
        0x50: physical("F19", 130, "F19"), 0x5A: physical("F20", 131, "F20"),
        // Modifiers.
        0x38: physical("ShiftLeft", 16, "Shift", 1), 0x3C: physical("ShiftRight", 16, "Shift", 2),
        0x3B: physical("ControlLeft", 17, "Control", 1), 0x3E: physical("ControlRight", 17, "Control", 2),
        0x3A: physical("AltLeft", 18, "Alt", 1), 0x3D: physical("AltRight", 18, "Alt", 2),
        0x37: physical("MetaLeft", 91, "Meta", 1), 0x36: physical("MetaRight", 92, "Meta", 2),
        0x39: physical("CapsLock", 20, "CapsLock"),
        // Numeric keypad.
        0x52: physical("Numpad0", 96, nil, 3), 0x53: physical("Numpad1", 97, nil, 3), 0x54: physical("Numpad2", 98, nil, 3),
        0x55: physical("Numpad3", 99, nil, 3), 0x56: physical("Numpad4", 100, nil, 3), 0x57: physical("Numpad5", 101, nil, 3),
        0x58: physical("Numpad6", 102, nil, 3), 0x59: physical("Numpad7", 103, nil, 3), 0x5B: physical("Numpad8", 104, nil, 3),
        0x5C: physical("Numpad9", 105, nil, 3), 0x41: physical("NumpadDecimal", 110, nil, 3),
        0x43: physical("NumpadMultiply", 106, nil, 3), 0x45: physical("NumpadAdd", 107, nil, 3),
        0x4B: physical("NumpadDivide", 111, nil, 3), 0x4E: physical("NumpadSubtract", 109, nil, 3),
        0x51: physical("NumpadEqual", 187, nil, 3), 0x5F: physical("NumpadComma", 188, nil, 3),
        0x4C: physical("NumpadEnter", 13, "Enter", 3),
        // The keypad's Clear is NumLock's position (Chromium's mapping).
        0x47: physical("NumLock", 12, "Clear"),
    ]

    public static func entry(_ keyCode: UInt16) -> Entry? {
        table[keyCode]
    }

    /// `KeyboardEvent.code`; "" for a key the table does not know.
    public static func code(_ keyCode: UInt16) -> String {
        table[keyCode]?.code ?? ""
    }

    /// The `key` of a key that types nothing; nil for a character key.
    public static func namedKey(_ keyCode: UInt16) -> String? {
        table[keyCode]?.namedKey
    }

    public static func location(_ keyCode: UInt16) -> Int {
        table[keyCode]?.location ?? 0
    }

    /// The modifier a modifier key sets; nil for Caps Lock and any other key.
    public static func modifierFlag(_ keyCode: UInt16) -> CDPModifiers? {
        switch keyCode {
        case shift, rightShift: return CDPModifiers.shift
        case control, rightControl: return CDPModifiers.control
        case option, rightOption: return CDPModifiers.alt
        case command, rightCommand: return CDPModifiers.meta
        default: return nil
        }
    }

    /// Shift, Control, Option, Command (either side) or Caps Lock: a key
    /// AppKit reports by flagsChanged, never keyDown.
    public static func isModifierKey(_ keyCode: UInt16) -> Bool {
        keyCode == capsLock || modifierFlag(keyCode) != nil
    }

    /// Chromium's KeyboardCodeFromNSEvent: a letter or digit among the
    /// characters ignoring modifiers, else the physical key's US code.
    public static func windowsKeyCode(keyCode: UInt16, charactersIgnoringModifiers: String) -> Int {
        let entry = table[keyCode]
        if entry?.location != 3, let first = charactersIgnoringModifiers.unicodeScalars.first {
            let value = first.value
            if value >= 0x61 && value <= 0x7A { return Int(value - 0x20) }  // a–z → A–Z
            if value >= 0x41 && value <= 0x5A { return Int(value) }          // A–Z
            if value >= 0x30 && value <= 0x39 { return Int(value) }          // 0–9
        }
        return entry?.windowsKeyCode ?? 0
    }

    /// `KeyboardEvent.key`: the name of a key that types nothing; else the
    /// last character typed (a dead key's failed combination "^q" reads
    /// "q"); a control character under Control or Command reads as the key's
    /// own character; a dead key alone, "Dead".
    public static func key(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String,
                           modifiers: CDPModifiers) -> String {
        if let named = namedKey(keyCode) { return named }
        guard var last = characters.last else {
            return charactersIgnoringModifiers.isEmpty ? "Unidentified" : "Dead"
        }
        let shortcut = (modifiers.contains(.control) && !modifiers.contains(.alt)) || modifiers.contains(.meta)
        if isControl(last), shortcut, let unmodified = charactersIgnoringModifiers.last {
            last = unmodified
        }
        return isControl(last) || isFunctionKey(last) ? "Unidentified" : String(last)
    }

    /// The whole identity of a key press.
    public static func identity(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String,
                                modifiers: CDPModifiers) -> KeyIdentity {
        KeyIdentity(key: key(keyCode: keyCode, characters: characters,
                             charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers),
                    code: code(keyCode),
                    windowsKeyCode: windowsKeyCode(keyCode: keyCode,
                                                   charactersIgnoringModifiers: charactersIgnoringModifiers),
                    location: location(keyCode))
    }

    /// C0 controls and DEL: what ⌃A, Return or Backspace put in `characters`.
    static func isControl(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// AppKit's private-use characters for arrows and function keys (U+F700…U+F8FF).
    static func isFunctionKey(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }
}
