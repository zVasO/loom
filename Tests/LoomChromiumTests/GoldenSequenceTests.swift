import Testing
import LoomChromium
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Seam: the golden sequences of the panel's input. Each case of
// Tests/AgentBrowserCDP/fixtures/panel-sequences.json lists the Swift-side
// events (NSEvent values, what AppKit called back, the agent's turns) and
// the exact DevTools commands they must produce; the CDP harness replays
// those commands against a real Chromium and checks what the page saw.
//
// The replay is the pump's flow: the gate admits, the mapping maps, the
// gate records what went (`didForward`). Event kinds:
//
// - geometry {viewWidth, viewHeight, deviceWidth, deviceHeight} (default: 1280 × 800 at 1:1)
// - mouseDown / mouseUp {x, y, button, clickCount, modifiers}; mouseDragged / mouseMoved {x, y, …};
//   mouseExited; scrollWheel {x, y, dx, dy, precise, modifiers} — view points, y down
// - keyDown {keyCode, characters, charactersIgnoringModifiers?, modifiers, isARepeat?, actions};
//   keyUp {keyCode, characters, …}; flagsChanged {keyCode, modifiers}
// - text {actions} — NSTextInputClient calls outside a keyDown
// - shortcut {keyCode, characters, charactersIgnoringModifiers?, modifiers} — performKeyEquivalent
// - edit {command} — an Edit menu action
// - resign — the page view resigns first responder
// - agentWillAct / agentDidFinish; dialog {open}
//
// An action is {insertText}, {setMarkedText, location, length}, {unmarkText: true} or {doCommand}.

private let sequencesFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AgentBrowserCDP/fixtures/panel-sequences.json")

private struct GoldenCase: Decodable {
    let name: String
    let input: [GoldenEvent]
    let expected: [PanelCDPCommand]
}

private enum GoldenError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let what): return what
        }
    }
}

private struct GoldenAction: Decodable {
    let insertText: String?
    let setMarkedText: String?
    let location: Int?
    let length: Int?
    let unmarkText: Bool?
    let doCommand: String?

    func action() throws -> KeyAction {
        if let insertText { return .insertText(insertText) }
        if let setMarkedText {
            return .setMarkedText(setMarkedText, selectedLocation: location ?? 0, selectedLength: length ?? 0)
        }
        if unmarkText == true { return .unmarkText }
        if let doCommand { return .doCommand(doCommand) }
        throw GoldenError.malformed("an action with nothing to do")
    }
}

private struct GoldenEvent: Decodable {
    let kind: String
    let x: Double?
    let y: Double?
    let button: Int?
    let clickCount: Int?
    let modifiers: Int?
    let dx: Double?
    let dy: Double?
    let precise: Bool?
    let keyCode: Int?
    let characters: String?
    let charactersIgnoringModifiers: String?
    let isARepeat: Bool?
    let actions: [GoldenAction]?
    let command: String?
    let viewWidth: Double?
    let viewHeight: Double?
    let deviceWidth: Double?
    let deviceHeight: Double?
    let open: Bool?

    var cdpModifiers: CDPModifiers {
        CDPModifiers(rawValue: modifiers ?? 0)
    }

    func point() throws -> CGPoint {
        guard let x, let y else { throw GoldenError.malformed("\(kind) without x and y") }
        return CGPoint(x: x, y: y)
    }

    func mouse() throws -> MacMouseEvent {
        MacMouseEvent(location: try point(), buttonNumber: button ?? 0, clickCount: clickCount ?? 1,
                      modifiers: cdpModifiers)
    }

    func press() throws -> MacKeyPress {
        guard let keyCode, keyCode >= 0, keyCode <= Int(UInt16.max) else {
            throw GoldenError.malformed("\(kind) without a keyCode")
        }
        return MacKeyPress(keyCode: UInt16(keyCode), characters: characters ?? "",
                           charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: cdpModifiers,
                           isARepeat: isARepeat ?? false)
    }

    func keyActions() throws -> [KeyAction] {
        try (actions ?? []).map { try $0.action() }
    }
}

/// The pump's flow, without the coalescer (which batches, never changes a
/// command) and without AppKit.
private struct Replayer {
    var gate = UserInputGate(live: true)
    var pointer = UserPointerMapping()
    var keys = UserKeyMapping()
    var geometry = ScreencastGeometry(viewSize: CGSize(width: 1_280, height: 800), device: CGSize(width: 1_280, height: 800))
    var sent: [PanelCDPCommand] = []

    mutating func forward(_ commands: [PanelCDPCommand]) {
        gate.didForward(commands)
        sent.append(contentsOf: commands)
    }

