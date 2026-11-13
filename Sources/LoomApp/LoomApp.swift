import AppKit
import SwiftUI

/// Closing the window means quitting: otherwise a headless instance keeps the
/// hook socket and the next launch reports "another instance running".
@MainActor
final class LoomAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The agents' Chromium saves its profiles (cookies, storage) before Loom
    /// goes (ADR-0016): Loom waits for it 1.5 s at most, then quits anyway —
    /// a Chromium still there exits when its pipe closes with Loom.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.live, model.runsAgentChromium else { return .terminateNow }
        Task { @MainActor in
            await model.shutDownAgentChromium(budget: .milliseconds(1_500))
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(LoomAppDelegate.self) private var appDelegate
    @AppStorage("loom.shortcut.newSession") private var keyNewSession = "n"
    @AppStorage("loom.shortcut.newTab") private var keyNewTab = "t"

    init() {
        // Launched outside an .app bundle (`swift run`), the process is treated as background:
        // no Dock icon, window never in the foreground. We force activation — with no
        // undesirable effect once packaged by the release wizard.
        NSApplication.shared.setActivationPolicy(.regular)
        // The app icon in the Dock — set at runtime so even `swift run`
        // (no .app bundle) shows it; the release wizard bakes Assets/loom.icns.
        if let url = Bundle.module.url(forResource: "loom-logo", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = logo
        }
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
        }
        // The custom navbar occupies the top of the window, like the reference:
        // title bar hidden, the traffic lights float on top of it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // The standard Edit menu (copy/paste…) stays intact: we only
            // replace File > New.
            CommandGroup(replacing: .newItem) {
                Button("New claude session") {
                    NotificationCenter.default.post(name: .loomNewSession, object: nil)
                }
                .keyboardShortcut(KeyEquivalent(keyNewSession.first ?? "n"), modifiers: .command)
                // The same letter with ⇧: ask which project first.
                Button("New claude session in…") {
                    NotificationCenter.default.post(name: .loomNewSessionInProject, object: nil)
                }
                .keyboardShortcut(KeyEquivalent(keyNewSession.first ?? "n"), modifiers: [.command, .shift])
                Button("New tab in the stack") {
                    NotificationCenter.default.post(name: .loomNewTab, object: nil)
                }
                .keyboardShortcut(KeyEquivalent(keyNewTab.first ?? "t"), modifiers: .command)
            }
            // ⌘⇧A, not ⌘A: ⌘A stays the agent's own select-all inside its input
            // field, which is the one actually pressed. A menu item rather than a
            // silent key handler — nobody discovers ⌘⇧A on their own.
            CommandGroup(after: .pasteboard) {
                Button("Select All in Terminal") {
                    NotificationCenter.default.post(name: .loomSelectAllTerminal, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            // A menu item, like ⌘⇧A: the breadcrumb's button is an icon, and
            // the menu is where a shortcut gets discovered.
            CommandGroup(after: .sidebar) {
                Button("Show Browser Beside Session") {
                    NotificationCenter.default.post(name: .loomToggleSidePanel, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                // ⌘M is macOS's Minimise; with ⇧ it was nobody's.
                Button("Show Session as Chat") {
                    NotificationCenter.default.post(name: .loomToggleSessionView, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Show Fleet Panel") {
                    NotificationCenter.default.post(name: .loomToggleFleetPanel, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)
            }
        }
    }
}


extension Notification.Name {
    /// Settings changed the terminal refresh rate.
    static let loomFrameRateChanged = Notification.Name("loom.frameRateChanged")
    /// Settings changed the global or a per-project theme.
    static let loomThemeChanged = Notification.Name("loom.themeChanged")
    /// The palette asks to rename the selected session.
    static let loomRenameSession = Notification.Name("loom.renameSession")
    /// ⌘N — a claude session in the current project.
    static let loomNewSession = Notification.Name("loom.newSession")
    /// ⌘⇧N — the project picker first (searchable), then the session.
    static let loomNewSessionInProject = Notification.Name("loom.newSessionInProject")
    /// ⌘T — contextual: web tab in the browser, terminal in a session.
    static let loomNewTab = Notification.Name("loom.newTab")
    /// ⌘⇧A — select everything the terminal pane holds.
    static let loomSelectAllTerminal = Notification.Name("loom.selectAllTerminal")
    /// ⌘⇧B — the browser beside the selected session's terminal.
    static let loomToggleSidePanel = Notification.Name("loom.toggleSidePanel")
    /// ⌘⇧M — the selected session as its terminal, or as its conversation.
    static let loomToggleSessionView = Notification.Name("loom.toggleSessionView")
    /// ⌘J — fold or unfold the fleet panel under the Sessions view.
    static let loomToggleFleetPanel = Notification.Name("loom.toggleFleetPanel")
    /// The theme tour (LOOM_AUTOTEST=themes) asks a view for a state only
    /// it holds — a tab, a panel, a sheet; the object names it.
    static let loomTourShow = Notification.Name("loom.tour.show")
}
