import SwiftUI

struct InsightsView: View {
    private let result = MockData.recordings.first?.result

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Conversation coaching should start as evidence, not diagnosis.")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let result {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        MetricTile(title: "Talk share", value: talkShare(result), systemImage: "chart.pie", tint: .blue)
                        MetricTile(title: "Response latency", value: seconds(result.turnTaking?.medianResponseLatencySeconds), systemImage: "timer", tint: .orange)
                        MetricTile(title: "Follow-ups", value: int(result.language?.followUpQuestionCount), systemImage: "arrowshape.turn.up.left.2", tint: .green)
                        MetricTile(title: "Long pauses", value: int(result.silenceAndPauses?.longPauseCount), systemImage: "pause.rectangle", tint: .purple)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("MVP insight rules")
                        .font(.headline)
                    InsightRule(title: "Turn balance", detail: "Show speaker talk-time share and turn counts before making any recommendation.")
                    InsightRule(title: "Responsiveness", detail: "Use median response latency and short acknowledgments to flag possible interruptions or backchannels.")
                    InsightRule(title: "Language habits", detail: "Track fillers, questions, follow-ups, and speaking rate as trend lines across recordings.")
                    InsightRule(title: "Audio confidence", detail: "Always show quality warnings when clipping, low SNR, or long silence might distort the metrics.")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Backend dependency")
                        .font(.headline)
                    Text("The iOS app should not try to run the current Python pipeline directly. The MVP app is a client for capture, pairing, upload, status, and review. Server jobs continue to handle ffmpeg conversion, Whisper, diarization, embeddings, and metric extraction.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
        .navigationTitle("Insights")
    }

    private func talkShare(_ result: AnalysisResult) -> String {
        guard let share = result.speakers?.talkTimeShare?["Speaker 1"] else { return "-" }
        return "\(Int((share * 100).rounded()))%"
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(value.shortMetric)s"
    }

    private func int(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }
}

private struct InsightRule: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
