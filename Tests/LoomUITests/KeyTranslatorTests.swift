import Testing
@testable import LoomUI

/// SES-05bis: keystrokes go straight to the agent's input field — the view
/// captures the keys and the translator converts them into bytes for the PTY.
@Suite("KeyTranslator — from keystrokes to PTY bytes")
struct KeyTranslatorTests {

    @Test("printable characters pass through as-is (AZERTY included)")
    func caracteresImprimables() {
        #expect(KeyTranslator.bytes(keyCode: 0, characters: "a", option: false) == "a")
        #expect(KeyTranslator.bytes(keyCode: 0, characters: "é", option: false) == "é")
    }

    @Test("Return sends CR — that is the agent field's submit")
    func entree() {
        #expect(KeyTranslator.bytes(keyCode: 36, characters: "\r", option: false) == "\r")
    }

    @Test("Option+Return sends ESC CR — newline inside the agent's field")
    func optionEntree() {
        #expect(KeyTranslator.bytes(keyCode: 36, characters: "\r", option: true) == "\u{1b}\r")
    }

    @Test("backspace sends DEL, not BS")
    func effacement() {
        #expect(KeyTranslator.bytes(keyCode: 51, characters: "\u{8}", option: false) == "\u{7f}")
    }

    @Test("arrow keys become CSI sequences")
    func fleches() {
        #expect(KeyTranslator.bytes(keyCode: 126, characters: "", option: false) == "\u{1b}[A")
        #expect(KeyTranslator.bytes(keyCode: 125, characters: "", option: false) == "\u{1b}[B")
        #expect(KeyTranslator.bytes(keyCode: 124, characters: "", option: false) == "\u{1b}[C")
        #expect(KeyTranslator.bytes(keyCode: 123, characters: "", option: false) == "\u{1b}[D")
    }

    @Test("Escape and Tab pass through as raw control")
    func echapEtTab() {
        #expect(KeyTranslator.bytes(keyCode: 53, characters: "\u{1b}", option: false) == "\u{1b}")
        #expect(KeyTranslator.bytes(keyCode: 48, characters: "\t", option: false) == "\t")
    }

    @Test("Ctrl+C already arrives as ETX in characters and passes through as-is")
    func controle() {
        #expect(KeyTranslator.bytes(keyCode: 8, characters: "\u{3}", option: false) == "\u{3}")
    }

    @Test("a keystroke with no character and no special key produces nothing")
    func toucheMuette() {
        #expect(KeyTranslator.bytes(keyCode: 63, characters: "", option: false) == nil)
    }
}
