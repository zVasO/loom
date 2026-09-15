import Testing
import LoomTerminal
@testable import LoomUI

/// SES-05bis: keystrokes go straight to the agent's input field — the view
/// captures the keys and the translator converts them into bytes for the PTY.
/// One test per binding claude relies on: losing any of them is the bug.
@Suite("KeyTranslator — from keystrokes to PTY bytes")
struct KeyTranslatorTests {

    // Key codes of a Mac keyboard, the way NSEvent reports them.
    private enum Code {
        static let a: UInt16 = 0, c: UInt16 = 8, o: UInt16 = 31, r: UInt16 = 15, b: UInt16 = 11
        static let t: UInt16 = 17, u: UInt16 = 32, l: UInt16 = 37, z: UInt16 = 6
        static let space: UInt16 = 49, minus: UInt16 = 27, slash: UInt16 = 44
        static let bracketLeft: UInt16 = 33, backslash: UInt16 = 42, bracketRight: UInt16 = 30
        static let six: UInt16 = 22
        static let enter: UInt16 = 36, keypadEnter: UInt16 = 76, tab: UInt16 = 48
        static let backspace: UInt16 = 51, escape: UInt16 = 53, forwardDelete: UInt16 = 117
        static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let f1: UInt16 = 122, f5: UInt16 = 96, f12: UInt16 = 111
    }

    private func key(_ code: UInt16, chars: String = "", base: String? = nil,
                     shift: Bool = false, control: Bool = false, option: Bool = false) -> KeyStroke {
        KeyStroke(keyCode: code, characters: chars, charactersIgnoringModifiers: base ?? chars,
                  shift: shift, control: control, option: option)
    }

    private func legacy(_ stroke: KeyStroke, modes: TerminalModes = .none,
                        optionAsMeta: Bool = false, event: KeyEventKind = .press) -> String? {
        KeyTranslator.encode(stroke, modes: modes,
                             preferences: KeyboardPreferences(optionAsMeta: optionAsMeta),
                             event: event)
    }

    private func kitty(_ flags: KeyboardEnhancement) -> TerminalModes {
        TerminalModes(keyboardEnhancement: flags)
    }

    // MARK: - The claude bindings, legacy dialect

    @Test("Shift+Tab is back-tab (CSI Z) — the mode cycle: auto, plan, accept edits")
    func shiftTab() {
        #expect(legacy(key(Code.tab, chars: "\u{19}", base: "\u{19}", shift: true)) == "\u{1b}[Z")
        #expect(legacy(key(Code.tab, chars: "\t")) == "\t", "a plain Tab is still a Tab")
    }

    @Test("Shift+Return and Option+Return insert a newline: ESC CR")
    func newlineInPrompt() {
        #expect(legacy(key(Code.enter, chars: "\r", shift: true)) == "\u{1b}\r")
        #expect(legacy(key(Code.enter, chars: "\r", option: true)) == "\u{1b}\r")
        #expect(legacy(key(Code.enter, chars: "\r")) == "\r", "Return alone submits")
        #expect(legacy(key(Code.keypadEnter, chars: "\u{3}")) == "\r", "keypad Enter submits too")
    }

    @Test("Escape interrupts, whatever modifier rides along")
    func escape() {
        #expect(legacy(key(Code.escape, chars: "\u{1b}")) == "\u{1b}")
        #expect(legacy(key(Code.escape, chars: "\u{1b}", shift: true)) == "\u{1b}")
    }

