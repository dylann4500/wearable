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
    @Environment(WearableBLEManager.self) private var bleManager

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
    }
}
