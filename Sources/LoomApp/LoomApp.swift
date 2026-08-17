import AppKit
import SwiftUI

@main
struct LoomApp: App {
    @AppStorage("loom.shortcut.newSession") private var keyNewSession = "n"
    @AppStorage("loom.shortcut.newTab") private var keyNewTab = "t"

    init() {
        // Launched outside an .app bundle (`swift run`), the process is treated as background:
        // no Dock icon, window never in the foreground. We force activation — with no
        // undesirable effect once packaged by the release wizard.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
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
                .keyboardShortcut("n", modifiers: .command)
                Button("New tab in the stack") {
                    NotificationCenter.default.post(name: .loomNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}


extension Notification.Name {
    /// Settings changed the terminal refresh rate.
    static let loomFrameRateChanged = Notification.Name("loom.frameRateChanged")
    /// Settings changed the global or a per-project theme.
    static let loomThemeChanged = Notification.Name("loom.themeChanged")
    /// ⌘N — a claude session in the current project.
    static let loomNewSession = Notification.Name("loom.newSession")
    /// ⌘T — contextual: web tab in the browser, terminal in a session.
    static let loomNewTab = Notification.Name("loom.newTab")
}
