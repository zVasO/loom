#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// The user's mouse and wheel in the panel → `Input.dispatchMouseEvent`
// (panel design §2, Mouse and Scroll). Every event carries pointerType
// "mouse", the modifiers bitmask (⌥ 1, ⌃ 2, ⌘ 4, ⇧ 8) and the buttons held
// (left 1, right 2, middle 4, back 8, forward 16), as `CDPInput` builds them:
//
// | NSEvent                         | CDP                                                        |
// |---------------------------------|------------------------------------------------------------|
// | mouseDown (any button)          | a move to the point if the last one sent was elsewhere, then mousePressed with clickCount |
// | *MouseDragged, after a press    | mouseMoved with the held button, unclamped (a drag leaves the view) |
// | *MouseUp, after a press         | mouseReleased, the button's bit gone                       |
// | mouseMoved                      | mouseMoved, button none                                    |
// | mouseExited                     | mouseMoved to (−1, −1): the page's :hover clears           |
// | buttonNumber 3 / 4              | history back / forward, not the page's                     |
// | scrollWheel                     | mouseWheel, deltas in CSS px (ScreencastGeometry.cssWheelDelta) |
//
// A press in the letterbox is not the page's. Points map through the
// geometry of the frame on screen. Whether an event may go at all is the
// gate's (UserInputGate): this only says what it becomes.

/// One NSEvent of the mouse, as the mapping needs it.
public struct MacMouseEvent: Equatable, Sendable {
    /// In the page view, in points, y down (the view is flipped).
    public var location: CGPoint
    /// NSEvent.buttonNumber: 0 left, 1 right, 2 middle, 3 back, 4 forward.
    public var buttonNumber: Int
    public var clickCount: Int
    public var modifiers: CDPModifiers

    public init(location: CGPoint, buttonNumber: Int = 0, clickCount: Int = 1, modifiers: CDPModifiers = []) {
        self.location = location
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.modifiers = modifiers
    }

    /// The DOM's button; nil past the fifth.
    public var button: CDPMouseButton? {
        UserPointerMapping.button(number: buttonNumber)
    }
}

/// One scrollWheel NSEvent.
public struct MacScrollEvent: Equatable, Sendable {
    public var location: CGPoint
    /// scrollingDeltaX / scrollingDeltaY as AppKit gives them (positive:
    /// the content moves right / down).
    public var delta: CGSize
    /// hasPreciseScrollingDeltas: points of a trackpad, else lines of a wheel.
    public var precise: Bool
    public var modifiers: CDPModifiers

    public init(location: CGPoint, delta: CGSize, precise: Bool, modifiers: CDPModifiers = []) {
        self.location = location
        self.delta = delta
        self.precise = precise
        self.modifiers = modifiers
    }
}

public enum HistoryDirection: String, Equatable, Sendable {
    case back, forward
}

public struct UserPointerMapping: Equatable, Sendable {

    /// Whether leaving the view moves the page's pointer to (−1, −1). The
    /// harness (T-leave) decides; it clears :hover and fires mouseleave.
    public var sendsLeaveMove: Bool
    /// The buttons whose press reached the page and whose release has not.
    public private(set) var held: CDPMouseButtons = []
    /// The page point of the last event sent, in CSS px; nil after a leave,
    /// or before any.
    public private(set) var lastPoint: CGPoint?

    public init(sendsLeaveMove: Bool = true) {
        self.sendsLeaveMove = sendsLeaveMove
    }

    /// Where a press lands.
    public enum PressTarget: Equatable, Sendable {
        /// The page, at this CSS point.
        case page(CGPoint)
        /// The mouse's back or forward button: the panel's history.
        case history(HistoryDirection)
        /// The letterbox, no frame yet, or a button the DOM has no name for.
        case outside
    }