    @Test("Ctrl+letter folds to the C0 control character, from the layout's base key")
    func controlLetters() {
        let expected: [(UInt16, String, String)] = [
            (Code.c, "c", "\u{03}"), (Code.o, "o", "\u{0f}"), (Code.r, "r", "\u{12}"),
            (Code.b, "b", "\u{02}"), (Code.t, "t", "\u{14}"), (Code.u, "u", "\u{15}"),
            (Code.l, "l", "\u{0c}"), (Code.z, "z", "\u{1a}"),
        ]
        for (code, base, bytes) in expected {
            #expect(legacy(key(code, chars: bytes, base: base, control: true)) == bytes)
        }
        #expect(legacy(key(Code.c, chars: "\u{03}", base: "C", control: true, shift: true)) == "\u{03}",
                "Shift does not change a control character")
    }

    @Test("Ctrl+_ and Ctrl+/ send 0x1F (undo), Ctrl+Space sends NUL")
    func controlPunctuation() {
        #expect(legacy(key(Code.minus, chars: "_", base: "_", control: true, shift: true)) == "\u{1f}")
        #expect(legacy(key(Code.slash, chars: "/", base: "/", control: true)) == "\u{1f}")
        #expect(legacy(key(Code.space, chars: " ", base: " ", control: true)) == "\u{0}")
        #expect(legacy(key(Code.bracketLeft, chars: "[", base: "[", control: true)) == "\u{1b}")
        #expect(legacy(key(Code.backslash, chars: "\\", base: "\\", control: true)) == "\u{1c}")
        #expect(legacy(key(Code.bracketRight, chars: "]", base: "]", control: true)) == "\u{1d}")
        #expect(legacy(key(Code.six, chars: "^", base: "^", control: true, shift: true)) == "\u{1e}")
    }

    @Test("Ctrl on a non-ASCII layout falls back to the character AppKit folded")
    func controlFoldedByAppKit() {
        #expect(legacy(key(Code.c, chars: "\u{03}", base: "с", control: true)) == "\u{03}")
    }

    @Test("backspace: DEL plain, Ctrl+W with Option (delete a word), BS with Control")
    func backspace() {
        #expect(legacy(key(Code.backspace, chars: "\u{8}")) == "\u{7f}")
        #expect(legacy(key(Code.backspace, chars: "\u{8}", option: true)) == "\u{17}")
        #expect(legacy(key(Code.backspace, chars: "\u{8}", control: true)) == "\u{08}")
    }

    @Test("arrows: CSI plain, SS3 under application cursor keys, CSI 1;m with modifiers")
    func arrows() {
        #expect(legacy(key(Code.up)) == "\u{1b}[A")
        #expect(legacy(key(Code.down)) == "\u{1b}[B")
        #expect(legacy(key(Code.right)) == "\u{1b}[C")
        #expect(legacy(key(Code.left)) == "\u{1b}[D")
        let application = TerminalModes(applicationCursorKeys: true)
        #expect(legacy(key(Code.up), modes: application) == "\u{1b}OA", "vim and less set DECCKM")
        #expect(legacy(key(Code.home), modes: application) == "\u{1b}OH")
        #expect(legacy(key(Code.up, shift: true)) == "\u{1b}[1;2A")
        #expect(legacy(key(Code.left, control: true)) == "\u{1b}[1;5D")
        #expect(legacy(key(Code.up, control: true), modes: application) == "\u{1b}[1;5A",
                "a modified arrow is CSI even under DECCKM")
        #expect(legacy(key(Code.left, shift: true, option: true)) == "\u{1b}[1;4D")
    }

    @Test("Option+arrows jump by word — the Mac idiom, kept over CSI 1;3")
    func optionArrows() {
        #expect(legacy(key(Code.left, option: true)) == "\u{1b}b")
        #expect(legacy(key(Code.right, option: true)) == "\u{1b}f")
    }

    @Test("Home, End, PageUp, PageDown, Delete — plain and modified")
    func navigationKeys() {
        #expect(legacy(key(Code.home)) == "\u{1b}[H")
        #expect(legacy(key(Code.end)) == "\u{1b}[F")
        #expect(legacy(key(Code.end, shift: true)) == "\u{1b}[1;2F")
        #expect(legacy(key(Code.pageUp)) == "\u{1b}[5~")
        #expect(legacy(key(Code.pageDown, shift: true)) == "\u{1b}[6;2~")
        #expect(legacy(key(Code.forwardDelete)) == "\u{1b}[3~")
        #expect(legacy(key(Code.forwardDelete, control: true)) == "\u{1b}[3;5~")
    }

    @Test("function keys: SS3 for F1–F4, CSI n~ beyond, modifiers as parameters")
    func functionKeys() {
        #expect(legacy(key(Code.f1)) == "\u{1b}OP")
        #expect(legacy(key(Code.f1, shift: true)) == "\u{1b}[1;2P")
        #expect(legacy(key(Code.f5)) == "\u{1b}[15~")
        #expect(legacy(key(Code.f5, shift: true)) == "\u{1b}[15;2~")
        #expect(legacy(key(Code.f12)) == "\u{1b}[24~")
    }

    @Test("Option as Meta is opt-in: off leaves ⌥ to the keyboard layout, on sends ESC+key")
    func optionAsMeta() {
        let optionA = key(Code.a, chars: "å", base: "a", option: true)
        #expect(legacy(optionA) == nil, "off: AppKit composes the glyph the layout has under ⌥")
        #expect(legacy(optionA, optionAsMeta: true) == "\u{1b}a")
        #expect(legacy(key(Code.a, chars: "Å", base: "A", shift: true, option: true),
                       optionAsMeta: true) == "\u{1b}A")
        #expect(legacy(key(Code.c, chars: "\u{03}", base: "c", control: true, option: true),
                       optionAsMeta: true) == "\u{1b}\u{03}")
    }

    @Test("plain text, accents and dead keys are left to AppKit: nil")
    func plainTextIsComposed() {
        #expect(legacy(key(Code.a, chars: "a")) == nil)
        #expect(legacy(key(Code.a, chars: "A", shift: true)) == nil)
        #expect(legacy(key(0, chars: "é")) == nil)
        #expect(legacy(key(0, chars: "{", base: "(", option: true)) == nil, "AZERTY brace under ⌥")
        #expect(legacy(key(0, chars: "")) == nil, "a dead key in progress")
        #expect(legacy(key(63, chars: "")) == nil, "fn alone")
    }

    @Test("key repeats are sent like presses, releases are not a legacy concept")
    func repeatsAndReleases() {
        #expect(legacy(key(Code.up), event: .repeat) == "\u{1b}[A")
        #expect(legacy(key(Code.up), event: .release) == nil)
    }

    // MARK: - Modifier parameter

    @Test("the xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4), absent when none")
    func modifierParameter() {
        #expect(KeyTranslator.modifierParameter(shift: false, option: false, control: false) == nil)
        #expect(KeyTranslator.modifierParameter(shift: true, option: false, control: false) == 2)
        #expect(KeyTranslator.modifierParameter(shift: false, option: true, control: false) == 3)
        #expect(KeyTranslator.modifierParameter(shift: true, option: true, control: false) == 4)
        #expect(KeyTranslator.modifierParameter(shift: false, option: false, control: true) == 5)
        #expect(KeyTranslator.modifierParameter(shift: true, option: false, control: true) == 6)
        #expect(KeyTranslator.modifierParameter(shift: false, option: true, control: true) == 7)
        #expect(KeyTranslator.modifierParameter(shift: true, option: true, control: true) == 8)
    }

    // MARK: - kitty keyboard protocol

    @Test("under 'disambiguate', Shift+Tab, Shift+Return and Escape become CSI u reports")
    func kittyDisambiguateSpecials() {
        let modes = kitty(.disambiguate)
        #expect(legacy(key(Code.tab, chars: "\u{19}", shift: true), modes: modes) == "\u{1b}[9;2u")
        #expect(legacy(key(Code.enter, chars: "\r", shift: true), modes: modes) == "\u{1b}[13;2u")
        #expect(legacy(key(Code.escape, chars: "\u{1b}"), modes: modes) == "\u{1b}[27u")
        #expect(legacy(key(Code.enter, chars: "\r"), modes: modes) == "\r", "a plain Return stays legacy")
        #expect(legacy(key(Code.tab, chars: "\t"), modes: modes) == "\t")
        #expect(legacy(key(Code.backspace, chars: "\u{8}"), modes: modes) == "\u{7f}")
    }

    @Test("under 'disambiguate', Ctrl+letter is CSI codepoint;5 u — no more folded control chars")
    func kittyDisambiguateControl() {
        let modes = kitty(.disambiguate)
        #expect(legacy(key(Code.c, chars: "\u{03}", base: "c", control: true), modes: modes) == "\u{1b}[99;5u")
        #expect(legacy(key(Code.a, chars: "å", base: "a", option: true), modes: modes,
                       optionAsMeta: true) == "\u{1b}[97;3u")
        #expect(legacy(key(Code.a, chars: "a"), modes: modes) == nil, "plain text is still text")
        #expect(legacy(key(Code.a, chars: "{", base: "(", option: true), modes: modes) == nil,
                "⌥ as a compose layer stays with AppKit")
    }

    @Test("under 'disambiguate', ⌥ on a special key is alt whatever the Meta preference")
    func kittyOptionOnSpecialKeys() {
        let modes = kitty(.disambiguate)
        #expect(legacy(key(Code.enter, chars: "\r", option: true), modes: modes) == "\u{1b}[13;3u",
                "⌥↩ still inserts a newline")
        #expect(legacy(key(Code.backspace, chars: "\u{8}", option: true), modes: modes) == "\u{1b}[127;3u",
                "⌥⌫ still deletes a word")
        #expect(legacy(key(Code.left, option: true), modes: modes) == "\u{1b}[1;3D", "⌥← still jumps a word")
    }

    @Test("under 'disambiguate', arrows and function keys keep CSI, with modifiers as usual")
    func kittyDisambiguateNavigation() {
        let modes = kitty(.disambiguate)
        #expect(legacy(key(Code.up), modes: modes) == "\u{1b}[A")
        #expect(legacy(key(Code.up, shift: true), modes: modes) == "\u{1b}[1;2A")
        #expect(legacy(key(Code.f1), modes: modes) == "\u{1b}[P", "never SS3 once the protocol is on")
        #expect(legacy(key(Code.f5, control: true), modes: modes) == "\u{1b}[15;5~")
        let application = TerminalModes(applicationCursorKeys: true, keyboardEnhancement: .disambiguate)
        #expect(legacy(key(Code.up), modes: application) == "\u{1b}[A", "DECCKM is ignored by the protocol")
    }

    @Test("'report all keys' reports plain text as codepoints, with the text when asked")
    func kittyReportAllKeys() {
        #expect(legacy(key(Code.a, chars: "a"), modes: kitty(.reportAllKeys)) == "\u{1b}[97u")
        #expect(legacy(key(Code.a, chars: "a"), modes: kitty([.reportAllKeys, .reportText])) == "\u{1b}[97;;97u")
        #expect(legacy(key(Code.a, chars: "A", base: "A", shift: true),
                       modes: kitty([.reportAllKeys, .reportAlternates])) == "\u{1b}[97:65;2u")
        #expect(legacy(key(Code.enter, chars: "\r"), modes: kitty(.reportAllKeys)) == "\u{1b}[13u")
    }

    @Test("'report events' adds the release and repeat event types")
    func kittyReportEvents() {
        let modes = kitty([.disambiguate, .reportEvents])
        #expect(legacy(key(Code.escape, chars: "\u{1b}"), modes: modes, event: .release) == "\u{1b}[27;1:3u")
        #expect(legacy(key(Code.up), modes: modes, event: .repeat) == "\u{1b}[1;1:2A")
        #expect(legacy(key(Code.enter, chars: "\r"), modes: modes, event: .release) == nil,
                "Return releases are not reported without 'all keys'")
        #expect(legacy(key(Code.escape, chars: "\u{1b}"), modes: kitty(.disambiguate), event: .release) == nil)
    }

    // MARK: - Paste

    @Test("a paste is bracketed only when the program asked, with CR line endings")
    func paste() {
        #expect(KeyTranslator.paste("a\nb", bracketed: true) == "\u{1b}[200~a\rb\u{1b}[201~")
        #expect(KeyTranslator.paste("a\nb", bracketed: false) == "a\rb")
        #expect(KeyTranslator.paste("a\r\nb", bracketed: false) == "a\rb")
        #expect(KeyTranslator.paste("x\u{1b}[201~y", bracketed: true) == "\u{1b}[200~xy\u{1b}[201~",
                "pasted text can never close its own bracket")
    }

    // MARK: - Mac editing shortcuts (⌘), translated to the sequences claude's input
    // understands — matched on the typed character (AZERTY-safe), arrows and
    // backspace on the hardware key code.

    @Test("⌘A selects the whole input: home, then shift-select to the end")
    func commandeToutSelectionner() {
        #expect(KeyTranslator.command(characters: "a", keyCode: 0) == "\u{01}\u{1b}[1;2F")
    }

    @Test("⌘Z undoes (readline undo)")
    func commandeAnnuler() {
        #expect(KeyTranslator.command(characters: "z", keyCode: 6) == "\u{1f}")
    }

    @Test("⌘← / ⌘→ jump to line start / end")
    func commandeDebutFinDeLigne() {
        #expect(KeyTranslator.command(characters: "", keyCode: 123) == "\u{01}")
        #expect(KeyTranslator.command(characters: "", keyCode: 124) == "\u{05}")
    }

    @Test("⌘backspace kills to the line start")
    func commandeEffacerLigne() {
        #expect(KeyTranslator.command(characters: "", keyCode: 51) == "\u{15}")
    }

    @Test("app-level shortcuts are NOT edit shortcuts: nil lets them through")
    func commandeInconnue() {
        #expect(KeyTranslator.command(characters: "k", keyCode: 40) == nil)
        #expect(KeyTranslator.command(characters: "n", keyCode: 45) == nil)
    }
}
