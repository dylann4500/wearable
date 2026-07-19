import SwiftUI

struct InsightsView: View {
    @Environment(AppState.self) private var appState
    @Environment(BackendClient.self) private var backend
    @Environment(RecordingPipelineCoordinator.self) private var recordingPipeline

    @State private var recording: Recording?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Conversation coaching should start as evidence, not diagnosis.")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !appState.isBackendEnabled {
                    ContentUnavailableView(
                        "Backend processing is off",
                        systemImage: "icloud.slash",
                        description: Text("Enable the backend in Settings. Verified wearable audio will remain queued on this iPhone until processing is available.")
                    )
                } else if isLoading, recording == nil {
                    ProgressView("Loading conversation analysis…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let errorMessage, recording == nil {
                    ContentUnavailableView(
                        "Insights unavailable",
                        systemImage: "exclamationmark.icloud",
                        description: Text(errorMessage)
                    )
                } else if let recording {
                    RecordingInsightContent(recording: recording)
                } else {
                    ContentUnavailableView(
                        "No analyzed recordings",
                        systemImage: "waveform.badge.magnifyingglass",
                        description: Text("Record on the wearable or upload an audio file. Insights appear after backend transcription and analysis finish.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Insights")
        .toolbar {
            Button {
                Task { await loadRecording(preferLatest: true) }
            } label: {
                Label("Refresh insights", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading || !appState.isBackendEnabled)
        }
        .task(id: refreshID) {
            await loadRecording()
        }
    }

    private var refreshID: String {
        [
            appState.isBackendEnabled.description,
            appState.selectedRecordingID ?? "latest",
            recordingPipeline.latestCompletedRecording?.id ?? "none",
            backend.baseURL.absoluteString,
        ].joined(separator: "|")
    }

    private func loadRecording(preferLatest: Bool = false) async {
        guard appState.isBackendEnabled else {
            recording = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if !preferLatest, let selectedID = appState.selectedRecordingID {
                recording = try await backend.getRecording(id: selectedID)
                return
            }

            if let completed = recordingPipeline.latestCompletedRecording,
               completed.result?.insights != nil {
                recording = completed
                appState.selectedRecordingID = completed.id
                return
            }

            let recordings = try await backend.listRecordings()
            guard let candidate = recordings.first(where: { $0.status == .complete }) ?? recordings.first else {
                recording = nil
                return
            }
            recording = try await backend.getRecording(id: candidate.id)
            appState.selectedRecordingID = candidate.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecordingInsightContent: View {
    var recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.originalFilename)
                        .font(.headline)
                    Text(recording.updatedAt.relativeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: recording.status)
            }

            if let error = recording.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if recording.status != .complete {
                ProcessingInsightPanel(status: recording.status)
            } else if let result = recording.result,
                      let insights = result.insights,
                      !insights.displayScores.isEmpty {
                if let context = insights.context ?? result.interpretation?.context {
                    ContextPanel(context: context, interpretation: result.interpretation)
                }

                RawMetricSummary(result: result)
                AnalysisDiagnosticsPanel(result: result)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Conversation intelligence insights")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        if let confidence = insights.confidence {
                            Text("\(Int((confidence * 100).rounded()))% confidence")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(orderedScores(insights), id: \.0) { name, score in
                        InsightScoreCard(name: name, item: score)
                    }
                }

                if let interpretation = result.interpretation {
                    InterpretationPanel(interpretation: interpretation)
                }

                Text("These scores are explainable coaching hypotheses derived from transcript, turn-taking, acoustic, and language features. They are not clinical or psychological diagnoses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Analysis result is incomplete",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("The backend completed this recording without a compatible `insights` result. Check the analyzer version and API contract.")
                )
            }
        }
    }

    private func orderedScores(_ insights: InsightResult) -> [(String, InsightScore)] {
        let preferred = [
            "warmth",
            "curiosity",
            "conversational_balance",
            "respectful_disagreeability",
            "emotional_regulation",
            "clarity",
            "conversational_generosity",
        ]
        let scores = insights.displayScores
        return scores.sorted { left, right in
            let leftIndex = preferred.firstIndex(of: left.key) ?? preferred.count
            let rightIndex = preferred.firstIndex(of: right.key) ?? preferred.count
            return leftIndex == rightIndex ? left.key < right.key : leftIndex < rightIndex
        }
    }
}

