import Testing
import LoomChromium
import Foundation

// Seam: the ⌘ allow-list. While the page view is first responder it claims
// the page's edit chords and the panel's own few; everything else stays
// Loom's or the system's.

@Suite("PanelShortcut — whose key equivalent it is")
struct PanelShortcutTests {

    private func chord(_ character: String, _ modifiers: CDPModifiers = [.meta], keyCode: UInt16 = 0) -> PanelShortcut {
        PanelShortcut.classify(MacKeyPress(keyCode: keyCode, characters: character, modifiers: modifiers))
    }

    @Test("⌘C ⌘X ⌘V ⌘A ⌘Z ⌘⇧Z go to the page")
    func pourLaPage() {
        #expect(chord("c", keyCode: 0x08) == .page(.copy))
        #expect(chord("x", keyCode: 0x07) == .page(.cut))
        #expect(chord("v", keyCode: 0x09) == .page(.paste))
        #expect(chord("a", keyCode: 0x00) == .page(.selectAll))
        #expect(chord("z", keyCode: 0x06) == .page(.undo))
        let redo = PanelShortcut.classify(MacKeyPress(keyCode: 0x06, characters: "z", charactersIgnoringModifiers: "Z",
                                                      modifiers: [.meta, .shift]))
        #expect(redo == .page(.redo))
    }

    @Test("⌘L ⌘R ⌘⇧R ⌘[ ⌘] are the panel's: address bar, reload, back, forward")
    func pourLePanneau() {
        #expect(chord("l") == .panel(.focusAddress))
        #expect(chord("r") == .panel(.reload(ignoreCache: false)))
        #expect(chord("R", [.meta, .shift]) == .panel(.reload(ignoreCache: true)))
        #expect(chord("[") == .panel(.back))
        #expect(chord("]") == .panel(.forward))
    }

    @Test("⌃Tab and ⌃⇧Tab leave the page, the keyboard-only way out")
    func sortie() {
        #expect(chord("\t", [.control], keyCode: 0x30) == .leave(forward: true))
        #expect(chord("\t", [.control, .shift], keyCode: 0x30) == .leave(forward: false))
        #expect(chord("\t", [], keyCode: 0x30) == .notOurs, "a plain Tab is the page's, through keyDown")
    }

    @Test("Loom's and the system's chords fall through: ⌘N ⌘T ⌘K ⌘G ⌘, ⌘⇧B ⌘⇧A ⌘W ⌘Q")
    func pasAnous() {
        for character in ["n", "t", "k", "g", ",", "w", "q", "h", "m", "f"] {
            #expect(chord(character) == .notOurs, "⌘\(character)")
        }
        #expect(chord("B", [.meta, .shift]) == .notOurs)
        #expect(chord("A", [.meta, .shift]) == .notOurs)
    }

    @Test("unclaimed chords and other modifiers are not the classifier's: ⌘B reaches keyDown, ⌥⌘C and ⌃C are not copy")
    func autresModificateurs() {
        #expect(chord("b") == .notOurs)
        #expect(chord("c", [.meta, .alt]) == .notOurs)
        #expect(chord("c", [.control]) == .notOurs)
        #expect(chord("c", []) == .notOurs)
    }

    @Test("chords read by character: ⌘A on AZERTY is the key printed A, physical KeyQ")
    func parCaractere() {
        #expect(chord("a", keyCode: 0x0C) == .page(.selectAll))
        #expect(chord("q", keyCode: 0x00) == .notOurs, "⌘Q on AZERTY's KeyA is Quit, Loom's")
    }

    @Test("an edit command's key events: down with the command, then up, both with ⌘")
    func evenementsDEdition() {
        #expect(PanelEditCommand.selectAll.keyEvents == [
            keyCommand("rawKeyDown", key: "a", code: "KeyA", vk: 65, native: 0, modifiers: 4, commands: ["selectAll"]),
            keyCommand("keyUp", key: "a", code: "KeyA", vk: 65, native: 0, modifiers: 4),
        ])
        #expect(PanelEditCommand.cut.keyEvents == [
            keyCommand("rawKeyDown", key: "x", code: "KeyX", vk: 88, native: 7, modifiers: 4, commands: ["cut"]),
            keyCommand("keyUp", key: "x", code: "KeyX", vk: 88, native: 7, modifiers: 4),
        ])
        for command in PanelEditCommand.allCases {
            #expect(command.editingCommands == [command.rawValue])
        }
    }
}
