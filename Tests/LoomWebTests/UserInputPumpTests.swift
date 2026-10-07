import Testing
import AppKit
import CoreGraphics
import Foundation
import LoomChromium
@testable import LoomWeb

// Seam: the person's input in the Chromium panel, between the page view and
// the tab's session (panel design §2–§3). The pump runs on fakes — a wire
// that records what would be written (and answers the tracked move at
// once), a host that answers the panel script's ops, a pasteboard — so the
// golden sequences of Tests/AgentBrowserCDP/fixtures/panel-sequences.json
// replay through it exactly as GoldenSequenceTests' Replayer replays them,
// and the flows it adds (a press's probe, paste, copy, the <select> menu,
// the agent's takeover) are checked command by command. No window, no
// Chromium.

/// Everything in the order it happened: written commands and host queries.
@MainActor
private final class Journal {
    var entries: [String] = []
}

@MainActor
private final class RecordingWire: PanelInputWire {
    let journal: Journal
    var sent: [PanelCDPCommand] = []
    var drains = 0

    init(journal: Journal) {
        self.journal = journal
    }

    func write(_ commands: [PanelCDPCommand]) {
        for command in commands {
            record(command)
        }
    }

    func track(_ command: PanelCDPCommand, replied: @escaping @MainActor @Sendable () -> Void) {
        record(command)
        replied()
    }

    func drain(within limit: Duration) async {
        drains += 1
    }

    private func record(_ command: PanelCDPCommand) {
        sent.append(command)
        journal.entries.append(command.method + (command.type.map { " " + $0 } ?? ""))
    }
}

@MainActor
private final class FakeHost: UserInputPumpHost {
    let journal: Journal
    var answers: [String: PanelJSON] = [:]
    var queries: [(op: String, arg: PanelJSON)] = []
    var notices: [String] = []
    var acted: [BrowserTabsModel.TabID] = []
    var actions: [PanelAction] = []

    init(journal: Journal) {
        self.journal = journal
    }

    func panelQuery(_ op: String, _ arg: PanelJSON, on tab: BrowserTabsModel.TabID,
                    timeout: Duration) async -> PanelJSON? {
        queries.append((op, arg))
        journal.entries.append("query " + op)
        return answers[op]
    }

    func noteUserActed(on tab: BrowserTabsModel.TabID) {
        acted.append(tab)
    }

    func showInputNotice(_ text: String) {
        notices.append(text)
    }

    func performPanelAction(_ action: PanelAction) {
        actions.append(action)
    }
}

@MainActor
private final class FakePasteboard: PanelPasteboard {
    var text: String?

    func string() -> String? {
        text
    }

    func setString(_ text: String) {
        self.text = text
    }
}

@MainActor
private final class FakeViewer: UserInputPumpViewer {
    var choice: Int?
    var menus: [SelectMenuModel] = []
    var compositionsEnded = 0
    /// While the menu is up: the page may change under it.
    var whileMenuIsUp: (@MainActor () -> Void)?

    func pumpCursorChanged(_ kind: CursorKind) {}

    func pumpCompositionEnded() {
        compositionsEnded += 1
    }

    func pumpChoose(from menu: SelectMenuModel, completion: @escaping @MainActor (Int?) -> Void) {
        menus.append(menu)
        whileMenuIsUp?()
        completion(choice)
    }
}

/// A pump on a live page, its fakes held here (it keeps them weakly).
@MainActor
private final class Rig {
    let journal: Journal
    let wire: RecordingWire
    let host: FakeHost
    let pasteboard: FakePasteboard
    let viewer: FakeViewer
    let pump: UserInputPump
    let tab: BrowserTabsModel.TabID

    init(withViewer: Bool = false) {
        journal = Journal()
        wire = RecordingWire(journal: journal)
        host = FakeHost(journal: journal)
        pasteboard = FakePasteboard()
        viewer = FakeViewer()
        tab = BrowserTabsModel.TabID(rawValue: UUID())
        pump = UserInputPump(pasteboard: pasteboard)
        pump.host = host
        if withViewer {
            pump.viewer = viewer
        }
        // A press first asks what is under it: an ordinary element.
        host.answers["hitInfo"] = ["cursor": "auto", "editable": false, "link": false]
        pump.attach(wire, tab: tab)
    }

    /// The commands written whose `params.commands` name `name`.
    func commandsNaming(_ name: String) -> [PanelCDPCommand] {
        wire.sent.filter { command in
            command.params["commands"]?.arrayValue?.contains(.string(name)) == true
        }
    }
}

// The wire shape, param by param.

private func mouse(_ type: String, x: Double, y: Double, button: String = "none", buttons: Int = 0,
                   clickCount: Int? = nil) -> PanelCDPCommand {
    var params: [String: PanelJSON] = [
        "type": .string(type), "x": .number(x), "y": .number(y), "button": .string(button),
        "buttons": .number(Double(buttons)), "modifiers": 0, "pointerType": "mouse",
    ]
    if let clickCount { params["clickCount"] = .number(Double(clickCount)) }
    return PanelCDPCommand(method: "Input.dispatchMouseEvent", params: params)
}

