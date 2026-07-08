import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(BackendClient.self) private var backend
    @Environment(WearableBLEManager.self) private var bleManager
    @Environment(AudioPlaybackController.self) private var playback

    @State private var recordings: [Recording] = []
    @State private var selectedRecording: Recording?
    @State private var isLoading = false
    @State private var isImporterPresented = false
    @State private var errorMessage: String?

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: bleStatusIcon)
                        .foregroundStyle(bleStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wearable sync")
                            .font(.headline)
                        Text(bleManager.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bleManager.isAutoSyncing {
                        ProgressView()
                    }
                }
            }

            Section("Wearable recordings") {
                if bleManager.recordings.isEmpty {
                    Text("Recordings will appear automatically after the wearable saves them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bleManager.recordings) { recording in
                        DashboardWearableRecordingRow(recording: recording)
                    }
                }
            }

            if appState.isBackendEnabled {
                Section {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Upload test recording", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(isLoading ? "Refreshing" : "Refresh cloud recordings", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }

                Section("Cloud recordings") {
                    ForEach(recordings) { recording in
                        NavigationLink(value: recording) {
                            RecordingRow(recording: recording)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "icloud.slash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .navigationDestination(for: Recording.self) { recording in
            RecordingDetailView(recording: selectedRecording ?? recording)
                .task(id: recording.id) {
                    await loadRecording(id: recording.id)
                }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .mpeg4Audio, .wav],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .task {
            if appState.isBackendEnabled {
                await refresh()
            }
        }
        .refreshable {
            bleManager.refreshRecordings()
            if appState.isBackendEnabled {
                await refresh()
            }
        }
        .alert("Playback failed", isPresented: playbackErrorBinding) {
            Button("OK", role: .cancel) { playback.errorMessage = nil }
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }

    private var selectionBinding: Binding<Recording.ID?> {
        @Bindable var appState = appState
        return $appState.selectedRecordingID
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.errorMessage = nil } }
        )
    }

    private var bleStatusIcon: String {
        if case .connected = bleManager.state { return "checkmark.circle.fill" }
        return bleManager.isAutoSyncing ? "antenna.radiowaves.left.and.right" : "circle.dashed"
    }

    private var bleStatusColor: Color {
        if case .connected = bleManager.state { return .green }
        return bleManager.isAutoSyncing ? .blue : .secondary
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            recordings = try await backend.listRecordings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadRecording(id: Recording.ID) async {
        do {
            selectedRecording = try await backend.getRecording(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let uploaded = try await backend.uploadRecording(fileURL: url)
            selectedRecording = uploaded
            appState.selectedRecordingID = uploaded.id
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DashboardWearableRecordingRow: View {
    @Environment(WearableBLEManager.self) private var bleManager
    @Environment(AudioPlaybackController.self) private var playback
    var recording: WearableAudioRecording

    private var transferState: WearableTransferState {
        bleManager.transferState(for: recording)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.filename)
                        .font(.headline)
                        .lineLimit(2)
                    Text(recording.displaySize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(transferState.label, systemImage: stateIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
            }

            if case .downloading(let progress) = transferState {
                ProgressView(value: progress) {
                    Text("BLE transfer")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                .font(.caption)
            } else if case .queued = transferState {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for BLE transfer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let localFileURL = recording.localFileURL {
                Button {
                    playback.play(url: localFileURL)
                } label: {
                    Label(
                        playback.playingURL == localFileURL ? "Pause" : "Play",
                        systemImage: playback.playingURL == localFileURL ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private var stateIcon: String {
        switch transferState {
        case .onWearable: "sdcard"
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .downloaded: "checkmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch transferState {
        case .onWearable: .secondary
        case .queued, .downloading: .blue
        case .downloaded: .green
        }
    }
}

private struct RecordingRow: View {
    var recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recording.originalFilename)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: recording.status)
            }

            HStack(spacing: 12) {
                Label(recording.source.displayName, systemImage: recording.source == .device ? "sensor.tag.radiowaves.forward" : "iphone")
                Text(recording.updatedAt.relativeLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct RecordingDetailView: View {
    var recording: Recording

    private var result: AnalysisResult? { recording.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(status: recording.status)
                    Text(recording.originalFilename)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(recording.deviceID ?? recording.source.displayName)
                        .foregroundStyle(.secondary)
                }

                if let error = recording.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let result {
                    MetricsGrid(result: result)
                    TranscriptPreview(turns: result.transcript ?? [])
                } else {
                    ProcessingPanel(status: recording.status)
                }
            }
            .padding()
        }
        .navigationTitle("Recording")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct MetricsGrid: View {
    var result: AnalysisResult

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricTile(title: "Speakers", value: metric(result.summary?.speakerCount), systemImage: "person.2")
            MetricTile(title: "Words", value: metric(result.summary?.totalWords), systemImage: "text.quote")
            MetricTile(title: "Turns", value: metric(result.summary?.totalTurns), systemImage: "arrow.left.arrow.right")
            MetricTile(title: "Conversation WPM", value: metric(result.summary?.conversationWPM), systemImage: "speedometer")
            MetricTile(title: "Silence", value: percent(result.summary?.silencePercent), systemImage: "pause.circle")
            MetricTile(title: "Questions", value: metric(result.language?.questionCount), systemImage: "questionmark.bubble")
            MetricTile(title: "Fillers / min", value: metric(result.language?.fillersPerMinute), systemImage: "ellipsis.bubble")
            MetricTile(title: "Interjections", value: metric(result.interjections?.estimatedCount), systemImage: "bolt.horizontal")
        }
    }

    private func metric(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func metric(_ value: Double?) -> String {
        value?.shortMetric ?? "-"
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(value.shortMetric)%"
    }
}

private struct TranscriptPreview: View {
    var turns: [TranscriptTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.title2.weight(.semibold))

            if turns.isEmpty {
                Text("Transcript turns will appear after analysis completes.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(turns.prefix(8)) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(turn.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct ProcessingPanel: View {
    var status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Waiting for analysis", systemImage: "hourglass")
                .font(.headline)
            Text("The app keeps the phone experience light. Whisper transcription, diarization, acoustic summaries, and conversation metrics run on the backend, then this view refreshes with the completed result.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension UTType {
    static var wav: UTType {
        UTType(filenameExtension: "wav") ?? .audio
    }
}
