import Testing
import LoomChromium
import Foundation

// Seam: the panel's commands as values — from CDPInput's tuples, back to
// what CDPConnection.post(batch:) writes, and through the golden files'
// JSON.

@Suite("PanelCDP — the panel's commands as values")
struct PanelCDPTests {

    @Test("a CDPInput tuple becomes a value; whole numbers go back as Int, fractions as Double")
    func depuisCDPInput() {
        let command = PanelCDPCommand(CDPInput.mousePressed(x: 120.5, y: 48, button: .right, clickCount: 2,
                                                            modifiers: [.shift]))
        #expect(command == mouseCommand("mousePressed", x: 120.5, y: 48, button: "right", buttons: 2, modifiers: 8,
                                        clickCount: 2))
        #expect(command.type == "mousePressed")
        let back = command.cdpCommand
        #expect(back.0 == "Input.dispatchMouseEvent")
        #expect(back.1["x"] as? Double == 120.5)
        #expect(back.1["y"] as? Int == 48)
        #expect(back.1["buttons"] as? Int == 2)
        #expect(back.1["clickCount"] as? Int == 2)
        #expect(back.1["button"] as? String == "right")
    }

    @Test("Bools stay Bools and a commands array survives the trip")
    func boolsEtTableaux() {
        let keypad = CDPKey(key: "1", code: "Numpad1", keyCode: 97, text: "1", location: 3)
        let down = PanelCDPCommand(CDPInput.keyDown(keypad, autoRepeat: true))
        #expect(down.params["isKeypad"] == .bool(true))
        #expect(down.params["autoRepeat"] == .bool(true))
        let selectAll = PanelCDPCommand(CDPInput.keyDown(CDPKey(key: "a", code: "KeyA", keyCode: 65, modifiers: .meta)))
        #expect(selectAll.params["commands"] == .array([.string("selectAll")]))
        let back = selectAll.cdpCommand.1
        #expect(back["commands"] as? [String] == ["selectAll"])
        #expect(down.cdpCommand.1["isKeypad"] as? Bool == true)
    }

    @Test("the bridged params are valid JSON, integers written without a fraction")
    func jsonValide() throws {
        let batch = PanelCDPCommand.cdpBatch([
            mouseCommand("mouseMoved", x: 200, y: 100),
            keyCommand("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a"),
        ])
        #expect(batch.map { $0.0 } == ["Input.dispatchMouseEvent", "Input.dispatchKeyEvent"])
        let data = try JSONSerialization.data(withJSONObject: batch[1].1, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"windowsVirtualKeyCode\":65"), "\(text)")
        #expect(!text.contains("65.0"), "\(text)")
    }

    @Test("the golden files' shape decodes; a missing params is empty; 65 and 65.0 are one number")
    func decodage() throws {
        let json = #"[{"method":"Input.insertText","params":{"text":"é"}},{"method":"Page.stopLoading"}]"#
        let commands = try JSONDecoder().decode([PanelCDPCommand].self, from: Data(json.utf8))
        #expect(commands == [insertTextCommand("é"), PanelCDPCommand(method: "Page.stopLoading")])
        let number = try JSONDecoder().decode(PanelJSON.self, from: Data("65".utf8))
        #expect(number == .number(65.0))
        #expect(number.intValue == 65)
        #expect(PanelJSON.number(65.5).intValue == nil)
        let flag = try JSONDecoder().decode(PanelJSON.self, from: Data("true".utf8))
        #expect(flag == .bool(true))
    }

    @Test("a command survives encoding and decoding")
    func allerRetour() throws {
        let original = keyCommand("rawKeyDown", key: "ArrowLeft", code: "ArrowLeft", vk: 37, native: 123, modifiers: 4,
                                  commands: ["moveToLeftEndOfLine"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PanelCDPCommand.self, from: data)
        #expect(decoded == original)
    }

    @Test("the builders: insertText and imeSetComposition as Chromium names them")
    func constructeurs() {
        #expect(PanelCDPCommand.insertText("ê") == insertTextCommand("ê"))
        #expect(PanelCDPCommand.imeSetComposition("^", selectionStart: 1, selectionEnd: 1) == compositionCommand("^", 1, 1))
        let identity = KeyIdentity(key: "Shift", code: "ShiftRight", windowsKeyCode: 16, location: 2)
        let up = PanelCDPCommand.keyEvent(.keyUp, identity, nativeKeyCode: 0x3C, modifiers: [])
        #expect(up == keyCommand("keyUp", key: "Shift", code: "ShiftRight", vk: 16, native: 60, location: 2))
    }

    @Test("a value JSON cannot hold is left out of the params")
    func horsJSON() {
        let command = PanelCDPCommand(("X.y", ["kept": 1, "dropped": Date()]))
        #expect(command.params == ["kept": .number(1)])
    }
}
