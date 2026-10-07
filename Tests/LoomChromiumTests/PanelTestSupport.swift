import LoomChromium
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The panel's expected commands, written out param by param — the wire
// shape the golden sequences (Tests/AgentBrowserCDP/fixtures/
// panel-sequences.json) hold and the CDP harness replays.

/// An `Input.dispatchKeyEvent` as the panel sends it.
func keyCommand(_ type: String, key: String, code: String, vk: Int, native: Int, modifiers: Int = 0,
                text: String? = nil, commands: [String] = [], location: Int = 0,
                autoRepeat: Bool = false) -> PanelCDPCommand {
    var params: [String: PanelJSON] = [
        "type": .string(type), "key": .string(key), "code": .string(code),
        "windowsVirtualKeyCode": .number(Double(vk)), "nativeVirtualKeyCode": .number(Double(native)),
        "modifiers": .number(Double(modifiers)),
    ]
    if let text {
        params["text"] = .string(text)
        params["unmodifiedText"] = .string(text)
    }
    if location != 0 { params["location"] = .number(Double(location)) }
    if location == 3 { params["isKeypad"] = .bool(true) }
    if autoRepeat { params["autoRepeat"] = .bool(true) }
    if !commands.isEmpty { params["commands"] = .array(commands.map { PanelJSON.string($0) }) }
    return PanelCDPCommand(method: "Input.dispatchKeyEvent", params: params)
}

/// An `Input.dispatchMouseEvent` move, press or release.
func mouseCommand(_ type: String, x: Double, y: Double, button: String = "none", buttons: Int = 0,
                  modifiers: Int = 0, clickCount: Int? = nil) -> PanelCDPCommand {
    var params: [String: PanelJSON] = [
        "type": .string(type), "x": .number(x), "y": .number(y), "button": .string(button),
        "buttons": .number(Double(buttons)), "modifiers": .number(Double(modifiers)), "pointerType": "mouse",
    ]
    if let clickCount { params["clickCount"] = .number(Double(clickCount)) }
    return PanelCDPCommand(method: "Input.dispatchMouseEvent", params: params)
}

func wheelCommand(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: Int = 0) -> PanelCDPCommand {
    PanelCDPCommand(method: "Input.dispatchMouseEvent", params: [
        "type": "mouseWheel", "x": .number(x), "y": .number(y), "deltaX": .number(deltaX), "deltaY": .number(deltaY),
        "modifiers": .number(Double(modifiers)), "pointerType": "mouse",
    ])
}

func insertTextCommand(_ text: String) -> PanelCDPCommand {
    PanelCDPCommand(method: "Input.insertText", params: ["text": .string(text)])
}

func compositionCommand(_ text: String, _ start: Int, _ end: Int) -> PanelCDPCommand {
    PanelCDPCommand(method: "Input.imeSetComposition", params: [
        "text": .string(text), "selectionStart": .number(Double(start)), "selectionEnd": .number(Double(end)),
    ])
}

/// 640 × 400 points showing a 1280 × 800 page: half a point per CSS pixel,
/// so view (100, 50) is page (200, 100) — every product exact in binary.
let halfScaleGeometry = ScreencastGeometry(viewSize: CGSize(width: 640, height: 400),
                                           device: CGSize(width: 1_280, height: 800))

/// 600 × 800 points showing a page pinned at 1280 × 720: the picture is
/// (0, 231.25, 600, 337.5), with a letterbox above and below.
let letterboxGeometry = ScreencastGeometry(viewSize: CGSize(width: 600, height: 800),
                                           device: CGSize(width: 1_280, height: 720))