private struct AnalysisDiagnosticsPanel: View {
    var result: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analysis diagnostics")
                .font(.headline)
            LabeledContent("Transcription model", value: result.metadata?.model ?? "Unknown")
            LabeledContent("Diarization", value: diarizationLabel)
            LabeledContent("Detected speakers", value: speakerCount)
            LabeledContent("Audio confidence", value: (result.audioQuality?.confidence ?? "unknown").capitalized)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var diarizationLabel: String {
        let diarization = result.metadata?.diarization
        if diarization?.enabled == true { return "Enabled" }
        return (diarization?.status ?? "Disabled").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var speakerCount: String {
        let value = result.metadata?.diarization?.displayedSpeakerCount
            ?? result.metadata?.diarization?.speakerCount
            ?? result.summary?.speakerCount
        return value.map(String.init) ?? "Unknown"
    }
}

private struct ProcessingInsightPanel: View {
    var status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
            Text(status == .uploaded ? "Audio uploaded" : "Analyzing conversation")
                .font(.headline)
            Text("The backend is running audio conversion, transcription, speaker diarization, feature extraction, and insight scoring.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RawMetricSummary: View {
    var result: AnalysisResult

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            MetricTile(title: "Focus talk share", value: talkShare, systemImage: "chart.pie", tint: .blue)
            MetricTile(title: "Response latency", value: seconds(result.turnTaking?.averageResponseLatencySeconds), systemImage: "timer", tint: .orange)
            MetricTile(title: "Follow-ups", value: int(result.language?.followUpQuestionEstimate), systemImage: "arrowshape.turn.up.left.2", tint: .green)
            MetricTile(title: "Long pauses", value: int(result.silenceAndPauses?.longPausesOver2Seconds), systemImage: "pause.rectangle", tint: .purple)
        }
    }

    private var talkShare: String {
        let focus = result.insights?.speakerFocus ?? result.summary?.userSpeakerAssumption ?? "Speaker 1"
        guard let share = result.speakers?[focus]?.talkTimePercent else { return "-" }
        return "\(share.shortMetric)%"
    }

    private func seconds(_ value: Double?) -> String {
        value.map { "\($0.shortMetric)s" } ?? "-"
    }

    private func int(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }
}

private struct ContextPanel: View {
    var context: ConversationContext
    var interpretation: InterpretationResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(contextTitle, systemImage: "quote.bubble")
                .font(.headline)
            if let brief = context.brief ?? interpretation?.discussionBrief ?? interpretation?.summary {
                Text(brief)
            }
            if let reason = context.whyItMatters {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var contextTitle: String {
        (context.type ?? "Conversation context")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

private struct InsightScoreCard: View {
    var name: String
    var item: InsightScore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName)
                    .font(.headline)
                Spacer()
                Text(scoreText)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(scoreColor)
            }

            ProgressView(value: item.score ?? 0, total: 100)
                .tint(scoreColor)

            if let confidence = item.confidence {
                Text("Confidence: \(Int((confidence * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(item.drivers ?? [], id: \.self) { driver in
                Label(driver, systemImage: "circle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.hierarchical)
            }

            if let practice = item.practice, !practice.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Try next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(practice)
                        .font(.callout)
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var scoreText: String {
        item.score.map { "\(Int($0.rounded()))" } ?? "-"
    }

    private var scoreColor: Color {
        guard let score = item.score else { return .secondary }
        if score >= 70 { return .green }
        if score >= 50 { return .blue }
        return .orange
    }
}

private struct InterpretationPanel: View {
    var interpretation: InterpretationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation interpretation")
                .font(.headline)
            if let summary = interpretation.summary {
                Text(summary)
            }
            ForEach(interpretation.actionPlan ?? [], id: \.self) { action in
                Label(action, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            if let provider = interpretation.provider {
                Text("Interpreter: \(provider)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
