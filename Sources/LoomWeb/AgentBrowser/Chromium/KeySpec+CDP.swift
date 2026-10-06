import Foundation
import LoomChromium

/// `browser_press_key` and `browser_type slowly` as trusted input (ADR-0015):
/// a `KeySpec` as `CDPInput` sends it.
///
/// "ControlOrMeta" is already Meta: `KeySpec.parse` reads it so, Loom runs
/// on a Mac. The Mac editing commands (Meta+A selectAll, Meta+C/V copy and
/// paste, Alt+Backspace…) go with the combinations `MacEditingCommands`
/// lists and with no other: Chromium runs any command it is given, whatever
/// the modifiers (step-0 probe: a plain "a" carrying selectAll selects all).
extension KeySpec {

    /// The key's modifiers as `Input.dispatchKeyEvent` counts them.
    public var cdpModifiers: CDPModifiers {
        var modifiers: CDPModifiers = []
        if shiftKey { modifiers.insert(.shift) }
        if ctrlKey { modifiers.insert(.control) }
        if altKey { modifiers.insert(.alt) }
        if metaKey { modifiers.insert(.meta) }
        return modifiers
    }

    /// The key as `CDPInput` builds its events. Its text stays as parsed:
    /// `CDPKey.typedText` gives Enter its "\r" and drops the text of a
    /// shortcut (Control, Meta or Alt held).
    public var cdpKey: CDPKey {
        CDPKey(key: key, code: code, keyCode: keyCode, text: text, modifiers: cdpModifiers)
    }

    /// A whole press, for one write: the held modifiers go down, the key
    /// goes down and up, the modifiers come up in reverse.
    public func cdpPress(mac: Bool = true) -> [(String, [String: Any])] {
        CDPInput.keyPress(cdpKey, mac: mac)
    }

    /// One character of `type slowly`: pressed when the layout has the key,
    /// inserted as text otherwise (é, an emoji).
    public func cdpTyping(mac: Bool = true) -> [(String, [String: Any])] {
        CDPInput.typing(cdpKey, mac: mac)
    }

    /// `text` typed key by key, as writes of `keysPerWrite` keys each — the
    /// design's 8 keys (16 events) per write. A key's events never straddle
    /// two writes; each write goes after the previous one's acks, so a
    /// dialog a key opens stops the rest.
    public static func cdpTypingWrites(_ text: String, keysPerWrite: Int = 8,
                                       mac: Bool = true) -> [[(String, [String: Any])]] {
        let size = max(1, keysPerWrite)
        var writes: [[(String, [String: Any])]] = []
        var current: [(String, [String: Any])] = []
        var keys = 0
        for character in text {
            current.append(contentsOf: KeySpec.typing(character).cdpTyping(mac: mac))
            keys += 1
            if keys == size {
                writes.append(current)
                current = []
                keys = 0
            }
        }
        if !current.isEmpty {
            writes.append(current)
        }
        return writes
    }
}
