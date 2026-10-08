#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// The conflict policy between the user's input in the panel and the agent's
// commands (panel design §3). Pure: the pump (LoomWeb's UserInputPump,
// MainActor) holds one per tab with the mappings and the coalescer, and for
// every user event:
//
//     switch gate.admit(event) {
//     case .drop(let notice): show(notice)               // nil: silently
//     case .forward:
//         let commands = mapping.…(event)                // UserPointerMapping / UserKeyMapping
//         gate.didForward(commands)                      // what the page saw: held buttons, keys, composition
//         send(commands)                                 // through InputCoalescer
//     }
//
// A press is admitted only once UserPointerMapping.pressTarget says it lands
// on the page, so a letterbox click never counts as held.
//
// | User event                                  | Forwarded when                                        | Otherwise                 |
// |---------------------------------------------|-------------------------------------------------------|---------------------------|
// | bare mouse move                             | live, not running, not blocked, and first responder   | dropped silently          |
// | press, keyDown, IME, edit command, panel action | live, not running, not blocked                    | dropped, with a notice    |
// | drag, mouseUp, keyUp (and a modifier's up)  | its press went to the page (pairing invariant)        | dropped                   |
// | wheel                                       | live, not running, not blocked (no arming)            | dropped silently          |
// | leaving the view                            | live, not running, not blocked, the last move the user's, nothing held | dropped silently |
//
// The agent wins: before its first `Input.*`, `agentWillAct` releases what
// the user holds (buttons at the last point, keys, the composition) and the
// gate stays shut until `agentDidFinish`. The user's next armed move takes
// the hover back.

public typealias MouseButtonName = CDPMouseButton

/// A user event, as the gate sorts it.
public enum GateEvent: Equatable, Sendable {
    /// A move with no button down: hover.
    case mouseMove
    case mouseDown(MouseButtonName)
    /// A move with this button down.
    case mouseDrag(MouseButtonName)
    case mouseUp(MouseButtonName)
    /// The pointer left the view, or the view resigned first responder.
    case mouseExited
    case wheel
    case keyDown(keyCode: UInt16)
    case keyUp(keyCode: UInt16)
    /// A modifier key changed: its up when its down went out, else a down.
    case flagsChanged(keyCode: UInt16)
    /// What the input method or AppKit inserts or marks outside a keyDown.
    case text
    /// Copy, cut, paste, select all, undo, redo (menu or ⌘ chord).
    case editCommand
    /// The address bar, reload, back, forward (also the mouse's side buttons).
    case panelAction
}

public struct UserInputGate: Equatable, Sendable {

    /// The tab has a live page (not launching, suspended or crashed).
    public var live = false
    /// An agent command runs (between agentWillAct and agentDidFinish).
    public var agentRunning = false
    /// A JavaScript dialog blocks the page.
    public var pageBlocked = false
    /// The page view is first responder in the key window: it is armed.
    public var isFirstResponder = false

    /// The buttons whose press reached the page.
    public private(set) var heldButtons: Set<MouseButtonName> = []
    /// Mac key code → the key as its down reached the page.
    public private(set) var heldKeyEvents: [UInt16: KeyIdentity] = [:]
    /// A composition is open on the page.
    public private(set) var composing = false
    /// The page's pointer is where the user last put it.
    public private(set) var lastMoveFromUser = false
    /// A click, a key or text reached the page since the agent last acted:
    /// the engine tells the agent its refs may be stale.
    public private(set) var userActed = false

    public init(live: Bool = false, agentRunning: Bool = false, pageBlocked: Bool = false,
                isFirstResponder: Bool = false) {
        self.live = live
        self.agentRunning = agentRunning
        self.pageBlocked = pageBlocked
        self.isFirstResponder = isFirstResponder
    }

    /// The keys whose down reached the page, by Mac key code.
    public var heldKeys: Set<UInt16> {
        Set(heldKeyEvents.keys)
    }

    public enum Notice: String, Equatable, Sendable, CaseIterable {
        case agentRunning = "claude is using the page — wait until it finishes"
        case pageBlocked = "Answer the page's dialog first"

        public var text: String {
            rawValue
        }
    }

    public enum Verdict: Equatable, Sendable {
        case forward
        case drop(notice: Notice?)
    }

    /// Nothing stops the user's input.
    public var isOpen: Bool {
        live && !agentRunning && !pageBlocked
    }

