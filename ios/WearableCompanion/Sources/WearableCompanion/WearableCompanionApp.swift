import SwiftUI

@main
struct WearableCompanionApp: App {
    @State private var appState = AppState()
    @State private var bleManager = WearableBLEManager()
    @State private var audioPlayback = AudioPlaybackController()

    var body: some Scene {
        WindowGroup {
            AppView()
                .environment(appState)
                .environment(BackendClient(baseURL: appState.backendBaseURL))
                .environment(bleManager)
                .environment(audioPlayback)
        }
    }
}