private func key(_ type: String, key: String, code: String, vk: Int, native: Int, modifiers: Int = 0,
                 text: String? = nil, commands: [String] = []) -> PanelCDPCommand {
    var params: [String: PanelJSON] = [
        "type": .string(type), "key": .string(key), "code": .string(code),
        "windowsVirtualKeyCode": .number(Double(vk)), "nativeVirtualKeyCode": .number(Double(native)),
        "modifiers": .number(Double(modifiers)),
    ]
    if let text {
        params["text"] = .string(text)
        params["unmodifiedText"] = .string(text)
    }
    if !commands.isEmpty { params["commands"] = .array(commands.map { PanelJSON.string($0) }) }
    return PanelCDPCommand(method: "Input.dispatchKeyEvent", params: params)
}

private func insertText(_ text: String) -> PanelCDPCommand {
    PanelCDPCommand(method: "Input.insertText", params: ["text": .string(text)])
}

/// 640 × 400 points showing a 1280 × 800 page: view (100, 50) is page (200, 100).
private let halfScale = ScreencastGeometry(viewSize: CGSize(width: 640, height: 400),
                                           device: CGSize(width: 1_280, height: 800))

private func leftClick(_ x: CGFloat, _ y: CGFloat, count: Int = 1) -> MacMouseEvent {
    MacMouseEvent(location: CGPoint(x: x, y: y), buttonNumber: 0, clickCount: count)
}

private let aKey = MacKeyPress(keyCode: 0, characters: "a")

// MARK: - The golden sequences, through the pump

private let sequencesFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AgentBrowserCDP/fixtures/panel-sequences.json")

private struct GoldenCase: Decodable {
    let name: String
    let input: [GoldenEvent]
    let expected: [PanelCDPCommand]
}

private struct GoldenAction: Decodable {
    let insertText: String?
    let setMarkedText: String?
    let location: Int?
    let length: Int?
    let unmarkText: Bool?
    let doCommand: String?

    var action: KeyAction? {
        if let insertText { return .insertText(insertText) }
        if let setMarkedText {
            return .setMarkedText(setMarkedText, selectedLocation: location ?? 0, selectedLength: length ?? 0)
        }
        if unmarkText == true { return .unmarkText }
        if let doCommand { return .doCommand(doCommand) }
        return nil
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

    var mouse: MacMouseEvent {
        MacMouseEvent(location: CGPoint(x: x ?? 0, y: y ?? 0), buttonNumber: button ?? 0,
                      clickCount: clickCount ?? 1, modifiers: CDPModifiers(rawValue: modifiers ?? 0))
    }

    var press: MacKeyPress {
        MacKeyPress(keyCode: UInt16(clamping: keyCode ?? 0), characters: characters ?? "",
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifiers: CDPModifiers(rawValue: modifiers ?? 0), isARepeat: isARepeat ?? false)
    }

    var keyActions: [KeyAction] {
        (actions ?? []).compactMap { $0.action }
    }
}

@MainActor
private func replayThroughPump(_ golden: GoldenCase) async -> [PanelCDPCommand] {
    let rig = Rig()
    var geometry = ScreencastGeometry(viewSize: CGSize(width: 1_280, height: 800),
                                      device: CGSize(width: 1_280, height: 800))
    for event in golden.input {
        switch event.kind {
        case "geometry":
            geometry = ScreencastGeometry(viewSize: CGSize(width: event.viewWidth ?? 0, height: event.viewHeight ?? 0),
                                          device: CGSize(width: event.deviceWidth ?? 0, height: event.deviceHeight ?? 0))
        case "mouseDown":
            rig.pump.mouseDown(event.mouse, geometry: geometry)
        case "mouseDragged":
            rig.pump.mouseDragged(event.mouse, geometry: geometry)
        case "mouseUp":
            rig.pump.mouseUp(event.mouse, geometry: geometry)
        case "mouseMoved":
            rig.pump.mouseMoved(event.mouse, geometry: geometry)
        case "mouseExited":
            rig.pump.mouseExited()
        case "scrollWheel":
            let scroll = MacScrollEvent(location: CGPoint(x: event.x ?? 0, y: event.y ?? 0),
                                        delta: CGSize(width: event.dx ?? 0, height: event.dy ?? 0),
                                        precise: event.precise ?? false,
                                        modifiers: CDPModifiers(rawValue: event.modifiers ?? 0))
            rig.pump.scrollWheel(scroll, geometry: geometry)
        case "keyDown":
            rig.pump.keyDown(event.press, actions: event.keyActions)
        case "keyUp":
            rig.pump.keyUp(event.press)
        case "flagsChanged":
            rig.pump.flagsChanged(event.press)
        case "text":
            rig.pump.text(event.keyActions)
        case "shortcut":
            switch PanelShortcut.classify(event.press) {
            case .page(let command): rig.pump.editCommand(command)
            case .panel(let action): rig.pump.panelAction(action)
            case .leave, .notOurs: break
            }
        case "edit":
            if let command = event.command.flatMap(PanelEditCommand.init(rawValue:)) {
                rig.pump.editCommand(command)
            } else {
                Issue.record("\(golden.name): edit without a known command")
            }
        case "resign":
            rig.pump.resign()
        case "agentWillAct":
            rig.pump.agentWillAct()
        case "agentDidFinish":
            rig.pump.agentDidFinish()
        case "dialog":
            rig.pump.setPageBlocked(event.open ?? true)
        default:
            Issue.record("\(golden.name): unknown event kind \(event.kind)")
        }
        // Real time: a press's probe answers before the next event comes.
        await rig.pump.waitForFlows()
    }
    return rig.wire.sent
}

@Suite("UserInputPump — the person's input through the gate, the mappings and the coalescer")
@MainActor
struct UserInputPumpTests {

