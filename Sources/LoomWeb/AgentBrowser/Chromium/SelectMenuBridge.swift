import AppKit
import CoreGraphics
import Foundation
import LoomChromium

// A <select> in the agent's page, as the person opens it from the panel
// (panel design §2, `<select>` popups; step-9 probe T-select). A press that
// reaches a one-line select opens Chromium's own popup, which NO screencast
// frame shows: it then eats arrows and typing, and Enter commits blindly.
// So a plain left press first asks the panel script what is under it
// (`hitInfo`, 50 ms at most — past that the press goes as it is); a single
// enabled select (size ≤ 1, not multiple) gets a Mac menu of its options
// instead, as Chrome itself shows on a Mac, and the choice goes through
// `chooseUserSelect` (focus, then input and change, as the agent's
// selectOption). When Chromium's popup is open already — a press slipped
// through — Escape closes it first: `chooseUserSelect` would leave it open.

/// A one-line <select> as the panel's menu shows it, from `hitInfo`.
struct SelectMenuModel: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// An <optgroup>'s label: a disabled header.
            case header
            /// The option at this index of `select.options`.
            case option(index: Int)
        }

        var kind: Kind
        var title: String
        var enabled: Bool
        /// The select's current option.
        var checked: Bool
        /// Under an <optgroup>'s header.
        var indented: Bool
    }

    /// The select's box, in CSS px of the main frame.
    var rect: CGRect
    var entries: [Entry]
    /// Chromium's own popup is open (a press reached the select).
    var open: Bool

    /// nil unless `hitInfo` found a select the menu stands for: one line
    /// (`size` ≤ 1), one choice (not `multiple`), enabled, with options. A
    /// list box, a multiple select or a base-select picker is drawn in the
    /// page: the press goes to it.
    init?(hitInfo: PanelJSON) {
        guard hitInfo.panelErrorCode == nil, let select = hitInfo["select"],
              select["multiple"]?.boolValue != true, select["disabled"]?.boolValue != true,
              (select["size"]?.doubleValue ?? 0) <= 1,
              let options = select["options"]?.arrayValue, !options.isEmpty,
              let box = select["rect"], let rect = UserInputPump.rect(box) else { return nil }
        let selected = select["selectedIndex"]?.intValue ?? -1
        var entries: [Entry] = []
        var group: String?
        for (index, option) in options.enumerated() {
            let optionGroup = option["group"]?.stringValue
            if optionGroup != group {
                group = optionGroup
                if let optionGroup {
                    entries.append(Entry(kind: .header, title: optionGroup, enabled: false, checked: false,
                                         indented: false))
                }
            }
            entries.append(Entry(kind: .option(index: index), title: option["label"]?.stringValue ?? "",
                                 enabled: option["disabled"]?.boolValue != true, checked: index == selected,
                                 indented: optionGroup != nil))
        }
        self.rect = rect
        self.entries = entries
        self.open = select["open"]?.boolValue == true
    }
}

enum SelectMenuBridge {

    /// How long a plain left press waits for `hitInfo` before it goes as it is.
    static let probeBudget: Duration = .milliseconds(50)
    /// The second look, on the release of a press whose probe came late.
    static let recheckBudget: Duration = .milliseconds(150)
    static let chooseBudget: Duration = .milliseconds(500)

    /// A plain left press — one click, no modifier — is the only one asked
    /// about first: a double click, a right or a modified click goes at once.
    static func probes(_ event: MacMouseEvent) -> Bool {
        event.buttonNumber == 0 && event.clickCount <= 1 && event.modifiers.isEmpty
    }

    /// Escape down and up: what closes Chromium's own popup (only the keyUp
    /// reaches the page).
    static var escapeKeys: [PanelCDPCommand] {
        let escape = KeyIdentity(key: "Escape", code: "Escape", windowsKeyCode: 27)
        return [
            .keyEvent(.rawKeyDown, escape, nativeKeyCode: MacKeyCodes.escape, modifiers: []),
            .keyEvent(.keyUp, escape, nativeKeyCode: MacKeyCodes.escape, modifiers: []),
        ]
    }

    /// The Mac menu: optgroups as disabled headers, their options indented,
    /// the current option checked; an option's tag is its index.
    @MainActor
    static func menu(for model: SelectMenuModel, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in model.entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            switch entry.kind {
            case .header:
                item.isEnabled = false
            case .option(let index):
                item.tag = index
                item.target = target
                item.action = action
                item.isEnabled = entry.enabled
                item.state = entry.checked ? .on : .off
                item.indentationLevel = entry.indented ? 1 : 0
            }
            menu.addItem(item)
        }
        return menu
    }
}

