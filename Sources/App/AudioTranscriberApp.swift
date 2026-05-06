import SwiftUI

@main
struct VoiceScribeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 800, height: 650)
    }
}
