import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case recordings
    case device
    case insights
    case settings

    var id: String { rawValue }

    @MainActor @ViewBuilder
    var label: some View {
        switch self {
        case .recordings:
            Label("Recordings", systemImage: "waveform")
        case .device:
            Label("Device", systemImage: "applewatch.radiowaves.left.and.right")
        case .insights:
            Label("Insights", systemImage: "chart.xyaxis.line")
        case .settings:
            Label("Settings", systemImage: "gearshape")
        }
    }
}

struct AppView: View {
    @Environment(AppState.self) private var appState
    @Environment(BackendClient.self) private var backend
    @Environment(WearableBLEManager.self) private var bleManager
    @Environment(RecordingPipelineCoordinator.self) private var recordingPipeline

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                RecordingsView()
            }
            .tabItem { AppTab.recordings.label }
            .tag(AppTab.recordings)

            NavigationStack {
                DevicePairingView()
            }
            .tabItem { AppTab.device.label }
            .tag(AppTab.device)

            NavigationStack {
                InsightsView()
            }
            .tabItem { AppTab.insights.label }
            .tag(AppTab.insights)

            NavigationStack {
                SettingsView()
            }
            .tabItem { AppTab.settings.label }
            .tag(AppTab.settings)
        }
        .task {
            bleManager.startAutoSyncNearest()
        }
        .task(id: bleManager.latestCompletedDownload?.id) {
            guard let download = bleManager.latestCompletedDownload else { return }
            recordingPipeline.enqueue(
                download,
                backendEnabled: appState.isBackendEnabled,
                backend: backend,
                deviceToken: appState.deviceUploadToken
            )
        }
        .task(id: backendConfigurationID) {
            recordingPipeline.resumeLocalRecordings(
                bleManager.recordings,
                backendEnabled: appState.isBackendEnabled,
                backend: backend,
                deviceToken: appState.deviceUploadToken
            )
        }
        .task(id: recordingPipeline.latestCompletedRecording?.id) {
            guard let completed = recordingPipeline.latestCompletedRecording else { return }
            appState.selectedRecordingID = completed.id
        }
    }

    private var backendConfigurationID: String {
        "\(appState.isBackendEnabled)|\(backend.baseURL.absoluteString)|\(appState.deviceUploadToken)"
    }
}
