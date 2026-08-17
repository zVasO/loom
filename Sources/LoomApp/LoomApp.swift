import AppKit
import SwiftUI

@main
struct LoomApp: App {
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

/// Settings (⌘,) — the terminal refresh rate. 30 fps default: fluid on any
/// Mac; 60/120 for fast machines now that frame production is cheap.
struct LoomSettingsView: View {
    @AppStorage("loom.terminal.fps") private var fps = 30

    var body: some View {
        Form {
            Picker("Terminal refresh rate", selection: $fps) {
                Text("30 fps — recommended, fluid everywhere").tag(30)
                Text("60 fps — fast Macs").tag(60)
                Text("120 fps — ProMotion, recent Macs").tag(120)
            }
            .pickerStyle(.radioGroup)
            Text("Caps how often terminal frames are produced during streaming. Lower is lighter on CPU; the first frame of any burst is always immediate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: fps) {
            NotificationCenter.default.post(name: .loomFrameRateChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Settings changed the terminal refresh rate.
    static let loomFrameRateChanged = Notification.Name("loom.frameRateChanged")
    /// ⌘N — a claude session in the current project.
    static let loomNewSession = Notification.Name("loom.newSession")
    /// ⌘T — contextual: web tab in the browser, terminal in a session.
    static let loomNewTab = Notification.Name("loom.newTab")
}
