import SwiftUI

@main
struct BunshinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .preferredColorScheme(.dark)
        }
    }
}