    public static func button(number: Int) -> CDPMouseButton? {
        switch number {
        case 0: return .left
        case 1: return .right
        case 2: return .middle
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    /// Asked before the gate, so a press that will not reach the page never
    /// counts as one (no release would pair with it).
    public func pressTarget(_ event: MacMouseEvent, geometry: ScreencastGeometry) -> PressTarget {
        guard let button = event.button else { return .outside }
        switch button {
        case .back: return .history(.back)
        case .forward: return .history(.forward)
        case .none, .left, .right, .middle: break
        }
        guard let point = geometry.cssPoint(fromView: event.location) else { return .outside }
        return .page(point)
    }

    /// A press on the page: the pointer first moves there if the page saw it
    /// elsewhere (its :hover and the press's target agree), then the press.
    public mutating func mouseDown(_ event: MacMouseEvent, geometry: ScreencastGeometry) -> [PanelCDPCommand] {
        guard case .page(let point) = pressTarget(event, geometry: geometry), let button = event.button else { return [] }
        var commands: [PanelCDPCommand] = []
        if lastPoint != point {
            commands.append(PanelCDPCommand(CDPInput.mouseMoved(x: Double(point.x), y: Double(point.y),
                                                                modifiers: event.modifiers, held: held)))
        }
        commands.append(PanelCDPCommand(CDPInput.mousePressed(x: Double(point.x), y: Double(point.y), button: button,
                                                              clickCount: max(1, event.clickCount),
                                                              modifiers: event.modifiers, held: held)))
        held.insert(button.mask)
        lastPoint = point
        return commands
    }

    /// A drag, only while its button's press is on the page.
    public mutating func mouseDragged(_ event: MacMouseEvent, geometry: ScreencastGeometry) -> [PanelCDPCommand] {
        guard let button = event.button, !button.mask.isEmpty, held.contains(button.mask) else { return [] }
        let point = geometry.cssPointUnclamped(fromView: event.location)
        lastPoint = point
        return [PanelCDPCommand(CDPInput.mouseMoved(x: Double(point.x), y: Double(point.y),
                                                    modifiers: event.modifiers, held: held))]
    }

    /// The release of a press that reached the page, wherever it ends.
    public mutating func mouseUp(_ event: MacMouseEvent, geometry: ScreencastGeometry) -> [PanelCDPCommand] {
        guard let button = event.button, !button.mask.isEmpty, held.contains(button.mask) else { return [] }
        let point = geometry.cssPointUnclamped(fromView: event.location)
        let command = PanelCDPCommand(CDPInput.mouseReleased(x: Double(point.x), y: Double(point.y), button: button,
                                                             clickCount: max(1, event.clickCount),
                                                             modifiers: event.modifiers, held: held))
        held.remove(button.mask)
        lastPoint = point
        return [command]
    }

    /// A bare move over the page (the gate arms it); nothing in the
    /// letterbox, nothing where the page already has the pointer.
    public mutating func mouseMoved(_ event: MacMouseEvent, geometry: ScreencastGeometry) -> [PanelCDPCommand] {
        guard let point = geometry.cssPoint(fromView: event.location), point != lastPoint else { return [] }
        lastPoint = point
        return [PanelCDPCommand(CDPInput.mouseMoved(x: Double(point.x), y: Double(point.y),
                                                    modifiers: event.modifiers, held: held))]
    }

    /// The pointer left the view (or the view resigned): the page's pointer
    /// goes nowhere, so the user's :hover clears. Not during a drag.
    public mutating func mouseExited() -> [PanelCDPCommand] {
        guard sendsLeaveMove, held.isEmpty, lastPoint != nil else { return [] }
        lastPoint = nil
        return [PanelCDPCommand(CDPInput.mouseMoved(x: -1, y: -1))]
    }

    /// A wheel turn or a trackpad scroll, momentum included. Over the
    /// letterbox it scrolls at the page's nearest edge.
    public func wheel(_ event: MacScrollEvent, geometry: ScreencastGeometry) -> [PanelCDPCommand] {
        guard !geometry.contentRect.isEmpty else { return [] }
        let delta = geometry.cssWheelDelta(event.delta, precise: event.precise)
        guard delta.width != 0 || delta.height != 0 else { return [] }
        let point = geometry.cssPoint(fromView: event.location)
            ?? Self.clamped(geometry.cssPointUnclamped(fromView: event.location), to: geometry.device)
        return [PanelCDPCommand(CDPInput.mouseWheel(x: Double(point.x), y: Double(point.y),
                                                    deltaX: Double(delta.width), deltaY: Double(delta.height),
                                                    modifiers: event.modifiers))]
    }

    /// The agent took the page (`UserInputGate.agentWillAct` released the
    /// buttons): nothing is held, and the page's pointer is the agent's.
    public mutating func agentTookOver() {
        held = []
        lastPoint = nil
    }

    static func clamped(_ point: CGPoint, to device: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(0, device.width - 1)),
                y: min(max(point.y, 0), max(0, device.height - 1)))
    }
}
