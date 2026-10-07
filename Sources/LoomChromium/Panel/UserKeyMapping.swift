import Foundation

// The user's keyboard in the panel → DevTools key, IME and text commands,
// with Chrome-on-Mac semantics (panel design §2, Keyboard). The page view
// calls interpretKeyEvents in keyDown — AppKit applies the user's key
// bindings and input method — collects what AppKit called back
// (`KeyAction`), and this maps the press and the collected actions:
//
// | AppKit did, during the keyDown               | CDP                                          |
// |----------------------------------------------|----------------------------------------------|
// | setMarkedText(s, sel)                        | imeSetComposition(s, sel); no key event      |
// | insertText(t) while composing                | insertText(t) (commits)                      |
// | unmarkText while composing                   | insertText(marked)                           |
// | insertText(t), not composing, t = characters | keyDown with text t                          |
// | insertText(t) otherwise                      | insertText(t)                                |
// | doCommand(sel…)                              | rawKeyDown with commands (Enter: keyDown "\r", vk 13; Tab: vk 9) |
// | nothing                                      | rawKeyDown                                   |
//
// A keyUp goes only for a key whose keyDown went out as a key event; the
// modifier keys go down and up through flagsChanged.

/// One NSEvent of the keyboard, as the mapping needs it.
public struct MacKeyPress: Equatable, Sendable {
    /// NSEvent.keyCode: the physical key (Carbon's kVK_*).
    public var keyCode: UInt16
    /// NSEvent.characters: what the key types under its modifiers ("" for a dead key).
    public var characters: String
    /// NSEvent.charactersIgnoringModifiers: under no modifier but Shift.
    public var charactersIgnoringModifiers: String
    /// The modifier flags after the event (for flagsChanged: the new state).
    public var modifiers: CDPModifiers
    public var isARepeat: Bool

    public init(keyCode: UInt16, characters: String = "", charactersIgnoringModifiers: String? = nil,
                modifiers: CDPModifiers = [], isARepeat: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.modifiers = modifiers
        self.isARepeat = isARepeat
    }

    /// What the page reads of the key.
    public var identity: KeyIdentity {
        MacKeyCodes.identity(keyCode: keyCode, characters: characters,
                             charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers)
    }
}

/// What AppKit called on the page view's NSTextInputClient side, in order.
public enum KeyAction: Equatable, Sendable {
    case insertText(String)
    /// The marked text and its selection (NSRange's location and length, in
    /// UTF-16 units, as CDP's selectionStart / selectionEnd are).
    case setMarkedText(String, selectedLocation: Int, selectedLength: Int)
    case unmarkText
    /// A selector name with its colon: "deleteBackward:", "insertNewline:".
    case doCommand(String)
}

/// The panel's keyboard state: the marked text of a composition in
/// progress, and the keys whose keyDown reached the page.
public struct UserKeyMapping: Equatable, Sendable {

    /// The composition in progress; nil when none.
    public private(set) var markedText: String?
    /// Mac key code → the key as its keyDown went out (its keyUp says the same).
    public private(set) var forwarded: [UInt16: KeyIdentity] = [:]
    /// Keys pressed with Command down: AppKit never delivers their keyUp,
    /// so they come up just before Command does.
    public private(set) var pressedUnderCommand: Set<UInt16> = []

    public init() {}

    public var composing: Bool {
        markedText != nil
    }

    /// The keys whose keyUp would go.
    public var forwardedKeyCodes: Set<UInt16> {
        Set(forwarded.keys)
    }

    // MARK: - Keys

    public mutating func keyDown(_ press: MacKeyPress, actions: [KeyAction]) -> [PanelCDPCommand] {
        let wasComposing = composing
        var identity = press.identity
        var commands: [PanelCDPCommand] = []
        var selectors: [String] = []
        var keyText: String?
        var keyEventIndex = 0
        // The input method or a plain insertion took the key.
        var handled = false

        for action in actions {
            switch action {
            case .setMarkedText(let text, let location, let length):
                commands.append(Self.composition(text, location: location, length: length))
                markedText = text.isEmpty ? nil : text
                handled = true
            case .insertText(let text):
                if composing {
                    commands.append(.insertText(text))
                    markedText = nil
                    handled = true
                } else if !wasComposing, !handled, keyText == nil, !text.isEmpty, text == press.characters {
                    keyText = text
                    keyEventIndex = commands.count
                } else if !text.isEmpty {
                    commands.append(.insertText(text))
                    handled = true
                }
            case .unmarkText:
                if let marked = markedText {
                    commands.append(.insertText(marked))
                    markedText = nil
                    handled = true
                }
            case .doCommand(let selector):
                selectors.append(selector)
            }
        }

        let editing = Self.chromiumCommands(selectors: selectors)
        let event: PanelCDPCommand
        if let keyText {
            event = .keyEvent(.keyDown, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers,
                              text: keyText, autoRepeat: press.isARepeat, commands: editing)
        } else if !selectors.isEmpty {
            keyEventIndex = commands.count
            if selectors.contains(where: { Self.newlineSelectors.contains($0) }) {
                identity.windowsKeyCode = 13
                event = .keyEvent(.keyDown, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers,
                                  text: "\r", autoRepeat: press.isARepeat, commands: editing)
            } else {
                if selectors.contains(where: { Self.tabSelectors.contains($0) }) {
                    identity.windowsKeyCode = 9
                }
                event = .keyEvent(.rawKeyDown, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers,
                                  autoRepeat: press.isARepeat, commands: editing)
            }
        } else if !handled, !wasComposing {
            // Nothing from AppKit (F-keys…): the bare key. During a
            // composition the input method ate it.
            keyEventIndex = commands.count
            event = .keyEvent(.rawKeyDown, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers,
                              autoRepeat: press.isARepeat)
        } else {
            return commands
        }
        commands.insert(event, at: keyEventIndex)
        forwarded[press.keyCode] = identity
        if press.modifiers.contains(.meta) {
            pressedUnderCommand.insert(press.keyCode)
        } else {
            pressedUnderCommand.remove(press.keyCode)
        }
        return commands
    }

