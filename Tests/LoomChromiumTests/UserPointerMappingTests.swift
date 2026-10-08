import Testing
import LoomChromium
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Seam: the user's mouse and wheel in the panel → Input.dispatchMouseEvent.
// Half a point per CSS pixel (PanelTestSupport): view (100, 50) is page
// (200, 100).

@Suite("UserPointerMapping — the panel's mouse and wheel as CDP")
struct UserPointerMappingTests {

    private func event(_ x: CGFloat, _ y: CGFloat, button: Int = 0, clicks: Int = 1,
                       modifiers: CDPModifiers = []) -> MacMouseEvent {
        MacMouseEvent(location: CGPoint(x: x, y: y), buttonNumber: button, clickCount: clicks, modifiers: modifiers)
    }

    @Test("a press: the pointer moves there first, then the press with its button, mask and clickCount")
    func appui() {
        var pointer = UserPointerMapping()
        let down = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        #expect(down == [
            mouseCommand("mouseMoved", x: 200, y: 100),
            mouseCommand("mousePressed", x: 200, y: 100, button: "left", buttons: 1, clickCount: 1),
        ])
        let up = pointer.mouseUp(event(100, 50), geometry: halfScaleGeometry)
        #expect(up == [mouseCommand("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, clickCount: 1)])
        #expect(pointer.held.isEmpty)
        #expect(pointer.lastPoint == CGPoint(x: 200, y: 100))
    }

    @Test("the pre-press move only when the page's pointer is elsewhere; a double click counts 2")
    func doubleClic() {
        var pointer = UserPointerMapping()
        _ = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        _ = pointer.mouseUp(event(100, 50), geometry: halfScaleGeometry)
        let second = pointer.mouseDown(event(100, 50, clicks: 2), geometry: halfScaleGeometry)
        #expect(second == [mouseCommand("mousePressed", x: 200, y: 100, button: "left", buttons: 1, clickCount: 2)])
        _ = pointer.mouseUp(event(100, 50, clicks: 2), geometry: halfScaleGeometry)
        let elsewhere = pointer.mouseDown(event(110, 50), geometry: halfScaleGeometry)
        #expect(elsewhere.count == 2)
        #expect(elsewhere.first == mouseCommand("mouseMoved", x: 220, y: 100))
    }

    @Test("right and middle buttons: their names and bits; a second button keeps the first's")
    func boutons() {
        var pointer = UserPointerMapping()
        let right = pointer.mouseDown(event(100, 50, button: 1), geometry: halfScaleGeometry)
        #expect(right.last == mouseCommand("mousePressed", x: 200, y: 100, button: "right", buttons: 2, clickCount: 1))
        let middle = pointer.mouseDown(event(100, 50, button: 2), geometry: halfScaleGeometry)
        #expect(middle == [mouseCommand("mousePressed", x: 200, y: 100, button: "middle", buttons: 6, clickCount: 1)])
        #expect(pointer.held == [.right, .middle])
        let rightUp = pointer.mouseUp(event(100, 50, button: 1), geometry: halfScaleGeometry)
        #expect(rightUp == [mouseCommand("mouseReleased", x: 200, y: 100, button: "right", buttons: 4, clickCount: 1)])
    }

    @Test("the modifiers bitmask rides on every event: ⌥ 1, ⌃ 2, ⌘ 4, ⇧ 8")
    func modificateurs() {
        var pointer = UserPointerMapping()
        let controlClick = pointer.mouseDown(event(100, 50, modifiers: [.control]), geometry: halfScaleGeometry)
        #expect(controlClick == [
            mouseCommand("mouseMoved", x: 200, y: 100, modifiers: 2),
            mouseCommand("mousePressed", x: 200, y: 100, button: "left", buttons: 1, modifiers: 2, clickCount: 1),
        ])
        let up = pointer.mouseUp(event(100, 50, modifiers: [.alt, .meta, .shift]), geometry: halfScaleGeometry)
        #expect(up == [mouseCommand("mouseReleased", x: 200, y: 100, button: "left", buttons: 0, modifiers: 13,
                                    clickCount: 1)])
    }

    @Test("a drag reports the held button and goes past the view's edge unclamped")
    func glisser() {
        var pointer = UserPointerMapping()
        _ = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        let inside = pointer.mouseDragged(event(300, 50), geometry: halfScaleGeometry)
        #expect(inside == [mouseCommand("mouseMoved", x: 600, y: 100, button: "left", buttons: 1)])
        let outside = pointer.mouseDragged(event(700, -10), geometry: halfScaleGeometry)
        #expect(outside == [mouseCommand("mouseMoved", x: 1_400, y: -20, button: "left", buttons: 1)])
        let up = pointer.mouseUp(event(700, -10), geometry: halfScaleGeometry)
        #expect(up == [mouseCommand("mouseReleased", x: 1_400, y: -20, button: "left", buttons: 0, clickCount: 1)])
    }

    @Test("a drag or a release without its press is not the page's")
    func sansAppui() {
        var pointer = UserPointerMapping()
        let drag = pointer.mouseDragged(event(300, 50), geometry: halfScaleGeometry)
        let up = pointer.mouseUp(event(300, 50), geometry: halfScaleGeometry)
        #expect(drag.isEmpty)
        #expect(up.isEmpty)
    }

    @Test("the mouse's back and forward buttons are the panel's history, never forwarded")
    func historique() {
        var pointer = UserPointerMapping()
        #expect(pointer.pressTarget(event(100, 50, button: 3), geometry: halfScaleGeometry) == .history(.back))
        #expect(pointer.pressTarget(event(100, 50, button: 4), geometry: halfScaleGeometry) == .history(.forward))
        let back = pointer.mouseDown(event(100, 50, button: 3), geometry: halfScaleGeometry)
        #expect(back.isEmpty)
        let backUp = pointer.mouseUp(event(100, 50, button: 3), geometry: halfScaleGeometry)
        #expect(backUp.isEmpty)
        #expect(pointer.held.isEmpty)
        #expect(pointer.pressTarget(event(100, 50, button: 7), geometry: halfScaleGeometry) == .outside)
    }

    @Test("a press in the letterbox is not forwarded, nor its release; one on the picture is")
    func bandeauNoir() {
        var pointer = UserPointerMapping()
        #expect(pointer.pressTarget(event(300, 100), geometry: letterboxGeometry) == .outside)
        let letterbox = pointer.mouseDown(event(300, 100), geometry: letterboxGeometry)
        #expect(letterbox.isEmpty)
        let letterboxUp = pointer.mouseUp(event(300, 100), geometry: letterboxGeometry)
        #expect(letterboxUp.isEmpty)
        #expect(pointer.pressTarget(event(300, 400), geometry: letterboxGeometry) == .page(CGPoint(x: 640, y: 360)))
        let picture = pointer.mouseDown(event(300, 400), geometry: letterboxGeometry)
        #expect(picture.last == mouseCommand("mousePressed", x: 640, y: 360, button: "left", buttons: 1, clickCount: 1))
    }

    @Test("a bare move: nothing in the letterbox, nothing twice for the same point")
    func survol() {
        var pointer = UserPointerMapping()
        let letterbox = pointer.mouseMoved(event(300, 100), geometry: letterboxGeometry)
        #expect(letterbox.isEmpty)
        let first = pointer.mouseMoved(event(150, 75), geometry: halfScaleGeometry)
        #expect(first == [mouseCommand("mouseMoved", x: 300, y: 150)])
        let same = pointer.mouseMoved(event(150, 75), geometry: halfScaleGeometry)
        #expect(same.isEmpty)
    }

    @Test("leaving the view moves the page's pointer to (−1, −1), once, never during a drag, not when off")
    func sortieDeLaVue() {
        var pointer = UserPointerMapping()
        let never = pointer.mouseExited()
        #expect(never.isEmpty, "no pointer on the page yet")
        _ = pointer.mouseMoved(event(150, 75), geometry: halfScaleGeometry)
        let leave = pointer.mouseExited()
        #expect(leave == [mouseCommand("mouseMoved", x: -1, y: -1)])
        let again = pointer.mouseExited()
        #expect(again.isEmpty)

        _ = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        let dragging = pointer.mouseExited()
        #expect(dragging.isEmpty)

        var off = UserPointerMapping(sendsLeaveMove: false)
        _ = off.mouseMoved(event(150, 75), geometry: halfScaleGeometry)
        let silent = off.mouseExited()
        #expect(silent.isEmpty)
        #expect(off.lastPoint == CGPoint(x: 300, y: 150))
    }

    @Test("the wheel: trackpad points scaled to CSS px, a line is 40 px, the sign flipped")
    func molette() {
        let pointer = UserPointerMapping()
        let precise = pointer.wheel(MacScrollEvent(location: CGPoint(x: 100, y: 50), delta: CGSize(width: 3, height: -10),
                                                   precise: true), geometry: halfScaleGeometry)
        #expect(precise == [wheelCommand(x: 200, y: 100, deltaX: -6, deltaY: 20)])
        let line = pointer.wheel(MacScrollEvent(location: CGPoint(x: 100, y: 50), delta: CGSize(width: 0, height: 1),
                                                precise: false, modifiers: [.shift]), geometry: halfScaleGeometry)
        #expect(line == [wheelCommand(x: 200, y: 100, deltaX: 0, deltaY: -40, modifiers: 8)])
        let still = pointer.wheel(MacScrollEvent(location: CGPoint(x: 100, y: 50), delta: .zero, precise: true),
                                  geometry: halfScaleGeometry)
        #expect(still.isEmpty, "a momentum event with no delta")
        let letterbox = pointer.wheel(MacScrollEvent(location: CGPoint(x: 300, y: 100), delta: CGSize(width: 0, height: -1),
                                                     precise: false), geometry: letterboxGeometry)
        #expect(letterbox == [wheelCommand(x: 640, y: 0, deltaX: 0, deltaY: 40)], "at the page's nearest edge")
    }

    @Test("the agent took over: nothing held, and the next press moves the pointer back first")
    func repriseParLAgent() {
        var pointer = UserPointerMapping()
        _ = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        pointer.agentTookOver()
        #expect(pointer.held.isEmpty)
        #expect(pointer.lastPoint == nil)
        let up = pointer.mouseUp(event(100, 50), geometry: halfScaleGeometry)
        #expect(up.isEmpty)
        let again = pointer.mouseDown(event(100, 50), geometry: halfScaleGeometry)
        #expect(again.first == mouseCommand("mouseMoved", x: 200, y: 100))
    }
}
