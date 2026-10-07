import Foundation

/// `Input.dispatch*Event.modifiers`: Alt=1, Ctrl=2, Meta/Command=4, Shift=8.
public struct CDPModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let alt = CDPModifiers(rawValue: 1)
    public static let control = CDPModifiers(rawValue: 2)
    public static let meta = CDPModifiers(rawValue: 4)
    public static let shift = CDPModifiers(rawValue: 8)
}

public enum CDPMouseButton: String, Sendable, CaseIterable {
    case none, left, middle, right, back, forward

    /// Its bit in `buttons` (the DOM's `MouseEvent.buttons`).
    public var mask: CDPMouseButtons {
        switch self {
        case .none: return []
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        case .back: return .back
        case .forward: return .forward
        }
    }
}

/// The buttons held down, as `MouseEvent.buttons` counts them.
public struct CDPMouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let left = CDPMouseButtons(rawValue: 1)
    public static let right = CDPMouseButtons(rawValue: 2)
    public static let middle = CDPMouseButtons(rawValue: 4)
    public static let back = CDPMouseButtons(rawValue: 8)
    public static let forward = CDPMouseButtons(rawValue: 16)

    /// The button a move reports while these are down: the DOM's order.
    var primary: CDPMouseButton {
        if contains(.left) { return .left }
        if contains(.right) { return .right }
        if contains(.middle) { return .middle }
        if contains(.back) { return .back }
        if contains(.forward) { return .forward }
        return .none
    }
}

/// One key as the page's events carry it. `keyCode` is the Windows virtual
/// key code (65 for "a"), sent as both `windowsVirtualKeyCode` and
/// `nativeVirtualKeyCode`; `text` is what it types, if anything.
public struct CDPKey: Sendable, Equatable {
    public var key: String
    public var code: String
    public var keyCode: Int
    public var text: String?
    public var modifiers: CDPModifiers
    /// `KeyboardEvent.location`: 1 left, 2 right, 3 numpad.
    public var location: Int

    public init(key: String, code: String, keyCode: Int, text: String? = nil,
                modifiers: CDPModifiers = [], location: Int = 0) {
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
        self.location = location
    }

    /// The text its keyDown carries. Enter types "\r" — the only Enter a
    /// form submits on (step-0 probe: "\n", no text, rawKeyDown all fail).
    /// Control, Meta or Alt held: none, as Playwright does — the key is a
    /// shortcut, and its edit comes from the Mac commands.
    public var typedText: String? {
        if !modifiers.intersection([.control, .meta, .alt]).isEmpty { return nil }
        if code == "Enter" || code == "NumpadEnter" { return "\r" }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // The modifier keys themselves, pressed around a shortcut (US layout).
    public static let shift = CDPKey(key: "Shift", code: "ShiftLeft", keyCode: 16, location: 1)
    public static let control = CDPKey(key: "Control", code: "ControlLeft", keyCode: 17, location: 1)
    public static let alt = CDPKey(key: "Alt", code: "AltLeft", keyCode: 18, location: 1)
    public static let meta = CDPKey(key: "Meta", code: "MetaLeft", keyCode: 91, location: 1)
}

/// The `Input.*` commands of trusted input (ADR-0016), as (method, params)
/// ready for `CDPConnection.post(batch:)`. Pure: the caller decides what
/// goes in one write — a click's three mouse events always do, so nothing
/// runs between them — and what waits for the previous acks.
public enum CDPInput {

    public static let dispatchMouseEvent = "Input.dispatchMouseEvent"
    public static let dispatchKeyEvent = "Input.dispatchKeyEvent"

    // MARK: - Mouse

    /// The pointer moves to (x, y), in CSS pixels of the main frame's
    /// viewport. `held`: the buttons down during the move (a drag).
    public static func mouseMoved(x: Double, y: Double, modifiers: CDPModifiers = [],
                                  held: CDPMouseButtons = []) -> (String, [String: Any]) {
        let params: [String: Any] = [
            "type": "mouseMoved", "x": x, "y": y,
            "button": held.primary.rawValue, "buttons": held.rawValue,
            "modifiers": modifiers.rawValue, "pointerType": "mouse",
        ]
        return (dispatchMouseEvent, params)
    }

