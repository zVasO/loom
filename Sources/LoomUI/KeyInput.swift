import AppKit
import SwiftUI

/// SES-05bis: typing happens IN the agent's field, not in a bar of our
/// own — every keystroke is translated into terminal bytes and sent to the PTY.
/// Pure translation, separate from the view: it is what carries the tests.
public enum KeyTranslator {

    /// Special keys identified by hardware virtual key code (independent of the
    /// keyboard layout). `nil` = ordinary key, to be composed by the view.
    public static func special(keyCode: UInt16, option: Bool) -> String? {
        switch keyCode {
        case 36, 76: return option ? "\u{1b}\r" : "\r"   // Return (+ numeric keypad)
        case 48: return "\t"
        case 51: return "\u{7f}"                          // backspace → DEL
        case 53: return "\u{1b}"
        case 117: return "\u{1b}[3~"                      // forward delete
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 116: return "\u{1b}[5~"
        case 121: return "\u{1b}[6~"
        case 123: return "\u{1b}[D"
        case 124: return "\u{1b}[C"
        case 125: return "\u{1b}[B"
        case 126: return "\u{1b}[A"
        default: return nil
        }
    }

    /// Full translation of a keystroke: special key first, otherwise the text
    /// produced by the actual layout (AZERTY, accents…). `nil` = nothing to send.
    public static func bytes(keyCode: UInt16, characters: String, option: Bool) -> String? {
        if let special = special(keyCode: keyCode, option: option) { return special }
        return characters.isEmpty ? nil : characters
    }
}

/// Invisible zone under the terminal: as first responder it pushes every keystroke
/// to the PTY — typing lives in the agent's field. Ordinary keys
/// go through `interpretKeyEvents` to compose dead keys (ê, î…),
/// ⌘ shortcuts stay with the system, ⌘V pastes into the agent's field.
public struct KeyCaptureView: NSViewRepresentable {
    /// Incremented by the host view when the user clicks the terminal:
    /// explicit signal to reclaim focus, even if a TextField had it.
    let focusTick: Int
    let onText: (String) -> Void

    public init(focusTick: Int = 0, onText: @escaping (String) -> Void) {
        self.focusTick = focusTick
        self.onText = onText
    }

    public func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onText = onText
        return view
    }

    public func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onText = onText
        guard let window = view.window else { return }
        let clicked = view.lastFocusTick != focusTick
        view.lastFocusTick = focusTick
        // Reclaiming focus: on an explicit click, or if nothing is focused anymore —
        // never by stealing it from an active text field (renaming, palette…).
        if clicked || window.firstResponder === window {
            DispatchQueue.main.async { [weak view] in
                view.map { $0.window?.makeFirstResponder($0) }
            }
        }
    }

    public final class CaptureNSView: NSView {
        var onText: ((String) -> Void)?
        var lastFocusTick = 0

        public override var acceptsFirstResponder: Bool { true }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        public override func keyDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.command) else {
                super.keyDown(with: event)
                return
            }
            if let special = KeyTranslator.special(keyCode: event.keyCode,
                                                   option: event.modifierFlags.contains(.option)) {
                onText?(special)
                return
            }
            // Ctrl+letter: the control character is already in characters (⌃C → ETX).
            if event.modifierFlags.contains(.control) {
                if let text = event.characters, !text.isEmpty { onText?(text) }
                return
            }
            // System composition (dead keys, IME) → insertText.
            interpretKeyEvents([event])
        }

        public override func insertText(_ insertString: Any) {
            if let text = insertString as? String {
                onText?(text)
            } else if let attributed = insertString as? NSAttributedString {
                onText?(attributed.string)
            }
        }

        public override func doCommand(by selector: Selector) {
            // The editing selectors are already covered by the special keys;
            // we absorb the rest without triggering the system beep.
        }

        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // ⌘V: paste directly into the agent's field.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v",
               let text = NSPasteboard.general.string(forType: .string) {
                onText?(text)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
