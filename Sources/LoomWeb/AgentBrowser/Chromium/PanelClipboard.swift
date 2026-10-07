import AppKit
import Foundation
import LoomChromium

// Copy, cut and paste between the agent's page and the Mac (panel design
// §2, Clipboard; step-9 probe T-clip and "Clipboard scope").
//
// Copy and cut: the chord goes to the page as the key with its command
// (rawKeyDown + keyUp, commands ["copy"] / ["cut"]) — the page gets a
// trusted copy event and may set its own data. Once the keys are answered,
// the panel script's `takeCopied` says what was copied; under a second old,
// it goes on NSPasteboard.general. (Chromium's own clipboard gets it too:
// a copy writes it whatever Loom does.)
//
// Paste: NEVER the "paste" command. Chromium keeps one clipboard per
// browser process, shared by every browser context in it: a paste command
// would read whatever any session of that Chromium copied. The Mac's
// pasteboard text is offered to the page as a `paste` event (`firePaste`);
// unless the page cancels it (a one-time-code field splitting it itself),
// `Input.insertText` types it. Keys typed meanwhile wait behind it.

/// The Mac's pasteboard as the panel reads and writes it (a test's fake).
@MainActor
protocol PanelPasteboard: AnyObject {
    /// Its plain text, if any.
    func string() -> String?
    /// Replaces its contents with plain text.
    func setString(_ text: String)
}

/// NSPasteboard.general.
@MainActor
final class SystemPanelPasteboard: PanelPasteboard {
    func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func setString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

enum PanelClipboard {

    /// A copy older than this was not the person's chord (`takeCopied`'s ageMs).
    static let freshness: Double = 1_000
    /// How long the copy's keys, or the keys before a paste, may take to be answered.
    static let keysBudget: Duration = .seconds(1)
    static let takeBudget: Duration = .milliseconds(300)
    static let pasteBudget: Duration = .seconds(1)
    static let pasteRefused = "The page did not answer the paste — try again."

    /// `takeCopied`'s answer worth the Mac's pasteboard: text, under a second old.
    static func copiedText(_ answer: PanelJSON?) -> String? {
        guard let answer, answer.panelErrorCode == nil, let text = answer["text"]?.stringValue, !text.isEmpty,
              let age = answer["ageMs"]?.doubleValue, age >= 0, age < freshness else { return nil }
        return text
    }

    /// After `firePaste`: the text is typed unless the page cancelled the
    /// event — and not when the page gave no answer at all.
    static func insertsAfterPaste(_ answer: PanelJSON?) -> Bool {
        guard let answer, answer.panelErrorCode == nil, let cancelled = answer["cancelled"]?.boolValue else {
            return false
        }
        return !cancelled
    }
}

// MARK: - The pump's side

extension UserInputPump {

    /// Copy, cut, paste, select all, undo, redo — from the Edit menu or a ⌘
    /// chord the page view claimed.
    func editCommand(_ command: PanelEditCommand) {
        enqueue { [weak self] in
            guard let self, self.admit(.editCommand) else { return }
            switch command {
            case .paste:
                // Noted once the page had its paste event.
                self.paste()
            case .copy, .cut:
                self.noteActed()
                self.forward(command.keyEvents)
                self.captureCopied()
            case .selectAll, .undo, .redo:
                self.noteActed()
                self.forward(command.keyEvents)
            }
        }
    }

    /// Whether the Edit menu's item for `command` is enabled: the gate would
    /// let it through.
    func canPerform(_ command: PanelEditCommand) -> Bool {
        gate.isOpen
    }

    /// Once the copy's keys are answered: what the page copied, to the Mac's
    /// pasteboard while fresh.
    /// Nothing once the agent acted since the chord: what the page holds
    /// as copied may be its doing by then.
    private func captureCopied() {
        let expected = generation
        let turn = takeovers
        startFlow { [weak self] in
            guard let self else { return }
            await self.wire?.drain(within: PanelClipboard.keysBudget)
            guard expected == self.generation, turn == self.takeovers, let host = self.host, let tab = self.tab else {
                return
            }
            let answer = await host.panelQuery("takeCopied", .null, on: tab, timeout: PanelClipboard.takeBudget)
            guard expected == self.generation, turn == self.takeovers,
                  let text = PanelClipboard.copiedText(answer) else { return }
            self.pasteboard.setString(text)
        }
    }

    /// The Mac's text offered to the page as a paste event, then typed —
    /// the keys after it wait. Nothing of it once the agent acted since ⌘V:
    /// the page, its focus, may be the agent's doing by then.
    private func paste() {
        guard let text = pasteboard.string(), !text.isEmpty else { return }
        raiseBarrier()
        let expected = generation
        let turn = takeovers
        startFlow { [weak self] in
            guard let self else { return }
            // The keys typed before ⌘V reach the field first.
            await self.wire?.drain(within: PanelClipboard.keysBudget)
            var answer: PanelJSON?
            if expected == self.generation, turn == self.takeovers, let host = self.host, let tab = self.tab {
                answer = await host.panelQuery("firePaste", .object(["text": .string(text)]), on: tab,
                                               timeout: PanelClipboard.pasteBudget)
            }
            guard expected == self.generation else { return }
            if turn != self.takeovers || !self.gate.isOpen {
                // The agent took the page (or a dialog came): say why, if it still holds it.
                if !self.gate.isOpen {
                    _ = self.admit(.editCommand)
                }
            } else {
                if answer != nil {
                    // The page had its paste event, whatever it made of it.
                    self.noteActed()
                }
                if PanelClipboard.insertsAfterPaste(answer) {
                    self.forward([.insertText(text)])
                } else if answer == nil {
                    self.host?.showInputNotice(PanelClipboard.pasteRefused)
                }
            }
            self.lowerBarrier(generation: expected)
        }
    }
}
