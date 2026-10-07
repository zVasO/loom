import Testing
import LoomChromium
import Foundation

// Seam: the user's keyboard in the panel → CDP, with Chrome-on-Mac
// semantics: what AppKit's interpretKeyEvents called back (insertText,
// setMarkedText, doCommand…) decides between a key event with text, a
// rawKeyDown with editing commands, a composition and plain text. The
// French examples are the panel design's (§2, Keyboard).

@Suite("UserKeyMapping — the panel's keyboard as CDP")
struct UserKeyMappingTests {

    // MARK: - Typing

    @Test("a: keyDown with its text, KeyA, 65, then its keyUp")
    func lettreA() {
        var mapping = UserKeyMapping()
        let press = MacKeyPress(keyCode: 0x00, characters: "a")
        let down = mapping.keyDown(press, actions: [.insertText("a")])
        // The wire shape, written out once.
        let params: [String: PanelJSON] = [
            "type": "keyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "nativeVirtualKeyCode": 0,
            "modifiers": 0, "text": "a", "unmodifiedText": "a",
        ]
        #expect(down == [PanelCDPCommand(method: "Input.dispatchKeyEvent", params: params)])
        let up = mapping.keyUp(press)
        #expect(up == [keyCommand("keyUp", key: "a", code: "KeyA", vk: 65, native: 0)])
        #expect(mapping.forwardedKeyCodes.isEmpty)
    }

    @Test("AZERTY: the physical KeyQ typing a has keyCode 65")
    func azertyQ() {
        var mapping = UserKeyMapping()
        let down = mapping.keyDown(MacKeyPress(keyCode: 0x0C, characters: "a"), actions: [.insertText("a")])
        #expect(down == [keyCommand("keyDown", key: "a", code: "KeyQ", vk: 65, native: 12, text: "a")])
    }

    @Test("a French dead key: ^ is a composition, e commits ê — no key event, no keyUp")
    func toucheMorte() {
        var mapping = UserKeyMapping()
        let circumflex = MacKeyPress(keyCode: 0x21, characters: "", charactersIgnoringModifiers: "^")
        let marked = mapping.keyDown(circumflex, actions: [.setMarkedText("^", selectedLocation: 1, selectedLength: 0)])
        #expect(marked == [compositionCommand("^", 1, 1)])
        #expect(mapping.composing)
        #expect(mapping.markedText == "^")
        let circumflexUp = mapping.keyUp(circumflex)
        #expect(circumflexUp.isEmpty)
        let e = MacKeyPress(keyCode: 0x0E, characters: "ê", charactersIgnoringModifiers: "e")
        let committed = mapping.keyDown(e, actions: [.insertText("ê")])
        #expect(committed == [insertTextCommand("ê")])
        #expect(!mapping.composing)
        let eUp = mapping.keyUp(e)
        #expect(eUp.isEmpty)
    }

    @Test("⌥( on a French keyboard types {, with modifiers 1 and the key's own keyCode")
    func optionParenthese() {
        var mapping = UserKeyMapping()
        let press = MacKeyPress(keyCode: 0x17, characters: "{", charactersIgnoringModifiers: "(", modifiers: [.alt])
        let down = mapping.keyDown(press, actions: [.insertText("{")])
        #expect(down == [keyCommand("keyDown", key: "{", code: "Digit5", vk: 53, native: 23, modifiers: 1, text: "{")])
    }

    @Test("é on its AZERTY key: text é, Digit2, keyCode 50")
    func eAccentAigu() {
        var mapping = UserKeyMapping()
        let down = mapping.keyDown(MacKeyPress(keyCode: 0x13, characters: "é"), actions: [.insertText("é")])
        #expect(down == [keyCommand("keyDown", key: "é", code: "Digit2", vk: 50, native: 19, text: "é")])
    }

