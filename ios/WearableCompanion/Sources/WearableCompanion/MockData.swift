import Foundation

enum MockData {
    static let recordings: [Recording] = [
        Recording(
            id: "mock-complete",
            deviceID: "xiao-esp32s3-prototype-001",
            originalFilename: "audio0007.wav",
            status: .complete,
            source: .device,
            error: nil,
            createdAt: .now.addingTimeInterval(-3600),
            updatedAt: .now.addingTimeInterval(-3320),
            completedAt: .now.addingTimeInterval(-3320),
            result: AnalysisResult(
                metadata: Metadata(fileName: "audio0007.wav", durationSeconds: 423),
                summary: Summary(speakerCount: 2, totalWords: 1168, totalTurns: 94, conversationWPM: 166, silencePercent: 12.8),
                speakers: Speakers(talkTimeShare: ["Speaker 1": 0.57, "Speaker 2": 0.43]),
                turnTaking: TurnTaking(averageTurnSeconds: 4.5, medianResponseLatencySeconds: 0.72, monologueCount: 2),
                language: LanguageMetrics(fillersPerMinute: 3.1, questionCount: 18, followUpQuestionCount: 7),
                silenceAndPauses: SilenceMetrics(longPauseCount: 4, totalPauseSeconds: 54),
                audioQuality: AudioQuality(clippingPercent: 0.2, estimatedSNR: 24),
                sentiment: Sentiment(overall: "Neutral-positive", trajectory: "Warmer near the end"),
                interjections: Interjections(estimatedCount: 6),
                transcript: [
                    TranscriptTurn(speaker: "Speaker 1", text: "I want to understand where the project feels blocked right now.", startSeconds: 4.2, endSeconds: 8.8),
                    TranscriptTurn(speaker: "Speaker 2", text: "Mostly the device setup path and whether upload can happen away from home.", startSeconds: 9.5, endSeconds: 14.2)
                ]
            )
        ),
        Recording(
            id: "mock-processing",
            deviceID: "xiao-esp32s3-prototype-001",
            originalFilename: "audio0008.wav",
            status: .processing,
            source: .device,
            error: nil,
            createdAt: .now.addingTimeInterval(-180),
            updatedAt: .now.addingTimeInterval(-40),
            completedAt: nil,
            result: nil
        )
    ]
}