    @Test("every golden sequence goes through the pump exactly as the Replayer sends it")
    func sequencesDOr() async throws {
        let data = try Data(contentsOf: sequencesFixture)
        let cases = try JSONDecoder().decode([GoldenCase].self, from: data)
        try #require(!cases.isEmpty)
        for golden in cases {
            let sent = await replayThroughPump(golden)
            #expect(sent.count == golden.expected.count, "\(golden.name): \(sent.count) commands")
            for (index, pair) in zip(sent, golden.expected).enumerated() where pair.0 != pair.1 {
                Issue.record("\(golden.name) — command \(index):\n  sent     \(pair.0)\n  expected \(pair.1)")
            }
        }
    }

    @Test("a click: the page is asked what is under the press, then move, press and release go in order")
    func clic() async {
        let rig = Rig()
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        // The release comes while the probe is out: it waits behind it.
        rig.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        let beforeAnswer = rig.wire.sent.count
        #expect(beforeAnswer == 0)
        await rig.pump.waitForFlows()
        let expected = [
            mouse("mouseMoved", x: 200, y: 100),
            mouse("mousePressed", x: 200, y: 100, button: "left", buttons: 1, clickCount: 1),
            mouse("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1),
        ]
        #expect(rig.wire.sent == expected)
        let probe = rig.host.queries.first
        let pressPoint: PanelJSON = ["x": 200, "y": 100]
        #expect(probe?.op == "hitInfo")
        #expect(probe?.arg == pressPoint)
        #expect(rig.journal.entries.first == "query hitInfo")
    }

    @Test("a double click, a right click or a modified click is not probed: it goes at once")
    func sansSonde() {
        let rig = Rig()
        rig.pump.mouseDown(leftClick(100, 50, count: 2), geometry: halfScale)
        let doubled = rig.wire.sent.count
        #expect(doubled == 2, "move and press, no wait")
        rig.pump.mouseDown(MacMouseEvent(location: CGPoint(x: 10, y: 10), buttonNumber: 1), geometry: halfScale)
        rig.pump.mouseDown(MacMouseEvent(location: CGPoint(x: 20, y: 10), modifiers: .control), geometry: halfScale)
        #expect(rig.host.queries.isEmpty)
    }

    @Test("typing with a dead key: ^ then e is a composition, then ê — no key event, no keyUp")
    func toucheMorte() {
        let rig = Rig()
        let circumflex = MacKeyPress(keyCode: 33, characters: "", charactersIgnoringModifiers: "^")
        rig.pump.keyDown(circumflex, actions: [.setMarkedText("^", selectedLocation: 1, selectedLength: 0)])
        rig.pump.keyUp(circumflex)
        let e = MacKeyPress(keyCode: 14, characters: "ê", charactersIgnoringModifiers: "e")
        rig.pump.keyDown(e, actions: [.insertText("ê")])
        rig.pump.keyUp(MacKeyPress(keyCode: 14, characters: "e"))
        let expected = [
            PanelCDPCommand(method: "Input.imeSetComposition",
                            params: ["text": "^", "selectionStart": 1, "selectionEnd": 1]),
            insertText("ê"),
        ]
        #expect(rig.wire.sent == expected)
        #expect(rig.host.acted == [rig.tab], "the agent hears of it once")
    }

    @Test("the agent takes over mid-drag: the button comes up at the last point, the release after is dropped, keys wait")
    func repriseEnPleinGlisser() async {
        let rig = Rig()
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        rig.pump.mouseDragged(MacMouseEvent(location: CGPoint(x: 300, y: 50)), geometry: halfScale)
        rig.pump.agentWillAct()
        let release = rig.wire.sent.last
        #expect(release == mouse("mouseReleased", x: 600, y: 100, button: "left", buttons: 0, clickCount: 1))
        let sentAtTakeover = rig.wire.sent.count

        rig.pump.mouseUp(MacMouseEvent(location: CGPoint(x: 310, y: 50)), geometry: halfScale)
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let whileRunning = rig.wire.sent.count
        #expect(whileRunning == sentAtTakeover, "nothing of the person's reaches the page while the agent acts")
        #expect(rig.host.notices == [UserInputGate.Notice.agentRunning.text])

        // A second command queued behind the first: still the agent's.
        rig.pump.agentWillAct()
        rig.pump.agentDidFinish()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let afterFirst = rig.wire.sent.count
        #expect(afterFirst == sentAtTakeover)

        rig.pump.agentDidFinish()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let typed = rig.wire.sent.last
        #expect(typed == key("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a"))
    }

    @Test("a command already in the core shuts the gate before its takeover reaches the main actor")
    func repriseAvantLeFilPrincipal() async {
        let rig = Rig()
        var busy = false
        rig.pump.agentBusy = { busy }
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        busy = true
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let release = rig.wire.sent.last
        #expect(release == mouse("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1),
                "the held button comes up, the key does not go")
        #expect(rig.host.notices == [UserInputGate.Notice.agentRunning.text])

        // The takeover lands, then the command's end: the person's turn again.
        rig.pump.agentWillAct()
        busy = false
        rig.pump.agentDidFinish()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let typed = rig.wire.sent.last
        #expect(typed == key("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a"))
    }

