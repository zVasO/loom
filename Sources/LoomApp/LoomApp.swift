import AppKit
import SwiftUI

@main
struct LoomApp: App {
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
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        // La navbar custom occupe le haut de la fenêtre, comme la référence :
        // barre de titre masquée, les feux tricolores flottent dessus.
        .windowStyle(.hiddenTitleBar)
    }
}
