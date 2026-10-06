import Testing
import LoomChromium
import Foundation

// Seam: the exact Input.* commands trusted input sends. The golden
// dictionaries are what the step-0 probe sent to get isTrusted events, the
// full pointer sequence, a form submitted by Enter, native Tab traversal
// and the Mac editing commands.

@Suite("CDPInput — trusted input as DevTools commands")
struct CDPInputTests {

    private let mouse = "Input.dispatchMouseEvent"
    private let key = "Input.dispatchKeyEvent"

    /// The command is exactly `method` with `expected` (numbers compare by
    /// value). Compared outside #expect: the literal keeps its type.
    private func expectCommand(_ command: (String, [String: Any]), _ method: String, _ expected: [String: Any]) {
        let matches = command.0 == method && (command.1 as NSDictionary).isEqual(expected as NSDictionary)
        let shown = json(command)
        #expect(matches, "\(shown)")
    }

    private func json(_ command: (String, [String: Any])) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: command.1, options: [.sortedKeys]) else {
            return command.0
        }
        return command.0 + " " + String(decoding: data, as: UTF8.self)
    }

    private func shown(_ commands: [(String, [String: Any])]) -> String {
        commands.map { json($0) }.joined(separator: "\n")
    }

    // MARK: - Mouse

    @Test("a click is move, press, release — one write, button bits, pointerType mouse")
    func clic() {
        let events = CDPInput.click(x: 120.5, y: 48)
        let count = events.count
        #expect(count == 3)
        guard count == 3 else { return }
        expectCommand(events[0], mouse, ["type": "mouseMoved", "x": 120.5, "y": 48, "button": "none", "buttons": 0,
                                         "modifiers": 0, "pointerType": "mouse"])
        expectCommand(events[1], mouse, ["type": "mousePressed", "x": 120.5, "y": 48, "button": "left", "buttons": 1,
                                         "clickCount": 1, "modifiers": 0, "pointerType": "mouse"])
        expectCommand(events[2], mouse, ["type": "mouseReleased", "x": 120.5, "y": 48, "button": "left", "buttons": 0,
                                         "clickCount": 1, "modifiers": 0, "pointerType": "mouse"])
    }

    @Test("a double click is a second write: press and release with clickCount 2, no move")
    func doubleClic() {
        let writes = CDPInput.clicks(x: 10, y: 20, clickCount: 2)
        let sizes = writes.map { $0.count }
        #expect(sizes == [3, 2])
        guard sizes == [3, 2] else { return }
        expectCommand(writes[1][0], mouse, ["type": "mousePressed", "x": 10, "y": 20, "button": "left", "buttons": 1,
                                            "clickCount": 2, "modifiers": 0, "pointerType": "mouse"])
        expectCommand(writes[1][1], mouse, ["type": "mouseReleased", "x": 10, "y": 20, "button": "left", "buttons": 0,
                                            "clickCount": 2, "modifiers": 0, "pointerType": "mouse"])
        let triple = CDPInput.clicks(x: 1, y: 1, clickCount: 3)
        let tripleSizes = triple.map { $0.count }
        #expect(tripleSizes == [3, 2, 2])
        if tripleSizes == [3, 2, 2] {
            let third = triple[2][0].1["clickCount"] as? Int
            #expect(third == 3)
        }
        let single = CDPInput.clicks(x: 1, y: 1, clickCount: 1)
        #expect(single.count == 1)
    }

    @Test("a right click with modifiers: its button, bit 2, the modifiers mask on every event")
    func clicDroit() {
        let modifiers: CDPModifiers = [.shift, .alt]
        let events = CDPInput.click(x: 5, y: 6, button: .right, modifiers: modifiers)
        guard events.count == 3 else {
            Issue.record("three events")
            return
        }
        expectCommand(events[0], mouse, ["type": "mouseMoved", "x": 5, "y": 6, "button": "none", "buttons": 0,
                                         "modifiers": 9, "pointerType": "mouse"])
        expectCommand(events[1], mouse, ["type": "mousePressed", "x": 5, "y": 6, "button": "right", "buttons": 2,
                                         "clickCount": 1, "modifiers": 9, "pointerType": "mouse"])
        expectCommand(events[2], mouse, ["type": "mouseReleased", "x": 5, "y": 6, "button": "right", "buttons": 0,
                                         "clickCount": 1, "modifiers": 9, "pointerType": "mouse"])
    }

    @Test("modifier bits: Alt 1, Control 2, Meta 4, Shift 8; button bits as MouseEvent.buttons")
    func bitsDeModificateurs() {
        #expect(CDPModifiers.alt.rawValue == 1)
        #expect(CDPModifiers.control.rawValue == 2)
        #expect(CDPModifiers.meta.rawValue == 4)
        #expect(CDPModifiers.shift.rawValue == 8)
        let middle = CDPMouseButton.middle.mask.rawValue
        let back = CDPMouseButton.back.mask.rawValue
        let forward = CDPMouseButton.forward.mask.rawValue
        #expect(middle == 4)
        #expect(back == 8)
        #expect(forward == 16)
    }

    @Test("a drag: the move reports the button held; a press keeps the others' bits")
    func glisser() {
        let left: CDPMouseButtons = .left
        let both: CDPMouseButtons = [.left, .right]
        expectCommand(CDPInput.mouseMoved(x: 1, y: 2, held: left), mouse,
                      ["type": "mouseMoved", "x": 1, "y": 2, "button": "left", "buttons": 1, "modifiers": 0,
                       "pointerType": "mouse"])
        expectCommand(CDPInput.mousePressed(x: 1, y: 2, button: .right, held: left), mouse,
                      ["type": "mousePressed", "x": 1, "y": 2, "button": "right", "buttons": 3, "clickCount": 1,
                       "modifiers": 0, "pointerType": "mouse"])
        expectCommand(CDPInput.mouseReleased(x: 1, y: 2, button: .right, held: both), mouse,
                      ["type": "mouseReleased", "x": 1, "y": 2, "button": "right", "buttons": 1, "clickCount": 1,
                       "modifiers": 0, "pointerType": "mouse"])
    }

    @Test("the wheel scrolls by its deltas over a point")
    func molette() {
        expectCommand(CDPInput.mouseWheel(x: 400, y: 400, deltaX: 0, deltaY: 300), mouse,
                      ["type": "mouseWheel", "x": 400, "y": 400, "deltaX": 0, "deltaY": 300,
                       "modifiers": 0, "pointerType": "mouse"])
    }

    // MARK: - Keys

    @Test("Enter is keyDown with text \\r (the only one that submits), then keyUp; no insert command")
    func entree() {
        let events = CDPInput.keyPress(CDPKey(key: "Enter", code: "Enter", keyCode: 13))
        guard events.count == 2 else {
            Issue.record("down and up: \(shown(events))")
            return
        }
        expectCommand(events[0], key, ["type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                                       "nativeVirtualKeyCode": 13, "modifiers": 0, "text": "\r", "unmodifiedText": "\r"])
        expectCommand(events[1], key, ["type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                                       "nativeVirtualKeyCode": 13, "modifiers": 0])
        let typed = CDPKey(key: "Enter", code: "Enter", keyCode: 13, text: "\n").typedText
        #expect(typed == "\r", "whatever text it was given")
    }

    @Test("Tab types nothing: rawKeyDown, so focus moves natively")
    func tabulation() {
        let events = CDPInput.keyPress(CDPKey(key: "Tab", code: "Tab", keyCode: 9))
        guard events.count == 2 else {
            Issue.record("down and up: \(shown(events))")
            return
        }
        expectCommand(events[0], key, ["type": "rawKeyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9,
                                       "nativeVirtualKeyCode": 9, "modifiers": 0])
    }

    @Test("Shift+Tab: Shift goes down carrying itself, comes up without")
    func majTab() {
        let events = CDPInput.keyPress(CDPKey(key: "Tab", code: "Tab", keyCode: 9, modifiers: .shift))
        guard events.count == 4 else {
            Issue.record("Shift down, Tab down, Tab up, Shift up: \(shown(events))")
            return
        }
        expectCommand(events[0], key, ["type": "rawKeyDown", "key": "Shift", "code": "ShiftLeft", "windowsVirtualKeyCode": 16,
                                       "nativeVirtualKeyCode": 16, "modifiers": 8, "location": 1])
        expectCommand(events[1], key, ["type": "rawKeyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9,
                                       "nativeVirtualKeyCode": 9, "modifiers": 8])
        expectCommand(events[2], key, ["type": "keyUp", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9,
                                       "nativeVirtualKeyCode": 9, "modifiers": 8])
        expectCommand(events[3], key, ["type": "keyUp", "key": "Shift", "code": "ShiftLeft", "windowsVirtualKeyCode": 16,
                                       "nativeVirtualKeyCode": 16, "modifiers": 0, "location": 1])
    }

    @Test("ControlOrMeta+a on a Mac: Meta around a textless a carrying selectAll")
    func toutSelectionner() {
        let events = CDPInput.keyPress(CDPKey(key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: .meta))
        guard events.count == 4 else {
            Issue.record("Meta down, a down, a up, Meta up: \(shown(events))")
            return
        }
        expectCommand(events[0], key, ["type": "rawKeyDown", "key": "Meta", "code": "MetaLeft", "windowsVirtualKeyCode": 91,
                                       "nativeVirtualKeyCode": 91, "modifiers": 4, "location": 1])
        expectCommand(events[1], key, ["type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 4, "commands": ["selectAll"]])
        expectCommand(events[2], key, ["type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 4])
        expectCommand(events[3], key, ["type": "keyUp", "key": "Meta", "code": "MetaLeft", "windowsVirtualKeyCode": 91,
                                       "nativeVirtualKeyCode": 91, "modifiers": 0, "location": 1])
    }

    @Test("Shift+Control+Alt+Meta go down in that order and come up in reverse")
    func ordreDesModificateurs() {
        let all: CDPModifiers = [.meta, .alt, .control, .shift]
        let events = CDPInput.keyPress(CDPKey(key: "b", code: "KeyB", keyCode: 66, text: "b", modifiers: all))
        let keys = events.map { $0.1["key"] as? String ?? "?" }
        let types = events.map { $0.1["type"] as? String ?? "?" }
        let masks = events.map { $0.1["modifiers"] as? Int ?? -1 }
        #expect(keys == ["Shift", "Control", "Alt", "Meta", "b", "b", "Meta", "Alt", "Control", "Shift"])
        #expect(types == ["rawKeyDown", "rawKeyDown", "rawKeyDown", "rawKeyDown", "rawKeyDown", "keyUp",
                          "keyUp", "keyUp", "keyUp", "keyUp"])
        #expect(masks == [8, 10, 11, 15, 15, 15, 11, 10, 8, 0])
    }

    @Test("a plain a types a and carries no command (Chromium would run one whatever the modifiers)")
    func lettreSimple() {
        let events = CDPInput.keyPress(CDPKey(key: "a", code: "KeyA", keyCode: 65, text: "a"))
        guard events.count == 2 else {
            Issue.record("down and up: \(shown(events))")
            return
        }
        expectCommand(events[0], key, ["type": "keyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 0, "text": "a", "unmodifiedText": "a"])
    }

    @Test("A is Shift and a capital, its text included")
    func majuscule() {
        let events = CDPInput.keyPress(CDPKey(key: "A", code: "KeyA", keyCode: 65, text: "A", modifiers: .shift))
        guard events.count == 4 else {
            Issue.record("Shift around A: \(shown(events))")
            return
        }
        expectCommand(events[1], key, ["type": "keyDown", "key": "A", "code": "KeyA", "windowsVirtualKeyCode": 65,
                                       "nativeVirtualKeyCode": 65, "modifiers": 8, "text": "A", "unmodifiedText": "A"])
    }

    @Test("Alt+a is a shortcut: no text")
    func altLettre() {
        expectCommand(CDPInput.keyDown(CDPKey(key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: .alt)), key,
                      ["type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                       "nativeVirtualKeyCode": 65, "modifiers": 1])
    }

    @Test("é and an emoji have no key: they are inserted as text")
    func caracteresSansTouche() {
        let accent = CDPInput.typing(CDPKey(key: "é", code: "", keyCode: 0, text: "é"))
        #expect(accent.count == 1)
        if let first = accent.first {
            expectCommand(first, "Input.insertText", ["text": "é"])
        }
        let emoji = CDPInput.typing(CDPKey(key: "🙂", code: "", keyCode: 0, text: "🙂"))
        if let first = emoji.first {
            expectCommand(first, "Input.insertText", ["text": "🙂"])
        }
        let letter = CDPInput.typing(CDPKey(key: "b", code: "KeyB", keyCode: 66, text: "b"))
        #expect(letter.count == 2, "a key the layout has is pressed")
    }

    @Test("Backspace on a Mac carries deleteBackward; off a Mac, no commands at all")
    func retourArriere() {
        let backspace = CDPKey(key: "Backspace", code: "Backspace", keyCode: 8)
        expectCommand(CDPInput.keyDown(backspace), key,
                      ["type": "rawKeyDown", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8,
                       "nativeVirtualKeyCode": 8, "modifiers": 0, "commands": ["deleteBackward"]])
        let other = CDPInput.keyDown(backspace, mac: false)
        let hasCommands = other.1.keys.contains("commands")
        #expect(!hasCommands)
    }

    @Test("a numpad key says where it is")
    func paveNumerique() {
        expectCommand(CDPInput.keyDown(CDPKey(key: "1", code: "Numpad1", keyCode: 97, text: "1", location: 3)), key,
                      ["type": "keyDown", "key": "1", "code": "Numpad1", "windowsVirtualKeyCode": 97,
                       "nativeVirtualKeyCode": 97, "modifiers": 0, "text": "1", "unmodifiedText": "1",
                       "location": 3, "isKeypad": true])
    }

    @Test("an auto-repeated key says so")
    func repetition() {
        let down = CDPInput.keyDown(CDPKey(key: "ArrowDown", code: "ArrowDown", keyCode: 40), autoRepeat: true)
        let repeated = down.1["autoRepeat"] as? Bool
        let commands = down.1["commands"] as? [String]
        #expect(repeated == true)
        #expect(commands == ["moveDown"])
    }

    // MARK: - Mac editing commands

    @Test("the Mac table: copy, cut, paste, undo, redo on Meta; the shortcut's modifier order")
    func tableMac() {
        let meta: CDPModifiers = .meta
        let shiftMeta: CDPModifiers = [.shift, .meta]
        let copy = MacEditingCommands.commands(code: "KeyC", modifiers: meta)
        let cut = MacEditingCommands.commands(code: "KeyX", modifiers: meta)
        let paste = MacEditingCommands.commands(code: "KeyV", modifiers: meta)
        let undo = MacEditingCommands.commands(code: "KeyZ", modifiers: meta)
        let redo = MacEditingCommands.commands(code: "KeyZ", modifiers: shiftMeta)
        let selectAll = MacEditingCommands.commands(code: "KeyA", modifiers: meta)
        #expect(copy == ["copy"])
        #expect(cut == ["cut"])
        #expect(paste == ["paste"])
        #expect(undo == ["undo"])
        #expect(redo == ["redo"])
        #expect(selectAll == ["selectAll"])

        let every: CDPModifiers = [.meta, .alt, .control, .shift]
        let shortcut = MacEditingCommands.shortcut(code: "KeyB", modifiers: every)
        #expect(shortcut == "Shift+Control+Alt+Meta+KeyB")
        let wordBack = MacEditingCommands.commands(code: "KeyB", modifiers: [.shift, .control, .alt])
        #expect(wordBack == ["moveWordBackwardAndModifySelection"])
    }

    @Test("insert* commands are dropped, several commands kept in order, the colon stripped")
    func filtreInsert() {
        let control: CDPModifiers = .control
        let alt: CDPModifiers = .alt
        let none: CDPModifiers = []
        let raw = MacEditingCommands.table["Control+KeyO"]
        #expect(raw == ["insertNewlineIgnoringFieldEditor:", "moveBackward:"])
        let controlO = MacEditingCommands.commands(code: "KeyO", modifiers: control)
        let enter = MacEditingCommands.commands(code: "Enter", modifiers: none)
        let controlTab = MacEditingCommands.commands(code: "Tab", modifiers: control)
        let altUp = MacEditingCommands.commands(code: "ArrowUp", modifiers: alt)
        let altBackspace = MacEditingCommands.commands(code: "Backspace", modifiers: alt)
        let controlE = MacEditingCommands.commands(code: "KeyE", modifiers: control)
        let metaQ = MacEditingCommands.commands(code: "KeyQ", modifiers: .meta)
        let plainA = MacEditingCommands.commands(code: "KeyA", modifiers: none)
        #expect(controlO == ["moveBackward"])
        #expect(enter.isEmpty)
        #expect(controlTab == ["selectNextKeyView"])
        #expect(altUp == ["moveBackward", "moveToBeginningOfParagraph"])
        #expect(altBackspace == ["deleteWordBackward"])
        #expect(controlE == ["moveToEndOfParagraph"])
        #expect(metaQ.isEmpty, "unlisted: nothing")
        #expect(plainA.isEmpty, "a letter alone: nothing")
        let size = MacEditingCommands.table.count
        #expect(size == 114)
        let colons = MacEditingCommands.table.values.allSatisfy { selectors in
            selectors.allSatisfy { $0.hasSuffix(":") }
        }
        #expect(colons)
    }

    // MARK: - Text, IME, batching

    @Test("insertText and the IME's composition")
    func texteEtIME() {
        expectCommand(CDPInput.insertText("Buy milk"), "Input.insertText", ["text": "Buy milk"])
        expectCommand(CDPInput.imeSetComposition("^", selectionStart: 1, selectionEnd: 1), "Input.imeSetComposition",
                      ["text": "^", "selectionStart": 1, "selectionEnd": 1])
        expectCommand(CDPInput.imeSetComposition("ê", selectionStart: 1, selectionEnd: 1, replacementStart: 0,
                                                 replacementEnd: 1), "Input.imeSetComposition",
                      ["text": "ê", "selectionStart": 1, "selectionEnd": 1, "replacementStart": 0, "replacementEnd": 1])
        expectCommand(CDPInput.imeCancel(), "Input.imeSetComposition", ["text": "", "selectionStart": 0, "selectionEnd": 0])
    }

    @Test("type slowly goes in writes of 8 keys (16 events)")
    func fenetres() {
        var commands: [(String, [String: Any])] = []
        for character in "Buy milk and eggs 42" {
            let text = String(character)
            commands += CDPInput.typing(CDPKey(key: text, code: "", keyCode: 1, text: text), mac: false)
        }
        #expect(commands.count == 40)
        let sizes = CDPInput.writes(commands).map { $0.count }
        #expect(sizes == [16, 16, 8])
        let empty = CDPInput.writes([], size: 16)
        #expect(empty.isEmpty)
        let ones = CDPInput.writes(commands, size: 0)
        #expect(ones.count == 40, "a size under 1 is one per write")
    }
}
