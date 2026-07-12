import SwiftUI

@main
struct SendLogWatchApp: App {
    @State private var auth = AuthManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await OfflineQueue.shared.drain() }
            }
        }
    }
}