    @Test("the agent takes over mid-composition: the composition is cancelled and the view drops its marked text")
    func repriseEnComposition() {
        let rig = Rig(withViewer: true)
        rig.pump.keyDown(MacKeyPress(keyCode: 33, characters: "", charactersIgnoringModifiers: "^"),
                         actions: [.setMarkedText("^", selectedLocation: 1, selectedLength: 0)])
        rig.pump.agentWillAct()
        let cancel = rig.wire.sent.last
        #expect(cancel == PanelCDPCommand(method: "Input.imeSetComposition",
                                          params: ["text": "", "selectionStart": 0, "selectionEnd": 0]))
        #expect(rig.viewer.compositionsEnded == 1)
    }

    @Test("paste: the Mac's text goes to firePaste, then Input.insertText — never a paste command — and keys wait for it")
    func coller() async {
        let rig = Rig()
        rig.pasteboard.text = "hello"
        rig.host.answers["firePaste"] = ["cancelled": false]
        rig.pump.editCommand(.paste)
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let beforePaste = rig.wire.sent.count
        #expect(beforePaste == 0, "the key typed after ⌘V waits for the paste")
        await rig.pump.waitForFlows()

        let firePaste = rig.host.queries.first { $0.op == "firePaste" }
        let offered: PanelJSON = ["text": "hello"]
        #expect(firePaste?.arg == offered)
        #expect(rig.journal.entries == ["query firePaste", "Input.insertText", "Input.dispatchKeyEvent keyDown"])
        #expect(rig.wire.sent.first == insertText("hello"))
        #expect(rig.commandsNaming("paste").isEmpty)
        #expect(rig.wire.drains == 1, "the keys before ⌘V are answered first")
    }

    @Test("paste: a page that cancels the event keeps the text to itself; no answer inserts nothing, with a notice")
    func collerAnnule() async {
        let cancelled = Rig()
        cancelled.pasteboard.text = "123456"
        cancelled.host.answers["firePaste"] = ["cancelled": true]
        cancelled.pump.editCommand(.paste)
        await cancelled.pump.waitForFlows()
        #expect(cancelled.wire.sent.isEmpty)
        #expect(cancelled.host.notices.isEmpty)

        let silent = Rig()
        silent.pasteboard.text = "123456"
        silent.pump.editCommand(.paste)
        await silent.pump.waitForFlows()
        #expect(silent.wire.sent.isEmpty)
        #expect(silent.host.notices == [PanelClipboard.pasteRefused])

        let empty = Rig()
        empty.pump.editCommand(.paste)
        await empty.pump.waitForFlows()
        #expect(empty.host.queries.isEmpty, "nothing on the pasteboard: nothing asked")
    }

    @Test("a key binding of the person's own naming paste: the key goes without Chromium's paste command")
    func liaisonColler() {
        let rig = Rig()
        let controlV = MacKeyPress(keyCode: 9, characters: "\u{16}", charactersIgnoringModifiers: "v", modifiers: .control)
        rig.pump.keyDown(controlV, actions: [.doCommand("paste:")])
        #expect(rig.commandsNaming("paste").isEmpty)
        let types = rig.wire.sent.map { $0.type }
        #expect(types == ["rawKeyDown"])
    }

    @Test("copy: ⌘C with its copy command, then takeCopied — a fresh copy reaches the pasteboard, a stale one does not")
    func copier() async {
        let rig = Rig()
        rig.host.answers["takeCopied"] = ["text": "copied words", "type": "copy", "ageMs": 12]
        rig.pump.editCommand(.copy)
        await rig.pump.waitForFlows()
        let expected = [
            key("rawKeyDown", key: "c", code: "KeyC", vk: 67, native: 8, modifiers: 4, commands: ["copy"]),
            key("keyUp", key: "c", code: "KeyC", vk: 67, native: 8, modifiers: 4),
        ]
        #expect(rig.wire.sent == expected)
        #expect(rig.journal.entries.last == "query takeCopied")
        #expect(rig.pasteboard.text == "copied words")

        let stale = Rig()
        stale.host.answers["takeCopied"] = ["text": "old", "type": "copy", "ageMs": 1_500]
        stale.pump.editCommand(.cut)
        await stale.pump.waitForFlows()
        #expect(stale.pasteboard.text == nil)
        #expect(stale.commandsNaming("cut").count == 1)
    }

    @Test("a <select> under a plain press: no press reaches the page, the Mac menu's choice goes through chooseUserSelect")
    func listeDeroulante() async {
        let rig = Rig(withViewer: true)
        rig.host.answers["hitInfo"] = selectInfo(open: false)
        rig.viewer.choice = 2
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        rig.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        #expect(rig.wire.sent.isEmpty, "neither the press nor its release: Chromium's popup would show in no frame")
        #expect(rig.viewer.menus.count == 1)
        let chosen = rig.host.queries.filter { $0.op == "chooseUserSelect" }
        #expect(chosen.count == 1)
        let third: PanelJSON = ["index": 2]
        #expect(chosen.first?.arg == third)
        #expect(rig.host.acted == [rig.tab])
    }

    @Test("a <select> whose own popup is open already: Escape closes it before the menu")
    func listeDejaOuverte() async {
        let rig = Rig(withViewer: true)
        rig.host.answers["hitInfo"] = selectInfo(open: true)
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        let expected = [
            key("rawKeyDown", key: "Escape", code: "Escape", vk: 27, native: 53),
            key("keyUp", key: "Escape", code: "Escape", vk: 27, native: 53),
        ]
        #expect(rig.wire.sent == expected)
        let chooses = rig.host.queries.filter { $0.op == "chooseUserSelect" }
        #expect(chooses.isEmpty, "the menu was closed without a choice")
    }

    @Test("a press whose probe came late goes as it is; its release looks again and bridges a popup it opened")
    func sondeEnRetard() async {
        let rig = Rig(withViewer: true)
        rig.host.answers["hitInfo"] = nil
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        let pressed = rig.wire.sent.map { $0.type }
        #expect(pressed == ["mouseMoved", "mousePressed"])
        rig.host.answers["hitInfo"] = selectInfo(open: true)
        rig.viewer.choice = 0
        rig.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        let types = rig.wire.sent.map { $0.type }
        #expect(types == ["mouseMoved", "mousePressed", "mouseReleased", "rawKeyDown", "keyUp"])
        let chosen = rig.host.queries.filter { $0.op == "chooseUserSelect" }
        let first: PanelJSON = ["index": 0]
        #expect(chosen.first?.arg == first)
    }

    @Test("another page under the panel: what was held there is forgotten, nothing waits")
    func autrePage() async {
        let rig = Rig()
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        let next = RecordingWire(journal: rig.journal)
        rig.pump.attach(next, tab: BrowserTabsModel.TabID(rawValue: UUID()))
        rig.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        #expect(next.sent.isEmpty, "the new page never saw that press")
        rig.pump.attach(nil, tab: nil)
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        #expect(next.sent.isEmpty)
        #expect(rig.host.notices.isEmpty, "no page: dropped silently")
    }

    @Test("the agent hears of the person's input once per gap between its commands, per tab")
    func uneLigneParIntervalle() async {
        let rig = Rig()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        #expect(rig.host.acted.count == 1)
        rig.pump.agentWillAct()
        rig.pump.agentDidFinish()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        #expect(rig.host.acted.count == 2)
    }

    @Test("a dialog blocks presses and keys with its notice; the panel's ⌘L always focuses the bar")
    func dialogueEtBarre() {
        let rig = Rig()
        rig.pump.setPageBlocked(true)
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        rig.pump.panelAction(.reload(ignoreCache: false))
        rig.pump.panelAction(.focusAddress)
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.host.notices == [UserInputGate.Notice.pageBlocked.text, UserInputGate.Notice.pageBlocked.text])
        #expect(rig.host.actions == [.focusAddress])
        #expect(!rig.pump.canPerform(.copy))
    }

    @Test("the core still running the agent's command keeps the gate shut past the command's return")
    func coeurOccupe() {
        let rig = Rig()
        rig.pump.agentWillAct()
        rig.pump.setAgentRunningInCore(true)
        // The core's backstop answered the caller; the job still runs.
        rig.pump.agentDidFinish()
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let whileRunning = rig.wire.sent.count
        #expect(whileRunning == 0)
        #expect(rig.host.notices == [UserInputGate.Notice.agentRunning.text])
        rig.pump.setAgentRunningInCore(false)
        rig.pump.keyDown(aKey, actions: [.insertText("a")])
        let typed = rig.wire.sent.last
        #expect(typed == key("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a"))
    }

    @Test("the core running a command the pump was not told of: the person's button comes up, the gate shuts")
    func coeurSansPreavis() async {
        let rig = Rig()
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        rig.pump.setAgentRunningInCore(true)
        let release = rig.wire.sent.last
        #expect(release == mouse("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1))
        let afterTakeover = rig.wire.sent.count
        rig.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        let afterRelease = rig.wire.sent.count
        #expect(afterRelease == afterTakeover, "its own release finds nothing held")
    }

    @Test("a press, or a paste, made before the agent acted sends nothing once its flow resumes after the command")
    func fluxPerime() async {
        let pressed = Rig()
        pressed.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        pressed.pump.mouseUp(leftClick(100, 50), geometry: halfScale)
        pressed.pump.keyDown(aKey, actions: [.insertText("a")])
        // The probe has not run yet: a whole agent command comes and goes.
        pressed.pump.agentWillAct()
        pressed.pump.agentDidFinish()
        await pressed.pump.waitForFlows()
        #expect(pressed.wire.sent.isEmpty, "neither the press, its release, nor the key typed behind it")

        let pasted = Rig()
        pasted.pasteboard.text = "secret"
        pasted.host.answers["firePaste"] = ["cancelled": false]
        pasted.pump.editCommand(.paste)
        pasted.pump.agentWillAct()
        pasted.pump.agentDidFinish()
        await pasted.pump.waitForFlows()
        #expect(pasted.wire.sent.isEmpty)
        let fired = pasted.host.queries.filter { $0.op == "firePaste" }
        #expect(fired.isEmpty, "the page never had the paste event")
        #expect(pasted.host.acted.isEmpty, "nothing reached the page: nothing to tell the agent")
    }

    @Test("a <select> gone from under the menu: the choice is not applied to whatever is there now")
    func listeDisparue() async {
        let rig = Rig(withViewer: true)
        rig.host.answers["hitInfo"] = selectInfo(open: false)
        rig.viewer.choice = 1
        let host = rig.host
        rig.viewer.whileMenuIsUp = {
            host.answers["hitInfo"] = ["cursor": "auto", "editable": false, "link": false]
        }
        rig.pump.mouseDown(leftClick(100, 50), geometry: halfScale)
        await rig.pump.waitForFlows()
        let hits = rig.host.queries.filter { $0.op == "hitInfo" }
        #expect(hits.count == 2, "the probe, then a second look before the choice")
        let chosen = rig.host.queries.filter { $0.op == "chooseUserSelect" }
        #expect(chosen.isEmpty)
        #expect(rig.host.acted.isEmpty)
    }

    private func selectInfo(open: Bool) -> PanelJSON {
        let rect: PanelJSON = ["x": 10, "y": 20, "width": 120, "height": 24]
        let one: PanelJSON = ["label": "One", "value": "1", "disabled": false]
        let two: PanelJSON = ["label": "Two", "value": "2", "disabled": false]
        let three: PanelJSON = ["label": "Three", "value": "3", "disabled": false]
        let select: PanelJSON = [
            "rect": rect, "options": .array([one, two, three]),
            "selectedIndex": 0, "multiple": false, "disabled": false, "size": 0, "open": .bool(open),
        ]
        return ["cursor": "default", "editable": false, "link": false, "select": select]
    }
}

