import AppKit
import SwiftUI

@main
struct BunshinApp: App {
    init() {
        // Lancé hors bundle .app (`swift run`), le process est traité en arrière-plan :
        // pas d'icône Dock, fenêtre jamais au premier plan. On force l'activation —
        // sans effet indésirable une fois empaqueté par le wizard de release.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .preferredColorScheme(.dark)
        }
    }
}