    /// `button` goes down; `held`: other buttons already down.
    public static func mousePressed(x: Double, y: Double, button: CDPMouseButton = .left, clickCount: Int = 1,
                                    modifiers: CDPModifiers = [],
                                    held: CDPMouseButtons = []) -> (String, [String: Any]) {
        let params: [String: Any] = [
            "type": "mousePressed", "x": x, "y": y,
            "button": button.rawValue, "buttons": held.union(button.mask).rawValue,
            "clickCount": clickCount, "modifiers": modifiers.rawValue, "pointerType": "mouse",
        ]
        return (dispatchMouseEvent, params)
    }

    /// `button` comes up; `held`: other buttons still down.
    public static func mouseReleased(x: Double, y: Double, button: CDPMouseButton = .left, clickCount: Int = 1,
                                     modifiers: CDPModifiers = [],
                                     held: CDPMouseButtons = []) -> (String, [String: Any]) {
        let params: [String: Any] = [
            "type": "mouseReleased", "x": x, "y": y,
            "button": button.rawValue, "buttons": held.subtracting(button.mask).rawValue,
            "clickCount": clickCount, "modifiers": modifiers.rawValue, "pointerType": "mouse",
        ]
        return (dispatchMouseEvent, params)
    }

    /// A single click: move, press, release — one write, so the page sees
    /// the whole pointer sequence (pointerover … click) in one go and
    /// `:hover` holds afterwards.
    public static func click(x: Double, y: Double, button: CDPMouseButton = .left,
                             modifiers: CDPModifiers = []) -> [(String, [String: Any])] {
        [
            mouseMoved(x: x, y: y, modifiers: modifiers),
            mousePressed(x: x, y: y, button: button, clickCount: 1, modifiers: modifiers),
            mouseReleased(x: x, y: y, button: button, clickCount: 1, modifiers: modifiers),
        ]
    }

    /// A double (or triple) click as successive writes: the first is
    /// `click`, each next one a press and a release with the count so far.
    /// Each write goes after the previous one's acks: a dialog the first
    /// click opens never receives a ghost second click.
    public static func clicks(x: Double, y: Double, button: CDPMouseButton = .left, clickCount: Int,
                              modifiers: CDPModifiers = []) -> [[(String, [String: Any])]] {
        var writes = [click(x: x, y: y, button: button, modifiers: modifiers)]
        if clickCount >= 2 {
            for count in 2...clickCount {
                writes.append([
                    mousePressed(x: x, y: y, button: button, clickCount: count, modifiers: modifiers),
                    mouseReleased(x: x, y: y, button: button, clickCount: count, modifiers: modifiers),
                ])
            }
        }
        return writes
    }

    /// A wheel turn over (x, y): the page scrolls by the deltas at once
    /// (step-0 probe: deltaY 300 → scrollY + 300).
    public static func mouseWheel(x: Double, y: Double, deltaX: Double, deltaY: Double,
                                  modifiers: CDPModifiers = []) -> (String, [String: Any]) {
        let params: [String: Any] = [
            "type": "mouseWheel", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY,
            "modifiers": modifiers.rawValue, "pointerType": "mouse",
        ]
        return (dispatchMouseEvent, params)
    }

    // MARK: - Keys

    /// A key goes down: `keyDown` when it types text (keypress, beforeinput
    /// and input follow), `rawKeyDown` when it does not (Tab moves focus,
    /// Escape, arrows). On a Mac, the editing commands of its combination.
    public static func keyDown(_ key: CDPKey, mac: Bool = true, autoRepeat: Bool = false) -> (String, [String: Any]) {
        let text = key.typedText
        var params: [String: Any] = [
            "type": text == nil ? "rawKeyDown" : "keyDown",
            "key": key.key,
            "code": key.code,
            "windowsVirtualKeyCode": key.keyCode,
            "nativeVirtualKeyCode": key.keyCode,
            "modifiers": key.modifiers.rawValue,
        ]
        if let text {
            params["text"] = text
            params["unmodifiedText"] = text
        }
        if key.location != 0 { params["location"] = key.location }
        if key.location == 3 { params["isKeypad"] = true }
        if autoRepeat { params["autoRepeat"] = true }
        if mac {
            let commands = MacEditingCommands.commands(code: key.code, modifiers: key.modifiers)
            if !commands.isEmpty { params["commands"] = commands }
        }
        return (dispatchKeyEvent, params)
    }