// MARK: - The <select> menu's model

@Suite("SelectMenuBridge — a <select> from hitInfo as a Mac menu")
struct SelectMenuModelTests {

    private func info(_ select: PanelJSON) -> PanelJSON {
        ["cursor": "default", "editable": false, "link": false, "select": select]
    }

    private let plain: PanelJSON = ["label": "Plain", "value": "p", "disabled": false]
    private let red: PanelJSON = ["label": "Red", "value": "r", "disabled": false, "group": "Colours"]
    private let blue: PanelJSON = ["label": "Blue", "value": "b", "disabled": true, "group": "Colours"]
    private let small: PanelJSON = ["label": "Small", "value": "s", "disabled": false, "group": "Sizes"]

    private var options: PanelJSON {
        .array([plain, red, blue, small])
    }

    @Test("optgroups become disabled headers, their options indented, the current one checked")
    func modele() throws {
        let select: PanelJSON = [
            "rect": ["x": 8, "y": 30.5, "width": 140, "height": 22],
            "options": options, "selectedIndex": 2, "multiple": false, "disabled": false, "size": 0, "open": false,
        ]
        let model = try #require(SelectMenuModel(hitInfo: info(select)))
        #expect(model.rect == CGRect(x: 8, y: 30.5, width: 140, height: 22))
        #expect(model.open == false)
        let titles = model.entries.map { $0.title }
        #expect(titles == ["Plain", "Colours", "Red", "Blue", "Sizes", "Small"])
        let kinds = model.entries.map { $0.kind }
        #expect(kinds == [.option(index: 0), .header, .option(index: 1), .option(index: 2), .header, .option(index: 3)])
        #expect(model.entries.map { $0.enabled } == [true, false, true, false, false, true])
        #expect(model.entries.map { $0.checked } == [false, false, false, true, false, false])
        #expect(model.entries.map { $0.indented } == [false, false, true, true, false, true])
    }