/// The menu's choice, handed over once: by the chosen item's action, or as
/// nil when the menu closed without one.
@MainActor
final class SelectMenuChoice: NSObject {
    private var completion: (@MainActor (Int?) -> Void)?

    init(completion: @escaping @MainActor (Int?) -> Void) {
        self.completion = completion
        super.init()
    }

    @objc func choose(_ sender: NSMenuItem) {
        finish(sender.tag)
    }

    func finish(_ index: Int?) {
        let handler = completion
        completion = nil
        handler?(index)
    }
}

// MARK: - The pump's side

extension UserInputPump {

    /// A plain left press on the page: what is under it first. Meanwhile
    /// events queue behind it (its release among them).
    func probeSelect(_ event: MacMouseEvent, geometry: ScreencastGeometry, at point: CGPoint) {
        raiseBarrier()
        let expected = generation
        let turn = takeovers
        startFlow { [weak self] in
            guard let self else { return }
            var answer: PanelJSON?
            if let host = self.host, let tab = self.tab {
                answer = await host.panelQuery("hitInfo", UserInputPump.hitArguments(point), on: tab,
                                               timeout: SelectMenuBridge.probeBudget)
            }
            guard expected == self.generation else { return }
            if turn != self.takeovers {
                // The agent acted meanwhile: this press came before it, and
                // goes nowhere (its release finds nothing held).
            } else if let answer, let menu = SelectMenuModel(hitInfo: answer) {
                // The press is the person's on the page, but goes as a menu.
                if self.admit(.mouseDown(.left)) {
                    await self.bridge(menu, at: point, generation: expected)
                }
            } else {
                // No answer in time: the press goes, and its release looks again.
                self.forwardPress(event, geometry: geometry, button: .left)
                let wentOut = self.gate.heldButtons.contains(.left)
                self.slippedPress = answer == nil && wentOut ? point : nil
            }
            self.lowerBarrier(generation: expected)
        }
    }

    /// The release of a press whose probe came late: if it opened a select's
    /// popup, Escape closes it and the Mac menu shows instead.
    func recheckSelect(at point: CGPoint) {
        guard gate.isOpen, host != nil, tab != nil else { return }
        raiseBarrier()
        let expected = generation
        let turn = takeovers
        startFlow { [weak self] in
            guard let self else { return }
            var answer: PanelJSON?
            if let host = self.host, let tab = self.tab {
                answer = await host.panelQuery("hitInfo", UserInputPump.hitArguments(point), on: tab,
                                               timeout: SelectMenuBridge.recheckBudget)
            }
            guard expected == self.generation else { return }
            if turn == self.takeovers, let answer, let menu = SelectMenuModel(hitInfo: answer), menu.open {
                await self.bridge(menu, at: point, generation: expected)
            }
            self.lowerBarrier(generation: expected)
        }
    }

    /// Chromium's popup closed if open, the menu shown, the choice set.
    /// Nothing while the page is not the person's (the agent took it during
    /// the probe): no Escape among the agent's own input, no menu.
    private func bridge(_ menu: SelectMenuModel, at point: CGPoint, generation expected: Int) async {
        guard expected == generation, gate.isOpen else { return }
        if menu.open {
            forward(SelectMenuBridge.escapeKeys)
        }
        guard let viewer else { return }
        let chosen: Int? = await withCheckedContinuation { continuation in
            viewer.pumpChoose(from: menu) { index in
                continuation.resume(returning: index)
            }
        }
        // The choice is the person's input now: the agent may hold the page
        // (its notice), or another page came.
        guard expected == generation, let index = chosen, admit(.mouseDown(.left)),
              let host, let tab else { return }
        // `chooseUserSelect` acts on the panel script's LAST hit, which a
        // cursor sample may have moved since the probe: hit the select again
        // first — and only if it is still there.
        guard let again = await host.panelQuery("hitInfo", UserInputPump.hitArguments(point), on: tab,
                                                timeout: SelectMenuBridge.chooseBudget),
              SelectMenuModel(hitInfo: again) != nil,
              expected == generation, gate.isOpen else { return }
        noteActed()
        let argument: PanelJSON = .object(["index": .number(Double(index))])
        _ = await host.panelQuery("chooseUserSelect", argument, on: tab, timeout: SelectMenuBridge.chooseBudget)
    }
}
