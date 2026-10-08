import Testing
import LoomChromium
import Foundation

// Seam: a Mac keyboard's physical keys as the page's KeyboardEvent reads
// them — code, key, keyCode, location — as Chrome on a Mac reports them,
// French (AZERTY) keyboards included.

@Suite("MacKeyCodes — Mac keys as the page reads them")
struct MacKeyCodesTests {

    @Test("letters, digits and punctuation: the physical code and the US key code")
    func lettresEtChiffres() {
        #expect(MacKeyCodes.code(0x00) == "KeyA")
        #expect(MacKeyCodes.entry(0x00)?.windowsKeyCode == 65)
        #expect(MacKeyCodes.code(0x1D) == "Digit0")
        #expect(MacKeyCodes.entry(0x1D)?.windowsKeyCode == 48)
        #expect(MacKeyCodes.code(0x2B) == "Comma")
        #expect(MacKeyCodes.entry(0x2B)?.windowsKeyCode == 188)
        #expect(MacKeyCodes.code(0x0A) == "IntlBackslash")
        #expect(MacKeyCodes.code(0x32) == "Backquote")
        #expect(MacKeyCodes.code(0xFF) == "", "an unknown key has no code")
    }

    @Test("AZERTY: the letter typed decides the key code (KeyQ typing a is 65), else the physical key")
    func azerty() {
        let q = MacKeyCodes.identity(keyCode: 0x0C, characters: "a", charactersIgnoringModifiers: "a", modifiers: [])
        #expect(q == KeyIdentity(key: "a", code: "KeyQ", windowsKeyCode: 65))
        // The "&" of the digit row is Digit1: no letter or digit, the US mapping's 49.
        let ampersand = MacKeyCodes.identity(keyCode: 0x12, characters: "&", charactersIgnoringModifiers: "&", modifiers: [])
        #expect(ampersand == KeyIdentity(key: "&", code: "Digit1", windowsKeyCode: 49))
        let eAcute = MacKeyCodes.identity(keyCode: 0x13, characters: "é", charactersIgnoringModifiers: "é", modifiers: [])
        #expect(eAcute == KeyIdentity(key: "é", code: "Digit2", windowsKeyCode: 50))
        // Shifted, the same key types the digit itself.
        #expect(MacKeyCodes.windowsKeyCode(keyCode: 0x13, charactersIgnoringModifiers: "2") == 50)
        // AZERTY's M is the US semicolon key: the letter wins.
        #expect(MacKeyCodes.windowsKeyCode(keyCode: 0x29, charactersIgnoringModifiers: "m") == 77)
    }

    @Test("named keys for the keys that type nothing; the keypad keeps its own codes")
    func touchesNommees() {
        let enter = MacKeyCodes.identity(keyCode: 0x24, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: [])
        #expect(enter == KeyIdentity(key: "Enter", code: "Enter", windowsKeyCode: 13))
        let left = MacKeyCodes.identity(keyCode: 0x7B, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
                                        modifiers: [.meta])
        #expect(left == KeyIdentity(key: "ArrowLeft", code: "ArrowLeft", windowsKeyCode: 37))
        let f1 = MacKeyCodes.identity(keyCode: 0x7A, characters: "\u{F704}", charactersIgnoringModifiers: "\u{F704}",
                                      modifiers: [])
        #expect(f1 == KeyIdentity(key: "F1", code: "F1", windowsKeyCode: 112))
        let numpad = MacKeyCodes.identity(keyCode: 0x53, characters: "1", charactersIgnoringModifiers: "1", modifiers: [])
        #expect(numpad == KeyIdentity(key: "1", code: "Numpad1", windowsKeyCode: 97, location: 3))
        let numpadEnter = MacKeyCodes.identity(keyCode: 0x4C, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}",
                                               modifiers: [])
        #expect(numpadEnter == KeyIdentity(key: "Enter", code: "NumpadEnter", windowsKeyCode: 13, location: 3))
        let space = MacKeyCodes.identity(keyCode: 0x31, characters: " ", charactersIgnoringModifiers: " ", modifiers: [])
        #expect(space == KeyIdentity(key: " ", code: "Space", windowsKeyCode: 32))
        #expect(MacKeyCodes.namedKey(0x72) == "Insert", "the Help key is Insert, as Chromium maps it")
    }

    @Test("modifier keys: their side, code and key code; Caps Lock has no flag")
    func modificateurs() {
        #expect(MacKeyCodes.entry(0x38) == MacKeyCodes.Entry(code: "ShiftLeft", windowsKeyCode: 16, namedKey: "Shift",
                                                              location: 1))
        #expect(MacKeyCodes.entry(0x3C)?.location == 2)
        #expect(MacKeyCodes.entry(0x37)?.windowsKeyCode == 91)
        #expect(MacKeyCodes.entry(0x36)?.windowsKeyCode == 92)
        #expect(MacKeyCodes.code(0x36) == "MetaRight")
        #expect(MacKeyCodes.entry(0x3B)?.windowsKeyCode == 17)
        #expect(MacKeyCodes.entry(0x3D)?.code == "AltRight")
        #expect(MacKeyCodes.entry(0x39)?.windowsKeyCode == 20)
        #expect(MacKeyCodes.location(0x39) == 0)
        #expect(MacKeyCodes.modifierFlag(0x3C) == CDPModifiers.shift)
        #expect(MacKeyCodes.modifierFlag(0x3E) == CDPModifiers.control)
        #expect(MacKeyCodes.modifierFlag(0x3A) == CDPModifiers.alt)
        #expect(MacKeyCodes.modifierFlag(0x36) == CDPModifiers.meta)
        #expect(MacKeyCodes.modifierFlag(0x39) == nil)
        #expect(MacKeyCodes.isModifierKey(0x39))
        #expect(!MacKeyCodes.isModifierKey(0x00))
    }

    @Test("key: ⌃A reads a, ⌥ keeps its character, a dead key alone reads Dead, a failed combination its last character")
    func valeurDeKey() {
        #expect(MacKeyCodes.key(keyCode: 0x00, characters: "\u{1}", charactersIgnoringModifiers: "a",
                                modifiers: [.control]) == "a")
        #expect(MacKeyCodes.key(keyCode: 0x17, characters: "{", charactersIgnoringModifiers: "(",
                                modifiers: [.alt]) == "{")
        #expect(MacKeyCodes.key(keyCode: 0x21, characters: "", charactersIgnoringModifiers: "^", modifiers: []) == "Dead")
        #expect(MacKeyCodes.key(keyCode: 0x0C, characters: "^q", charactersIgnoringModifiers: "q", modifiers: []) == "q")
        #expect(MacKeyCodes.key(keyCode: 0x08, characters: "c", charactersIgnoringModifiers: "c",
                                modifiers: [.meta]) == "c")
    }

    @Test("every key has its own code")
    func codesUniques() {
        let codes = MacKeyCodes.table.values.map { $0.code }
        #expect(Set(codes).count == codes.count)
        #expect(codes.count > 100)
    }
}