    @Test("a list box, a multiple or a disabled select, an empty one, or no select at all: no menu")
    func pasDeMenu() {
        let base: [String: PanelJSON] = [
            "rect": ["x": 0, "y": 0, "width": 100, "height": 20],
            "options": options, "selectedIndex": 0, "multiple": false, "disabled": false, "size": 0, "open": false,
        ]
        var listBox = base
        listBox["size"] = 4
        var multiple = base
        multiple["multiple"] = true
        var disabled = base
        disabled["disabled"] = true
        var empty = base
        empty["options"] = []
        for select in [listBox, multiple, disabled, empty] {
            #expect(SelectMenuModel(hitInfo: info(.object(select))) == nil)
        }
        #expect(SelectMenuModel(hitInfo: ["cursor": "auto", "editable": false, "link": false]) == nil)
        #expect(SelectMenuModel(hitInfo: ["error": ["code": "invalid", "message": "x"]]) == nil)
        #expect(SelectMenuModel(hitInfo: .object(["select": .object(base)])) != nil, "the one-line select itself")
    }

    @Test("only a plain left press is probed; Escape is a rawKeyDown and keyUp of keyCode 27")
    func sondeEtEchap() {
        #expect(SelectMenuBridge.probes(MacMouseEvent(location: .zero)))
        #expect(!SelectMenuBridge.probes(MacMouseEvent(location: .zero, clickCount: 2)))
        #expect(!SelectMenuBridge.probes(MacMouseEvent(location: .zero, buttonNumber: 1)))
        #expect(!SelectMenuBridge.probes(MacMouseEvent(location: .zero, modifiers: .shift)))
        let escape = SelectMenuBridge.escapeKeys
        #expect(escape.map { $0.type } == ["rawKeyDown", "keyUp"])
        #expect(escape.allSatisfy { $0.params["windowsVirtualKeyCode"] == 27 && $0.params["commands"] == nil })
    }