    public static func keyUp(_ key: CDPKey) -> (String, [String: Any]) {
        var params: [String: Any] = [
            "type": "keyUp",
            "key": key.key,
            "code": key.code,
            "windowsVirtualKeyCode": key.keyCode,
            "nativeVirtualKeyCode": key.keyCode,
            "modifiers": key.modifiers.rawValue,
        ]
        if key.location != 0 { params["location"] = key.location }
        if key.location == 3 { params["isKeypad"] = true }
        return (dispatchKeyEvent, params)
    }

    /// The order modifier keys go down (and come up in reverse).
    static let modifierOrder: [(CDPModifiers, CDPKey)] = [
        (.shift, CDPKey.shift), (.control, CDPKey.control), (.alt, CDPKey.alt), (.meta, CDPKey.meta),
    ]

    /// A whole press, for one write: each held modifier's own key goes down
    /// (its event already carries itself, as a browser's does), the key goes
    /// down and up, the modifiers come up in reverse (an up no longer
    /// carries itself).
    public static func keyPress(_ key: CDPKey, mac: Bool = true) -> [(String, [String: Any])] {
        var events: [(String, [String: Any])] = []
        var held: CDPModifiers = []
        var pressed: [(CDPModifiers, CDPKey)] = []
        for (flag, modifierKey) in modifierOrder where key.modifiers.contains(flag) {
            held.insert(flag)
            var down = modifierKey
            down.modifiers = held
            events.append(keyDown(down, mac: mac))
            pressed.append((flag, modifierKey))
        }
        events.append(keyDown(key, mac: mac))
        events.append(keyUp(key))
        for (flag, modifierKey) in pressed.reversed() {
            held.remove(flag)
            var up = modifierKey
            up.modifiers = held
            events.append(keyUp(up))
        }
        return events
    }

    /// One character of `type slowly`: a key the layout has (keyCode != 0)
    /// is pressed; anything else (é, an emoji) is inserted as text, with the
    /// trusted beforeinput and input a person's IME would give.
    public static func typing(_ key: CDPKey, mac: Bool = true) -> [(String, [String: Any])] {
        if key.keyCode == 0, let text = key.text, !text.isEmpty {
            return [insertText(text)]
        }
        return keyPress(key, mac: mac)
    }

    // MARK: - Text and IME

    /// Text as an IME commits it: trusted beforeinput and input
    /// (inputType insertText), no key events. `type` fills a field with it.
    public static func insertText(_ text: String) -> (String, [String: Any]) {
        let params: [String: Any] = ["text": text]
        return ("Input.insertText", params)
    }

    /// The marked text of a composition in progress (a dead key's "^"). It
    /// ends with `insertText` (the composed "ê") or `imeCancel`.
    public static func imeSetComposition(_ text: String, selectionStart: Int, selectionEnd: Int,
                                         replacementStart: Int? = nil,
                                         replacementEnd: Int? = nil) -> (String, [String: Any]) {
        var params: [String: Any] = ["text": text, "selectionStart": selectionStart, "selectionEnd": selectionEnd]
        if let replacementStart { params["replacementStart"] = replacementStart }
        if let replacementEnd { params["replacementEnd"] = replacementEnd }
        return ("Input.imeSetComposition", params)
    }

    /// Abandons the composition: empty marked text.
    public static func imeCancel() -> (String, [String: Any]) {
        imeSetComposition("", selectionStart: 0, selectionEnd: 0)
    }

    /// Commands cut into writes of at most `size` (`type slowly`: 8 keys,
    /// 16 events, per write; each write after the previous one's acks).
    public static func writes(_ commands: [(String, [String: Any])],
                              size: Int = 16) -> [[(String, [String: Any])]] {
        let step = max(1, size)
        var result: [[(String, [String: Any])]] = []
        var index = 0
        while index < commands.count {
            let end = min(index + step, commands.count)
            result.append(Array(commands[index..<end]))
            index = end
        }
        return result
    }
}
