import SwiftUI

@main
struct WearableCompanionApp: App {
    @State private var appState = AppState()
    @State private var backend = BackendClient(baseURL: URL(string: "http://192.168.4.97:8000")!)
    @State private var bleManager = WearableBLEManager()
    @State private var audioPlayback = AudioPlaybackController()
    @State private var recordingPipeline = RecordingPipelineCoordinator()

    var body: some Scene {
        WindowGroup {
            AppView()
                .environment(appState)
                .environment(backend)
                .environment(bleManager)
                .environment(audioPlayback)
                .environment(recordingPipeline)
        }
    }
}
