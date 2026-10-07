import AppKit
import CoreGraphics
import LoomChromium

// The page view's NSEvents as the panel's pure mappings read them
// (LoomChromium: MacKeyPress, MacMouseEvent, MacScrollEvent). Only what each
// event type carries is read: a flagsChanged has no characters and no
// repeat flag (AppKit raises when they are asked of one).

extension CDPModifiers {

    /// ⌥ 1, ⌃ 2, ⌘ 4, ⇧ 8. Caps Lock, Fn and the keypad flag are not a
    /// page's modifiers.
    init(eventFlags flags: NSEvent.ModifierFlags) {
        var modifiers: CDPModifiers = []
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.meta) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

extension NSEvent {

    var panelModifiers: CDPModifiers {
        CDPModifiers(eventFlags: modifierFlags)
    }

    /// A keyDown or keyUp with its characters; a flagsChanged with its key
    /// and the modifiers after it. Any other event is no key (key code 0).
    var panelKeyPress: MacKeyPress {
        switch type {
        case .keyDown, .keyUp:
            return MacKeyPress(keyCode: keyCode, characters: characters ?? "",
                               charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
                               modifiers: panelModifiers, isARepeat: isARepeat)
        case .flagsChanged:
            return MacKeyPress(keyCode: keyCode, modifiers: panelModifiers)
        default:
            return MacKeyPress(keyCode: 0, modifiers: panelModifiers)
        }
    }

    /// A mouse event at `location`, in the page view's points, y down: a
    /// button's down, up or drag with its button and click count; anything
    /// else (a bare move) as no button and one click, read from nothing.
    func panelMouseEvent(at location: CGPoint) -> MacMouseEvent {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return MacMouseEvent(location: location, buttonNumber: buttonNumber, clickCount: clickCount,
                                 modifiers: panelModifiers)
        default:
            return MacMouseEvent(location: location, modifiers: panelModifiers)
        }
    }

    /// A scrollWheel at `location`: trackpad points when precise, wheel
    /// lines otherwise; momentum events alike.
    func panelScrollEvent(at location: CGPoint) -> MacScrollEvent {
        MacScrollEvent(location: location, delta: CGSize(width: scrollingDeltaX, height: scrollingDeltaY),
                       precise: hasPreciseScrollingDeltas, modifiers: panelModifiers)
    }
}

extension CursorKind {

    /// The NSCursor the page view shows for the page's cursor.
    @MainActor
    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        case .iBeam: return .iBeam
        case .crosshair: return .crosshair
        case .operationNotAllowed: return .operationNotAllowed
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .resizeLeftRight: return .resizeLeftRight
        case .resizeUpDown: return .resizeUpDown
        case .dragCopy: return .dragCopy
        case .dragLink: return .dragLink
        case .contextualMenu: return .contextualMenu
        }
    }
}