    @Test("text that is not the key's (a text replacement) goes as insertText")
    func remplacement() {
        var mapping = UserKeyMapping()
        let press = MacKeyPress(keyCode: 0x31, characters: " ")
        let commands = mapping.keyDown(press, actions: [.insertText("—")])
        #expect(commands == [insertTextCommand("—")])
        let up = mapping.keyUp(press)
        #expect(up.isEmpty)
    }

    @Test("an auto-repeated key says so")
    func repetition() {
        var mapping = UserKeyMapping()
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x00, characters: "a"), actions: [.insertText("a")])
        let repeated = mapping.keyDown(MacKeyPress(keyCode: 0x00, characters: "a", isARepeat: true),
                                       actions: [.insertText("a")])
        #expect(repeated == [keyCommand("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a",
                                        autoRepeat: true)])
    }

    // MARK: - Commands

    @Test("Enter: keyDown \"\\r\", keyCode 13, no commands")
    func entree() {
        var mapping = UserKeyMapping()
        let down = mapping.keyDown(MacKeyPress(keyCode: 0x24, characters: "\r"), actions: [.doCommand("insertNewline:")])
        #expect(down == [keyCommand("keyDown", key: "Enter", code: "Enter", vk: 13, native: 36, text: "\r")])
    }

    @Test("⌃O opens a line: keyDown \"\\r\" with vk 13, then moveBackward")
    func controleO() {
        var mapping = UserKeyMapping()
        let press = MacKeyPress(keyCode: 0x1F, characters: "\u{F}", charactersIgnoringModifiers: "o", modifiers: [.control])
        let down = mapping.keyDown(press, actions: [.doCommand("insertNewlineIgnoringFieldEditor:"),
                                                    .doCommand("moveBackward:")])
        #expect(down == [keyCommand("keyDown", key: "o", code: "KeyO", vk: 13, native: 31, modifiers: 2, text: "\r",
                                    commands: ["moveBackward"])])
    }

    @Test("⌫ deleteBackward, ⌥⌫ deleteWordBackward")
    func effacement() {
        var mapping = UserKeyMapping()
        let backspace = mapping.keyDown(MacKeyPress(keyCode: 0x33, characters: "\u{7F}"),
                                        actions: [.doCommand("deleteBackward:")])
        #expect(backspace == [keyCommand("rawKeyDown", key: "Backspace", code: "Backspace", vk: 8, native: 51,
                                         commands: ["deleteBackward"])])
        let word = mapping.keyDown(MacKeyPress(keyCode: 0x33, characters: "\u{7F}", modifiers: [.alt]),
                                   actions: [.doCommand("deleteWordBackward:")])
        #expect(word == [keyCommand("rawKeyDown", key: "Backspace", code: "Backspace", vk: 8, native: 51, modifiers: 1,
                                    commands: ["deleteWordBackward"])])
    }

    @Test("⌘← moveToLeftEndOfLine with modifiers 4; ⇧→ moveRightAndModifySelection")
    func fleches() {
        var mapping = UserKeyMapping()
        let lineStart = mapping.keyDown(MacKeyPress(keyCode: 0x7B, characters: "\u{F702}", modifiers: [.meta]),
                                        actions: [.doCommand("moveToLeftEndOfLine:")])
        #expect(lineStart == [keyCommand("rawKeyDown", key: "ArrowLeft", code: "ArrowLeft", vk: 37, native: 123,
                                         modifiers: 4, commands: ["moveToLeftEndOfLine"])])
        let extend = mapping.keyDown(MacKeyPress(keyCode: 0x7C, characters: "\u{F703}", modifiers: [.shift]),
                                     actions: [.doCommand("moveRightAndModifySelection:")])
        #expect(extend == [keyCommand("rawKeyDown", key: "ArrowRight", code: "ArrowRight", vk: 39, native: 124,
                                      modifiers: 8, commands: ["moveRightAndModifySelection"])])
    }

    @Test("Tab and ⇧Tab: rawKeyDown with keyCode 9, insertTab filtered; Escape: rawKeyDown 27")
    func tabulationEtEchap() {
        var mapping = UserKeyMapping()
        let tab = mapping.keyDown(MacKeyPress(keyCode: 0x30, characters: "\t"), actions: [.doCommand("insertTab:")])
        #expect(tab == [keyCommand("rawKeyDown", key: "Tab", code: "Tab", vk: 9, native: 48)])
        let backTab = mapping.keyDown(MacKeyPress(keyCode: 0x30, characters: "\u{19}", charactersIgnoringModifiers: "\t",
                                                  modifiers: [.shift]),
                                      actions: [.doCommand("insertBacktab:")])
        #expect(backTab == [keyCommand("rawKeyDown", key: "Tab", code: "Tab", vk: 9, native: 48, modifiers: 8)])
        let escape = mapping.keyDown(MacKeyPress(keyCode: 0x35, characters: "\u{1B}"),
                                     actions: [.doCommand("cancelOperation:")])
        #expect(escape == [keyCommand("rawKeyDown", key: "Escape", code: "Escape", vk: 27, native: 53,
                                      commands: ["cancelOperation"])])
    }

    @Test("an unclaimed ⌘ chord (noop) is a rawKeyDown with Meta and no command")
    func accordNonReclame() {
        var mapping = UserKeyMapping()
        let down = mapping.keyDown(MacKeyPress(keyCode: 0x0B, characters: "b", modifiers: [.meta]),
                                   actions: [.doCommand("noop:")])
        #expect(down == [keyCommand("rawKeyDown", key: "b", code: "KeyB", vk: 66, native: 11, modifiers: 4)])
    }

    @Test("a key AppKit calls nothing for (F5) is a bare rawKeyDown")
    func toucheDeFonction() {
        var mapping = UserKeyMapping()
        let down = mapping.keyDown(MacKeyPress(keyCode: 0x60, characters: "\u{F708}"), actions: [])
        #expect(down == [keyCommand("rawKeyDown", key: "F5", code: "F5", vk: 116, native: 96)])
    }

    @Test("⌘A, ⌘Z and ⌘⇧Z: the edit command on its key, down then up")
    func commandesDEdition() {
        let selectAll = UserKeyMapping.editCommand(.selectAll)
        #expect(selectAll == [
            keyCommand("rawKeyDown", key: "a", code: "KeyA", vk: 65, native: 0, modifiers: 4, commands: ["selectAll"]),
            keyCommand("keyUp", key: "a", code: "KeyA", vk: 65, native: 0, modifiers: 4),
        ])
        let undo = UserKeyMapping.editCommand(.undo)
        #expect(undo.first == keyCommand("rawKeyDown", key: "z", code: "KeyZ", vk: 90, native: 6, modifiers: 4,
                                         commands: ["undo"]))
        let redo = UserKeyMapping.editCommand(.redo)
        #expect(redo.first == keyCommand("rawKeyDown", key: "z", code: "KeyZ", vk: 90, native: 6, modifiers: 12,
                                         commands: ["redo"]))
        let copy = UserKeyMapping.editCommand(.copy)
        #expect(copy.first == keyCommand("rawKeyDown", key: "c", code: "KeyC", vk: 67, native: 8, modifiers: 4,
                                         commands: ["copy"]))
        #expect(PanelEditCommand.paste.editingCommands == ["paste"])
        #expect(PanelEditCommand.cut.editingCommands == ["cut"])
    }

    @Test("the selector filter: colon dropped, insert* and noop gone")
    func filtreDesSelecteurs() {
        let names = UserKeyMapping.chromiumCommands(selectors: ["insertNewline:", "moveBackward:", "noop:",
                                                                "insertTab:", "deleteWordBackward:", "selectAll"])
        #expect(names == ["moveBackward", "deleteWordBackward", "selectAll"])
    }

    // MARK: - Input methods

    @Test("Japanese: the marked text grows and converts, the commit inserts — never a key event")
    func japonais() {
        var mapping = UserKeyMapping()
        let k = mapping.keyDown(MacKeyPress(keyCode: 0x28, characters: "k"),
                                actions: [.setMarkedText("k", selectedLocation: 1, selectedLength: 0)])
        let ka = mapping.keyDown(MacKeyPress(keyCode: 0x00, characters: "a"),
                                 actions: [.setMarkedText("か", selectedLocation: 1, selectedLength: 0)])
        let converted = mapping.keyDown(MacKeyPress(keyCode: 0x31, characters: " "),
                                        actions: [.setMarkedText("蚊", selectedLocation: 0, selectedLength: 1)])
        // An arrow the input method keeps for its candidates: nothing reaches the page.
        let eaten = mapping.keyDown(MacKeyPress(keyCode: 0x7D, characters: "\u{F701}"), actions: [])
        let committed = mapping.keyDown(MacKeyPress(keyCode: 0x24, characters: "\r"), actions: [.insertText("蚊")])
        #expect(k == [compositionCommand("k", 1, 1)])
        #expect(ka == [compositionCommand("か", 1, 1)])
        #expect(converted == [compositionCommand("蚊", 0, 1)])
        #expect(eaten.isEmpty)
        #expect(committed == [insertTextCommand("蚊")])
        #expect(mapping.forwardedKeyCodes.isEmpty)
        #expect(!mapping.composing)
    }

    @Test("a selection past the marked text, or NSNotFound, stays inside it")
    func selectionBornee() {
        var mapping = UserKeyMapping()
        let past = mapping.text([.setMarkedText("ab", selectedLocation: NSNotFound, selectedLength: 0)])
        #expect(past == [compositionCommand("ab", 2, 2)])
        let long = mapping.text([.setMarkedText("abc", selectedLocation: 1, selectedLength: 99)])
        #expect(long == [compositionCommand("abc", 1, 3)])
    }

    @Test("insertText outside a keyDown (the emoji picker, dictation) is inserted; a command alone is dropped")
    func texteHorsTouche() {
        var mapping = UserKeyMapping()
        let emoji = mapping.text([.insertText("😀")])
        #expect(emoji == [insertTextCommand("😀")])
        let command = mapping.text([.doCommand("deleteBackward:")])
        #expect(command.isEmpty)
    }

    @Test("losing focus with marked text commits it")
    func perteDuFocus() {
        var mapping = UserKeyMapping()
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x21, characters: "", charactersIgnoringModifiers: "^"),
                            actions: [.setMarkedText("^", selectedLocation: 1, selectedLength: 0)])
        let committed = mapping.commitComposition()
        #expect(committed == [insertTextCommand("^")])
        let again = mapping.commitComposition()
        #expect(again.isEmpty)
    }

    // MARK: - Ups and modifiers

    @Test("a keyUp goes only after a forwarded keyDown")
    func keyUpApparie() {
        var mapping = UserKeyMapping()
        let orphan = mapping.keyUp(MacKeyPress(keyCode: 0x00, characters: "a"))
        #expect(orphan.isEmpty)
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x24, characters: "\r"), actions: [.doCommand("insertNewline:")])
        let up = mapping.keyUp(MacKeyPress(keyCode: 0x24, characters: "\r"))
        #expect(up == [keyCommand("keyUp", key: "Enter", code: "Enter", vk: 13, native: 36)])
        let twice = mapping.keyUp(MacKeyPress(keyCode: 0x24, characters: "\r"))
        #expect(twice.isEmpty)
    }

    @Test("flagsChanged: ShiftLeft down and up; MetaRight is 92, location 2")
    func modificateurs() {
        var mapping = UserKeyMapping()
        let shiftDown = mapping.flagsChanged(MacKeyPress(keyCode: 0x38, modifiers: [.shift]))
        let metaDown = mapping.flagsChanged(MacKeyPress(keyCode: 0x36, modifiers: [.shift, .meta]))
        let metaUp = mapping.flagsChanged(MacKeyPress(keyCode: 0x36, modifiers: [.shift]))
        let shiftUp = mapping.flagsChanged(MacKeyPress(keyCode: 0x38, modifiers: []))
        #expect(shiftDown == [keyCommand("rawKeyDown", key: "Shift", code: "ShiftLeft", vk: 16, native: 56, modifiers: 8,
                                         location: 1)])
        #expect(metaDown == [keyCommand("rawKeyDown", key: "Meta", code: "MetaRight", vk: 92, native: 54, modifiers: 12,
                                        location: 2)])
        #expect(metaUp == [keyCommand("keyUp", key: "Meta", code: "MetaRight", vk: 92, native: 54, modifiers: 8,
                                      location: 2)])
        #expect(shiftUp == [keyCommand("keyUp", key: "Shift", code: "ShiftLeft", vk: 16, native: 56, location: 1)])
        // The release of a Control pressed before the page had the keys.
        let stray = mapping.flagsChanged(MacKeyPress(keyCode: 0x3B, modifiers: []))
        #expect(stray.isEmpty)
    }

    @Test("Caps Lock goes down when the lock engages, up when it releases")
    func verrouillageMajuscules() {
        var mapping = UserKeyMapping()
        let on = mapping.flagsChanged(MacKeyPress(keyCode: 0x39))
        let off = mapping.flagsChanged(MacKeyPress(keyCode: 0x39))
        #expect(on == [keyCommand("rawKeyDown", key: "CapsLock", code: "CapsLock", vk: 20, native: 57)])
        #expect(off == [keyCommand("keyUp", key: "CapsLock", code: "CapsLock", vk: 20, native: 57)])
    }

    @Test("Command's up brings up the keys pressed under it first: AppKit never sends their keyUp")
    func relacheSousCommande() {
        var mapping = UserKeyMapping()
        _ = mapping.flagsChanged(MacKeyPress(keyCode: 0x37, modifiers: [.meta]))
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x7B, characters: "\u{F702}", modifiers: [.meta]),
                            actions: [.doCommand("moveToLeftEndOfLine:")])
        #expect(mapping.pressedUnderCommand == [0x7B])
        let commandUp = mapping.flagsChanged(MacKeyPress(keyCode: 0x37, modifiers: []))
        #expect(commandUp == [
            keyCommand("keyUp", key: "ArrowLeft", code: "ArrowLeft", vk: 37, native: 123, modifiers: 4),
            keyCommand("keyUp", key: "Meta", code: "MetaLeft", vk: 91, native: 55, location: 1),
        ])
        let late = mapping.keyUp(MacKeyPress(keyCode: 0x7B, characters: "\u{F702}"))
        #expect(late.isEmpty)
    }

    @Test("⌃A: AppKit's moveToBeginningOfParagraph on key a, keyCode 65")
    func controleA() {
        var mapping = UserKeyMapping()
        let press = MacKeyPress(keyCode: 0x00, characters: "\u{1}", charactersIgnoringModifiers: "a", modifiers: [.control])
        let down = mapping.keyDown(press, actions: [.doCommand("moveToBeginningOfParagraph:")])
        #expect(down == [keyCommand("rawKeyDown", key: "a", code: "KeyA", vk: 65, native: 0, modifiers: 2,
                                    commands: ["moveToBeginningOfParagraph"])])
    }

    @Test("the agent took over: nothing is held or marked any more")
    func repriseParLAgent() {
        var mapping = UserKeyMapping()
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x00, characters: "a"), actions: [.insertText("a")])
        _ = mapping.keyDown(MacKeyPress(keyCode: 0x21, characters: "", charactersIgnoringModifiers: "^"),
                            actions: [.setMarkedText("^", selectedLocation: 1, selectedLength: 0)])
        mapping.agentTookOver()
        #expect(mapping.forwardedKeyCodes.isEmpty)
        #expect(!mapping.composing)
        let up = mapping.keyUp(MacKeyPress(keyCode: 0x00, characters: "a"))
        #expect(up.isEmpty)
    }
}