    /// Only for a key whose keyDown reached the page.
    public mutating func keyUp(_ press: MacKeyPress) -> [PanelCDPCommand] {
        guard let identity = forwarded.removeValue(forKey: press.keyCode) else { return [] }
        pressedUnderCommand.remove(press.keyCode)
        return [.keyEvent(.keyUp, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers)]
    }

    /// Shift, Control, Option, Command or Caps Lock: down when it was not,
    /// up when its down went out. Caps Lock goes down when the lock engages
    /// and up when it releases, as Chrome on a Mac reports it. Command's up
    /// first brings up the keys pressed under it (their keyUp never came).
    public mutating func flagsChanged(_ press: MacKeyPress) -> [PanelCDPCommand] {
        guard MacKeyCodes.isModifierKey(press.keyCode), let entry = MacKeyCodes.entry(press.keyCode) else { return [] }
        if let identity = forwarded.removeValue(forKey: press.keyCode) {
            var commands: [PanelCDPCommand] = []
            if MacKeyCodes.modifierFlag(press.keyCode) == CDPModifiers.meta, !press.modifiers.contains(.meta) {
                for keyCode in pressedUnderCommand.sorted() {
                    guard let held = forwarded.removeValue(forKey: keyCode) else { continue }
                    commands.append(.keyEvent(.keyUp, held, nativeKeyCode: keyCode,
                                              modifiers: press.modifiers.union(.meta)))
                }
                pressedUnderCommand = []
            }
            commands.append(.keyEvent(.keyUp, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers))
            return commands
        }
        if let flag = MacKeyCodes.modifierFlag(press.keyCode), !press.modifiers.contains(flag) {
            // The release of a key pressed before the page had the keys.
            return []
        }
        let identity = KeyIdentity(key: entry.namedKey ?? "", code: entry.code,
                                   windowsKeyCode: entry.windowsKeyCode, location: entry.location)
        forwarded[press.keyCode] = identity
        return [.keyEvent(.rawKeyDown, identity, nativeKeyCode: press.keyCode, modifiers: press.modifiers)]
    }

    // MARK: - Text outside a keyDown

    /// What AppKit calls on its own — the emoji picker, dictation, a
    /// candidate clicked in an input method's window: text and marked text,
    /// never a key event (a command without its key is dropped).
    public mutating func text(_ actions: [KeyAction]) -> [PanelCDPCommand] {
        var commands: [PanelCDPCommand] = []
        for action in actions {
            switch action {
            case .insertText(let text):
                if composing || !text.isEmpty {
                    commands.append(.insertText(text))
                }
                markedText = nil
            case .setMarkedText(let text, let location, let length):
                if composing || !text.isEmpty {
                    commands.append(Self.composition(text, location: location, length: length))
                }
                markedText = text.isEmpty ? nil : text
            case .unmarkText:
                if let marked = markedText {
                    commands.append(.insertText(marked))
                    markedText = nil
                }
            case .doCommand:
                break
            }
        }
        return commands
    }

    /// The page view resigns first responder: the marked text is committed
    /// (the view then discards it from its input context).
    public mutating func commitComposition() -> [PanelCDPCommand] {
        text([.unmarkText])
    }

    /// The agent took the page (`UserInputGate.agentWillAct` released the
    /// keys and cancelled the composition): nothing is held or marked any more.
    public mutating func agentTookOver() {
        markedText = nil
        forwarded = [:]
        pressedUnderCommand = []
    }

    // MARK: - Pure parts

    /// The selectors that type a line break: the key goes as keyDown "\r",
    /// keyCode 13 — the only Enter a form submits on.
    public static let newlineSelectors: Set<String> = [
        "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:",
    ]

    /// The selectors that move the focus: rawKeyDown, keyCode 9.
    public static let tabSelectors: Set<String> = ["insertTab:", "insertBacktab:"]

    /// Chromium's names for `Input.dispatchKeyEvent.commands`: the colon
    /// dropped, and neither insert* (the key's own text inserts) nor noop
    /// (an unbound ⌘ chord) — Playwright's crInput.ts rule.
    public static func chromiumCommands(selectors: [String]) -> [String] {
        selectors.compactMap { selector in
            let name = selector.hasSuffix(":") ? String(selector.dropLast()) : selector
            if name.isEmpty || name.hasPrefix("insert") || name == "noop" { return nil }
            return name
        }
    }

    /// The edit command a menu item or a ⌘ shortcut sends (⌘A, ⌘C…): the
    /// key down with the command, then up.
    public static func editCommand(_ command: PanelEditCommand) -> [PanelCDPCommand] {
        command.keyEvents
    }

    /// `Input.imeSetComposition` for marked text and its NSRange selection,
    /// clamped to the text (NSNotFound puts the caret at its end).
    static func composition(_ text: String, location: Int, length: Int) -> PanelCDPCommand {
        let count = text.utf16.count
        let start = min(max(0, location), count)
        let end = length >= count - start ? count : start + max(0, length)
        return .imeSetComposition(text, selectionStart: start, selectionEnd: end)
    }
}
