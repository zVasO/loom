import Foundation

// Who a key equivalent belongs to while the page view is first responder
// (panel design §2, ⌘ shortcuts). The page claims an allow-list only;
// everything else falls through to Loom's menus and SwiftUI shortcuts and
// to the system (performKeyEquivalent returns false):
//
// | Chord                      | Goes to                                         |
// |----------------------------|-------------------------------------------------|
// | ⌘C ⌘X ⌘V ⌘A ⌘Z ⌘⇧Z         | the page: the key with its edit command         |
// | ⌘L, ⌘R (⇧: no cache), ⌘[ ⌘] | the panel: address bar, reload, back, forward   |
// | ⌃Tab, ⌃⇧Tab                | out of the page: next / previous key view       |
// | anything else              | not ours (⌘B and other unclaimed chords reach keyDown and go to the page as rawKeyDown with Meta) |
//
// Chords are read by character, as menus match them: ⌘A on AZERTY is the
// key printed A (physical KeyQ).

/// The page's edit commands, from the Edit menu or a ⌘ chord.
public enum PanelEditCommand: String, CaseIterable, Equatable, Sendable {
    case copy, cut, paste, selectAll, undo, redo

    /// The chord a Mac types it with, on the US key it is printed on.
    var chord: (macKeyCode: UInt16, letter: String, code: String, windowsKeyCode: Int, modifiers: CDPModifiers) {
        switch self {
        case .copy: return (0x08, "c", "KeyC", 67, [.meta])
        case .cut: return (0x07, "x", "KeyX", 88, [.meta])
        case .paste: return (0x09, "v", "KeyV", 86, [.meta])
        case .selectAll: return (0x00, "a", "KeyA", 65, [.meta])
        case .undo: return (0x06, "z", "KeyZ", 90, [.meta])
        case .redo: return (0x06, "z", "KeyZ", 90, [.meta, .shift])
        }
    }

    /// Chromium's command name ("selectAll"), from the Mac editing table.
    public var editingCommands: [String] {
        let chord = self.chord
        return MacEditingCommands.commands(code: chord.code, modifiers: chord.modifiers)
    }

    /// The key down with its command (no text: a shortcut types nothing),
    /// then up — together, since AppKit delivers no keyUp under ⌘.
    ///
    /// Never sent for the user's `.paste`: `commands:["paste"]` pastes
    /// Chromium's own clipboard, which every browser context of the process
    /// shares (step-9 probe T-clip). The user's paste goes through the
    /// clipboard bridge (`firePaste`, then `Input.insertText`).
    public var keyEvents: [PanelCDPCommand] {
        let chord = self.chord
        let identity = KeyIdentity(key: chord.letter, code: chord.code, windowsKeyCode: chord.windowsKeyCode)
        return [
            .keyEvent(.rawKeyDown, identity, nativeKeyCode: chord.macKeyCode, modifiers: chord.modifiers,
                      commands: editingCommands),
            .keyEvent(.keyUp, identity, nativeKeyCode: chord.macKeyCode, modifiers: chord.modifiers),
        ]
    }
}

/// What the panel's own chrome does for a chord.
public enum PanelAction: Equatable, Sendable {
    case focusAddress
    case reload(ignoreCache: Bool)
    case back
    case forward
}

public enum PanelShortcut: Equatable, Sendable {
    /// An edit command for the page (copy and cut also capture the copied
    /// text; paste goes through the clipboard bridge).
    case page(PanelEditCommand)
    case panel(PanelAction)
    /// Give the keyboard back: the window's next (true) or previous key view.
    case leave(forward: Bool)
    /// Loom's or the system's: performKeyEquivalent returns false.
    case notOurs

    /// A key equivalent seen by the page view while it is first responder.
    public static func classify(_ press: MacKeyPress) -> PanelShortcut {
        let modifiers = press.modifiers
        if press.keyCode == MacKeyCodes.tab {
            if modifiers == [.control] { return .leave(forward: true) }
            if modifiers == [.control, .shift] { return .leave(forward: false) }
            return .notOurs
        }
        let character = press.charactersIgnoringModifiers.lowercased()
        if modifiers == [.meta] {
            switch character {
            case "c": return .page(.copy)
            case "x": return .page(.cut)
            case "v": return .page(.paste)
            case "a": return .page(.selectAll)
            case "z": return .page(.undo)
            case "l": return .panel(.focusAddress)
            case "r": return .panel(.reload(ignoreCache: false))
            case "[": return .panel(.back)
            case "]": return .panel(.forward)
            default: return .notOurs
            }
        }
        if modifiers == [.meta, .shift] {
            switch character {
            case "z": return .page(.redo)
            case "r": return .panel(.reload(ignoreCache: true))
            default: return .notOurs
            }
        }
        return .notOurs
    }
}