    public mutating func admit(_ event: GateEvent) -> Verdict {
        switch event {
        case .mouseMove:
            return isOpen && isFirstResponder ? .forward : .drop(notice: nil)
        case .wheel:
            return isOpen ? .forward : .drop(notice: nil)
        case .mouseExited:
            return isOpen && lastMoveFromUser && heldButtons.isEmpty ? .forward : .drop(notice: nil)
        case .mouseDown, .keyDown, .text, .editCommand, .panelAction:
            if pageBlocked { return .drop(notice: .pageBlocked) }
            if agentRunning { return .drop(notice: .agentRunning) }
            guard live else { return .drop(notice: nil) }
            userActed = true
            return .forward
        case .mouseDrag(let button), .mouseUp(let button):
            return heldButtons.contains(button) ? .forward : .drop(notice: nil)
        case .keyUp(let keyCode):
            return heldKeyEvents[keyCode] != nil ? .forward : .drop(notice: nil)
        case .flagsChanged(let keyCode):
            if heldKeyEvents[keyCode] != nil { return .forward }
            // A modifier going down while the page is not the user's: no
            // notice (⌘ on its way to ⌘Tab is not an attempt to type).
            return isOpen ? .forward : .drop(notice: nil)
        }
    }

    /// What was actually sent: presses and key downs held until their
    /// release, the composition open until committed or cancelled, the
    /// pointer the user's until it leaves.
    public mutating func didForward(_ commands: [PanelCDPCommand]) {
        for command in commands {
            switch command.method {
            case PanelCDPCommand.dispatchMouseEvent:
                let button = CDPMouseButton(rawValue: command.params["button"]?.stringValue ?? "")
                switch command.type ?? "" {
                case "mousePressed":
                    if let button, button != CDPMouseButton.none { heldButtons.insert(button) }
                    lastMoveFromUser = true
                case "mouseReleased":
                    if let button { heldButtons.remove(button) }
                    lastMoveFromUser = true
                case "mouseMoved":
                    let x = command.params["x"]?.doubleValue ?? 0
                    let y = command.params["y"]?.doubleValue ?? 0
                    lastMoveFromUser = !(x < 0 && y < 0)
                default:
                    break
                }
            case PanelCDPCommand.dispatchKeyEvent:
                guard let native = command.params["nativeVirtualKeyCode"]?.intValue,
                      native >= 0, native <= Int(UInt16.max) else { continue }
                let keyCode = UInt16(native)
                switch command.type ?? "" {
                case "keyDown", "rawKeyDown":
                    heldKeyEvents[keyCode] = Self.identity(of: command)
                case "keyUp":
                    heldKeyEvents[keyCode] = nil
                default:
                    break
                }
            case PanelCDPCommand.imeSetCompositionMethod:
                composing = !(command.params["text"]?.stringValue ?? "").isEmpty
            case PanelCDPCommand.insertTextMethod:
                composing = false
            default:
                break
            }
        }
    }

    /// The agent takes the page: what the user holds comes up — each button
    /// at `lastPoint` (the mapping's last CSS point), each key — and a
    /// composition is cancelled. Send these before the agent's first
    /// `Input.*`; the gate stays shut until `agentDidFinish`. The pump then
    /// resets its mappings (`agentTookOver`) and drops the coalescer's
    /// pending moves.
    public mutating func agentWillAct(lastPoint: CGPoint?) -> [PanelCDPCommand] {
        var commands: [PanelCDPCommand] = []
        let point = lastPoint ?? .zero
        var remaining: CDPMouseButtons = []
        for button in heldButtons {
            remaining.insert(button.mask)
        }
        for button in Self.releaseOrder where heldButtons.contains(button) {
            commands.append(PanelCDPCommand(CDPInput.mouseReleased(x: Double(point.x), y: Double(point.y),
                                                                   button: button, clickCount: 1, held: remaining)))
            remaining.remove(button.mask)
        }
        for keyCode in heldKeyEvents.keys.sorted() {
            guard let key = heldKeyEvents[keyCode] else { continue }
            commands.append(.keyEvent(.keyUp, key, nativeKeyCode: keyCode, modifiers: []))
        }
        if composing {
            commands.append(PanelCDPCommand(CDPInput.imeCancel()))
        }
        heldButtons = []
        heldKeyEvents = [:]
        composing = false
        lastMoveFromUser = false
        userActed = false
        agentRunning = true
        return commands
    }

    public mutating func agentDidFinish() {
        agentRunning = false
    }

    /// Another page under the panel (a tab switch, a relaunch, a crash):
    /// nothing of the user's is held there.
    public mutating func reset() {
        heldButtons = []
        heldKeyEvents = [:]
        composing = false
        lastMoveFromUser = false
    }

    /// The DOM's order, as a move reports the primary held button.
    static let releaseOrder: [MouseButtonName] = [.left, .right, .middle, .back, .forward]

    static func identity(of command: PanelCDPCommand) -> KeyIdentity {
        KeyIdentity(key: command.params["key"]?.stringValue ?? "",
                    code: command.params["code"]?.stringValue ?? "",
                    windowsKeyCode: command.params["windowsVirtualKeyCode"]?.intValue ?? 0,
                    location: command.params["location"]?.intValue ?? 0)
    }
}