    mutating func play(_ event: GoldenEvent) throws {
        switch event.kind {
        case "geometry":
            guard let width = event.viewWidth, let height = event.viewHeight,
                  let deviceWidth = event.deviceWidth, let deviceHeight = event.deviceHeight else {
                throw GoldenError.malformed("geometry without its sizes")
            }
            geometry = ScreencastGeometry(viewSize: CGSize(width: width, height: height),
                                          device: CGSize(width: deviceWidth, height: deviceHeight))
        case "mouseDown":
            let mouse = try event.mouse()
            // The only place the page view takes the keyboard.
            gate.isFirstResponder = true
            switch pointer.pressTarget(mouse, geometry: geometry) {
            case .outside:
                break
            case .history:
                _ = gate.admit(.panelAction)
            case .page:
                guard let button = mouse.button, gate.admit(.mouseDown(button)) == .forward else { return }
                let commands = pointer.mouseDown(mouse, geometry: geometry)
                forward(commands)
            }
        case "mouseDragged":
            let mouse = try event.mouse()
            guard let button = mouse.button, gate.admit(.mouseDrag(button)) == .forward else { return }
            let commands = pointer.mouseDragged(mouse, geometry: geometry)
            forward(commands)
        case "mouseUp":
            let mouse = try event.mouse()
            guard let button = mouse.button, gate.admit(.mouseUp(button)) == .forward else { return }
            let commands = pointer.mouseUp(mouse, geometry: geometry)
            forward(commands)
        case "mouseMoved":
            let mouse = try event.mouse()
            guard gate.admit(.mouseMove) == .forward else { return }
            let commands = pointer.mouseMoved(mouse, geometry: geometry)
            forward(commands)
        case "mouseExited":
            guard gate.admit(.mouseExited) == .forward else { return }
            let commands = pointer.mouseExited()
            forward(commands)
        case "scrollWheel":
            let scroll = MacScrollEvent(location: try event.point(), delta: CGSize(width: event.dx ?? 0, height: event.dy ?? 0),
                                        precise: event.precise ?? false, modifiers: event.cdpModifiers)
            guard gate.admit(.wheel) == .forward else { return }
            let commands = pointer.wheel(scroll, geometry: geometry)
            forward(commands)
        case "keyDown":
            let press = try event.press()
            let actions = try event.keyActions()
            guard gate.admit(.keyDown(keyCode: press.keyCode)) == .forward else { return }
            let commands = keys.keyDown(press, actions: actions)
            forward(commands)
        case "keyUp":
            let press = try event.press()
            guard gate.admit(.keyUp(keyCode: press.keyCode)) == .forward else { return }
            let commands = keys.keyUp(press)
            forward(commands)
        case "flagsChanged":
            let press = try event.press()
            guard gate.admit(.flagsChanged(keyCode: press.keyCode)) == .forward else { return }
            let commands = keys.flagsChanged(press)
            forward(commands)
        case "text":
            let actions = try event.keyActions()
            guard gate.admit(.text) == .forward else { return }
            let commands = keys.text(actions)
            forward(commands)
        case "shortcut":
            let press = try event.press()
            switch PanelShortcut.classify(press) {
            case .page(let command):
                guard gate.admit(.editCommand) == .forward else { return }
                // Paste is the clipboard bridge's (firePaste, then insertText):
                // never commands:["paste"], which reads Chromium's shared clipboard.
                if command != .paste {
                    forward(command.keyEvents)
                }
            case .panel:
                _ = gate.admit(.panelAction)
            case .leave, .notOurs:
                break
            }
        case "edit":
            guard let name = event.command, let command = PanelEditCommand(rawValue: name) else {
                throw GoldenError.malformed("edit without a known command")
            }
            guard gate.admit(.editCommand) == .forward else { return }
            if command != .paste {
                forward(UserKeyMapping.editCommand(command))
            }
        case "resign":
            gate.isFirstResponder = false
            let committed = keys.commitComposition()
            if gate.isOpen {
                forward(committed)
            }
            guard gate.admit(.mouseExited) == .forward else { return }
            let commands = pointer.mouseExited()
            forward(commands)
        case "agentWillAct":
            let lastPoint = pointer.lastPoint
            let releases = gate.agentWillAct(lastPoint: lastPoint)
            pointer.agentTookOver()
            keys.agentTookOver()
            sent.append(contentsOf: releases)
        case "agentDidFinish":
            gate.agentDidFinish()
        case "dialog":
            gate.pageBlocked = event.open ?? true
        default:
            throw GoldenError.malformed("unknown event kind \(event.kind)")
        }
    }
}

@Suite("Golden sequences — the panel's input as the CDP harness replays it")
struct GoldenSequenceTests {

    private func cases() throws -> [GoldenCase] {
        let data = try Data(contentsOf: sequencesFixture)
        return try JSONDecoder().decode([GoldenCase].self, from: data)
    }

    @Test("every golden sequence maps to exactly its expected commands")
    func sequencesDOr() throws {
        let all = try cases()
        try #require(!all.isEmpty, "panel-sequences.json holds no case")
        for golden in all {
            var replayer = Replayer()
            for event in golden.input {
                try replayer.play(event)
            }
            let sent = replayer.sent
            #expect(sent.count == golden.expected.count, "\(golden.name): \(sent.count) commands")
            for (index, pair) in zip(sent, golden.expected).enumerated() where pair.0 != pair.1 {
                Issue.record("\(golden.name) — command \(index):\n  sent     \(pair.0)\n  expected \(pair.1)")
            }
        }
    }

    @Test("the golden cases have distinct names")
    func nomsDistincts() throws {
        let names = try cases().map { $0.name }
        #expect(Set(names).count == names.count)
    }
}
