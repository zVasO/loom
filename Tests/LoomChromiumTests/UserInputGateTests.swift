import Testing
import LoomChromium
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Seam: the conflict policy between the user's input in the panel and the
// agent's commands (panel design §3) — the admission table, the pairing
// invariant, and what the agent's takeover releases.

@Suite("UserInputGate — the user's input against the agent's")
struct UserInputGateTests {

    private let busy = UserInputGate.Verdict.drop(notice: .agentRunning)
    private let dialog = UserInputGate.Verdict.drop(notice: .pageBlocked)
    private let silent = UserInputGate.Verdict.drop(notice: nil)

    /// Admits and records what the mapping sent, as the pump does.
    private func pass(_ gate: inout UserInputGate, _ event: GateEvent, _ commands: [PanelCDPCommand]) -> Bool {
        guard gate.admit(event) == .forward else { return false }
        gate.didForward(commands)
        return true
    }

    private let press = [mouseCommand("mouseMoved", x: 200, y: 100),
                         mouseCommand("mousePressed", x: 200, y: 100, button: "left", buttons: 1, clickCount: 1)]
    private let release = [mouseCommand("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1)]
    private let shiftDown = [keyCommand("rawKeyDown", key: "Shift", code: "ShiftLeft", vk: 16, native: 56, modifiers: 8,
                                        location: 1)]
    private let aDown = [keyCommand("keyDown", key: "a", code: "KeyA", vk: 65, native: 0, text: "a")]

    @Test("a bare move goes only once the page view is armed (first responder)")
    func survolArme() {
        var gate = UserInputGate(live: true)
        let unarmed = gate.admit(.mouseMove)
        #expect(unarmed == silent)
        gate.isFirstResponder = true
        let armed = gate.admit(.mouseMove)
        #expect(armed == .forward)
        gate.agentRunning = true
        let running = gate.admit(.mouseMove)
        #expect(running == silent, "a pointer crossing the panel never breaks the agent's hover")
    }

    @Test("presses, keys, text, edit and panel actions: forwarded when open, else dropped with the notice")
    func tableDesPressions() {
        let events: [GateEvent] = [.mouseDown(.left), .keyDown(keyCode: 0), .text, .editCommand, .panelAction]
        for event in events {
            var open = UserInputGate(live: true)
            let forwarded = open.admit(event)
            #expect(forwarded == .forward, "\(event)")
            var running = UserInputGate(live: true, agentRunning: true)
            let whileRunning = running.admit(event)
            #expect(whileRunning == busy, "\(event)")
            var blocked = UserInputGate(live: true, pageBlocked: true)
            let whileBlocked = blocked.admit(event)
            #expect(whileBlocked == dialog, "\(event)")
            var dead = UserInputGate(live: false)
            let notLive = dead.admit(event)
            #expect(notLive == silent, "\(event)")
        }
    }

    @Test("the wheel needs no arming, and is dropped silently when the page is not the user's")
    func molette() {
        var gate = UserInputGate(live: true)
        let unarmed = gate.admit(.wheel)
        #expect(unarmed == .forward)
        gate.agentRunning = true
        let running = gate.admit(.wheel)
        #expect(running == silent)
    }

    @Test("pairing: a drag, a release, a keyUp only after their press reached the page")
    func appariement() {
        var gate = UserInputGate(live: true, isFirstResponder: true)
        let orphanDrag = gate.admit(.mouseDrag(.left))
        let orphanUp = gate.admit(.mouseUp(.left))
        let orphanKeyUp = gate.admit(.keyUp(keyCode: 0))
        #expect(orphanDrag == silent)
        #expect(orphanUp == silent)
        #expect(orphanKeyUp == silent)

        let pressed = pass(&gate, .mouseDown(.left), press)
        #expect(pressed)
        #expect(gate.heldButtons == [.left])
        let drag = gate.admit(.mouseDrag(.left))
        #expect(drag == .forward)
        let otherButton = gate.admit(.mouseUp(.right))
        #expect(otherButton == silent)
        let released = pass(&gate, .mouseUp(.left), release)
        #expect(released)
        #expect(gate.heldButtons.isEmpty)

        let typed = pass(&gate, .keyDown(keyCode: 0), aDown)
        #expect(typed)
        #expect(gate.heldKeys == [0])
        let keyUp = gate.admit(.keyUp(keyCode: 0))
        #expect(keyUp == .forward)
    }

    @Test("a key down that sent no key event (a dead key) pairs with no keyUp")
    func toucheMorteSansKeyUp() {
        var gate = UserInputGate(live: true)
        let composed = pass(&gate, .keyDown(keyCode: 0x21), [compositionCommand("^", 1, 1)])
        #expect(composed)
        #expect(gate.heldKeys.isEmpty)
        #expect(gate.composing)
        let up = gate.admit(.keyUp(keyCode: 0x21))
        #expect(up == silent)
        gate.didForward([insertTextCommand("ê")])
        #expect(!gate.composing)
    }

    @Test("a dialog opened by the press: its release still goes, new presses wait with the notice")
    func dialogueOuvertParLAppui() {
        var gate = UserInputGate(live: true, isFirstResponder: true)
        _ = pass(&gate, .mouseDown(.left), press)
        gate.pageBlocked = true
        let up = gate.admit(.mouseUp(.left))
        #expect(up == .forward)
        gate.didForward(release)
        let again = gate.admit(.mouseDown(.left))
        #expect(again == dialog)
        let key = gate.admit(.keyDown(keyCode: 0))
        #expect(key == dialog)
        let move = gate.admit(.mouseMove)
        #expect(move == silent)
    }

    @Test("agentWillAct: buttons released at the last point, keys up, the composition cancelled; shut until it finishes")
    func repriseParLAgent() {
        var gate = UserInputGate(live: true, isFirstResponder: true)
        _ = pass(&gate, .mouseDown(.left), press)
        _ = pass(&gate, .flagsChanged(keyCode: 0x38), shiftDown)
        _ = pass(&gate, .keyDown(keyCode: 0x21), [compositionCommand("¨", 1, 1)])
        #expect(gate.lastMoveFromUser)

        let releases = gate.agentWillAct(lastPoint: CGPoint(x: 200, y: 100))
        #expect(releases == [
            mouseCommand("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1),
            keyCommand("keyUp", key: "Shift", code: "ShiftLeft", vk: 16, native: 56, location: 1),
            compositionCommand("", 0, 0),
        ])
        #expect(gate.agentRunning)
        #expect(gate.heldButtons.isEmpty)
        #expect(gate.heldKeys.isEmpty)
        #expect(!gate.composing)
        #expect(!gate.lastMoveFromUser)

        // The user's own release and keyUp come later: already released.
        let up = gate.admit(.mouseUp(.left))
        #expect(up == silent)
        let shiftUp = gate.admit(.flagsChanged(keyCode: 0x38))
        #expect(shiftUp == silent)
        let typed = gate.admit(.keyDown(keyCode: 0))
        #expect(typed == busy)

        gate.agentDidFinish()
        let after = gate.admit(.keyDown(keyCode: 0))
        #expect(after == .forward)
        let hover = gate.admit(.mouseMove)
        #expect(hover == .forward, "the user's next armed move takes the hover back")
    }

    @Test("two held buttons come up one by one, the mask shrinking; nothing held, nothing sent")
    func deuxBoutons() {
        var gate = UserInputGate(live: true)
        gate.didForward([mouseCommand("mousePressed", x: 5, y: 6, button: "right", buttons: 2, clickCount: 1),
                         mouseCommand("mousePressed", x: 5, y: 6, button: "left", buttons: 3, clickCount: 1)])
        let releases = gate.agentWillAct(lastPoint: CGPoint(x: 5, y: 6))
        #expect(releases == [
            mouseCommand("mouseReleased", x: 5, y: 6, button: "left", buttons: 2, clickCount: 1),
            mouseCommand("mouseReleased", x: 5, y: 6, button: "right", buttons: 0, clickCount: 1),
        ])
        gate.agentDidFinish()
        let nothing = gate.agentWillAct(lastPoint: nil)
        #expect(nothing.isEmpty)
    }

    @Test("leaving the view clears the hover only when the last move was the user's and nothing is held")
    func sortie() {
        var gate = UserInputGate(live: true, isFirstResponder: true)
        let before = gate.admit(.mouseExited)
        #expect(before == silent)
        gate.didForward([mouseCommand("mouseMoved", x: 300, y: 150)])
        let hovering = gate.admit(.mouseExited)
        #expect(hovering == .forward)
        gate.didForward([mouseCommand("mouseMoved", x: -1, y: -1)])
        #expect(!gate.lastMoveFromUser)
        let twice = gate.admit(.mouseExited)
        #expect(twice == silent)
        _ = pass(&gate, .mouseDown(.left), press)
        let dragging = gate.admit(.mouseExited)
        #expect(dragging == silent)
    }

    @Test("a modifier's down while the agent runs is dropped without a notice; its up after a forwarded down goes")
    func modificateurs() {
        var gate = UserInputGate(live: true)
        _ = pass(&gate, .flagsChanged(keyCode: 0x38), shiftDown)
        gate.pageBlocked = true
        let up = gate.admit(.flagsChanged(keyCode: 0x38))
        #expect(up == .forward)
        let otherDown = gate.admit(.flagsChanged(keyCode: 0x37))
        #expect(otherDown == silent)
    }

    @Test("userActed: a click or a key sets it, the agent's turn clears it; a wheel or a move does not")
    func utilisateurAgi() {
        var gate = UserInputGate(live: true, isFirstResponder: true)
        _ = gate.admit(.wheel)
        _ = gate.admit(.mouseMove)
        #expect(!gate.userActed)
        _ = gate.admit(.keyDown(keyCode: 0))
        #expect(gate.userActed)
        _ = gate.agentWillAct(lastPoint: nil)
        #expect(!gate.userActed)
    }

    @Test("reset: another page under the panel holds nothing of the user's")
    func remiseAZero() {
        var gate = UserInputGate(live: true)
        _ = pass(&gate, .mouseDown(.left), press)
        _ = pass(&gate, .keyDown(keyCode: 0), aDown)
        gate.reset()
        #expect(gate.heldButtons.isEmpty)
        #expect(gate.heldKeys.isEmpty)
        let releases = gate.agentWillAct(lastPoint: nil)
        #expect(releases.isEmpty)
    }

    @Test("the two notices, word for word")
    func avis() {
        #expect(UserInputGate.Notice.agentRunning.text == "claude is using the page — wait until it finishes")
        #expect(UserInputGate.Notice.pageBlocked.text == "Answer the page's dialog first")
    }
}
