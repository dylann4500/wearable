import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(BackendClient.self) private var backend

    @State private var recordings: [Recording] = MockData.recordings
    @State private var selectedRecording: Recording?
    @State private var isLoading = false
    @State private var isImporterPresented = false
    @State private var errorMessage: String?

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Upload test recording", systemImage: "square.and.arrow.up")
                }

                Button {
                    Task { await refresh() }
                } label: {
                    Label(isLoading ? "Refreshing" : "Refresh recordings", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            Section("Recent recordings") {
                ForEach(recordings) { recording in
                    NavigationLink(value: recording) {
                        RecordingRow(recording: recording)
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
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Wearable uploads and phone test uploads will appear here.")
                )
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .mpeg4Audio, .wav],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .alert("Backend unavailable", isPresented: hasError) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private var selectionBinding: Binding<Recording.ID?> {
        @Bindable var appState = appState
        return $appState.selectedRecordingID
    }

    private var hasError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
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