    @Test("the NSMenu: headers disabled, options tagged with their index, the current one on")
    @MainActor
    func menuMac() throws {
        let select: PanelJSON = [
            "rect": ["x": 0, "y": 0, "width": 100, "height": 20],
            "options": options, "selectedIndex": 3, "multiple": false, "disabled": false, "size": 1, "open": false,
        ]
        let model = try #require(SelectMenuModel(hitInfo: info(select)))
        let target = SelectMenuChoice { _ in }
        let menu = SelectMenuBridge.menu(for: model, target: target, action: #selector(SelectMenuChoice.choose(_:)))
        #expect(menu.items.count == 6)
        #expect(menu.items[1].isEnabled == false)
        #expect(menu.items[1].action == nil)
        #expect(menu.items[5].tag == 3)
        #expect(menu.items[5].state == .on)
        #expect(menu.items[3].isEnabled == false, "a disabled option stays disabled")
        #expect(menu.items[2].indentationLevel == 1)
    }
}

// MARK: - Clipboard and answers, pure

@Suite("PanelClipboard — what the page's answers mean")
struct PanelClipboardTests {

    @Test("takeCopied: text under a second old goes to the pasteboard; stale, empty, null or an error does not")
    func copie() {
        #expect(PanelClipboard.copiedText(["text": "x", "type": "copy", "ageMs": 999]) == "x")
        #expect(PanelClipboard.copiedText(["text": "x", "type": "copy", "ageMs": 1_000]) == nil)
        #expect(PanelClipboard.copiedText(["text": "", "type": "cut", "ageMs": 3]) == nil)
        #expect(PanelClipboard.copiedText(.null) == nil)
        #expect(PanelClipboard.copiedText(nil) == nil)
        #expect(PanelClipboard.copiedText(["error": ["code": "failed", "message": "x"]]) == nil)
    }

    @Test("firePaste: typed unless cancelled — never without an answer")
    func collage() {
        #expect(PanelClipboard.insertsAfterPaste(["cancelled": false]))
        #expect(!PanelClipboard.insertsAfterPaste(["cancelled": true]))
        #expect(!PanelClipboard.insertsAfterPaste(nil))
        #expect(!PanelClipboard.insertsAfterPaste(["error": ["code": "panelMissing", "message": "x"]]))
    }

    @Test("hitInfo's cursor: CSSCursor's kind, auto read through editable and link; caretRect's box")
    func curseurEtCaret() {
        #expect(UserInputPump.cursorKind(hitInfo: ["cursor": "pointer", "editable": false, "link": false]) == .pointingHand)
        #expect(UserInputPump.cursorKind(hitInfo: ["cursor": "auto", "editable": true, "link": false]) == .iBeam)
        #expect(UserInputPump.cursorKind(hitInfo: ["cursor": "auto", "editable": false, "link": true]) == .pointingHand)
        #expect(UserInputPump.cursorKind(hitInfo: ["error": ["code": "invalid", "message": "x"]]) == nil)
        #expect(UserInputPump.rect(["x": 1, "y": 2.5, "width": 0, "height": 18]) == CGRect(x: 1, y: 2.5, width: 0, height: 18))
        #expect(UserInputPump.rect(.null) == nil)
        let cursorArguments: PanelJSON = ["x": 3, "y": 4, "select": false]
        #expect(UserInputPump.hitArguments(CGPoint(x: 3, y: 4), select: false) == cursorArguments)
    }
}

// MARK: - NSEvent → the mappings' values

@Suite("NSEvent+Panel — AppKit's events as the panel's mappings read them")
@MainActor
struct NSEventPanelTests {

    @Test("a keyDown: key code, characters with and without modifiers, ⌘⇧ as Meta and Shift, the repeat flag")
    func touche() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: "Z",
                                                  charactersIgnoringModifiers: "z", isARepeat: true, keyCode: 6))
        let press = event.panelKeyPress
        #expect(press == MacKeyPress(keyCode: 6, characters: "Z", charactersIgnoringModifiers: "z",
                                     modifiers: [.meta, .shift], isARepeat: true))
        #expect(PanelShortcut.classify(press) == .page(.redo))
    }

    @Test("modifier flags: ⌥ 1, ⌃ 2, ⌘ 4, ⇧ 8; Caps Lock and Fn are none of them")
    func modificateurs() {
        let all = CDPModifiers(eventFlags: [.option, .control, .command, .shift, .capsLock, .function])
        #expect(all.rawValue == 15)
        #expect(CDPModifiers(eventFlags: [.capsLock, .numericPad]).isEmpty)
        #expect(CDPModifiers(eventFlags: .option) == .alt)
    }

    @Test("a mouse event: the view's point as given, the button, the click count, the modifiers")
    func souris() throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 300),
                                                    modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        let mouse = event.panelMouseEvent(at: CGPoint(x: 12, y: 34))
        #expect(mouse == MacMouseEvent(location: CGPoint(x: 12, y: 34), buttonNumber: 0, clickCount: 2,
                                       modifiers: .alt))
        #expect(mouse.button == .left)
    }

    @Test("a flagsChanged: its key and the modifiers after it, no characters read")
    func modificateurSeul() {
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.shift],
                                           timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56) else {
            return   // AppKit builds no flagsChanged this way here: nothing to read.
        }
        let press = event.panelKeyPress
        #expect(press == MacKeyPress(keyCode: 56, modifiers: .shift))
    }
}

// MARK: - The panel script in a tab's init

@Suite("Chromium tab — the panel script beside the helper")
struct PanelScriptInitTests {

    private let agent = ChromiumUserAgent(major: "141", fullVersion: "141.0.7390.37")

    @Test("start sends the harness's init with the panel script right after the helper, in its world, before the target runs")
    func scriptDuPanneau() throws {
        let harness = ChromiumTabRuntime.initCommands(viewport: CGSize(width: 1280, height: 800), userAgent: agent)
        let started = ChromiumTabRuntime.startCommands(viewport: CGSize(width: 1280, height: 800), userAgent: agent)
        #expect(started.count == harness.count + 1)
        let helper = try #require(harness.lastIndex { $0.0 == "Page.addScriptToEvaluateOnNewDocument" })
        let panel = started[helper + 1]
        #expect(panel.0 == "Page.addScriptToEvaluateOnNewDocument")
        #expect(panel.1["worldName"] as? String == "loom-agent")
        #expect(panel.1["runImmediately"] as? Bool == true)
        let source = try #require(panel.1["source"] as? String)
        #expect(source.hasPrefix("if (window === window.top) {\n"))
        #expect(source.contains(AgentPanelScript.source))
        let methods = started.map { $0.0 }
        var withoutPanel = methods
        withoutPanel.remove(at: helper + 1)
        #expect(withoutPanel == harness.map { $0.0 })
        #expect(methods.last == "Runtime.runIfWaitingForDebugger")
        #expect(ChromiumTabRuntime.panelInjectFunction.hasPrefix("function() {\n"))
    }
}
