import Foundation

struct Recording: Identifiable, Codable, Hashable {
    let id: String
    let deviceID: String?
    let originalFilename: String
    let status: RecordingStatus
    let source: RecordingSource
    let error: String?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let result: AnalysisResult?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case originalFilename = "original_filename"
        case status
        case source
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case result
    }
}

enum RecordingStatus: String, Codable, CaseIterable {
    case uploaded
    case processing
    case complete
    case failed

    var displayName: String {
        switch self {
        case .uploaded: "Uploaded"
        case .processing: "Processing"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }
}

enum RecordingSource: String, Codable {
    case browser
    case device

    var displayName: String {
        switch self {
        case .browser: "Manual upload"
        case .device: "Wearable"
        }
    }
}

struct AnalysisResult: Codable, Hashable {
    var metadata: Metadata? = nil
    var summary: Summary? = nil
    var speakers: [String: SpeakerMetrics]? = nil
    var turnTaking: TurnTaking? = nil
    var language: LanguageMetrics? = nil
    var silenceAndPauses: SilenceMetrics? = nil
    var audioQuality: AudioQuality? = nil
    var sentiment: Sentiment? = nil
    var interjections: Interjections? = nil
    var insights: InsightResult? = nil
    var interpretation: InterpretationResult? = nil
    var transcript: [TranscriptTurn]? = nil

    enum CodingKeys: String, CodingKey {
        case metadata
        case summary
        case speakers
        case turnTaking = "turn_taking"
        case language
        case silenceAndPauses = "silence_and_pauses"
        case audioQuality = "audio_quality"
        case sentiment
        case interjections
        case insights
        case interpretation
        case transcript
    }
}

struct Metadata: Codable, Hashable {
    var fileName: String? = nil
    var durationSeconds: Double? = nil
    var turnsAnalyzed: Int? = nil
    var diarization: DiarizationStatus? = nil
    var model: String? = nil
    var runID: String? = nil

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case durationSeconds = "duration_seconds"
        case turnsAnalyzed = "turns_analyzed"
        case diarization
        case model
        case runID = "run_id"
    }
}

struct DiarizationStatus: Codable, Hashable {
    var enabled: Bool?
    var status: String?
    var speakerCount: Int?
    var displayedSpeakerCount: Int?
    var displayedSpeakers: [String]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case status
        case speakerCount = "speaker_count"
        case displayedSpeakerCount = "displayed_speaker_count"
        case displayedSpeakers = "displayed_speakers"
    }
}

struct Summary: Codable, Hashable {
    var speakerCount: Int?
    var totalWords: Int?
    var totalTurns: Int?
    var conversationWPM: Double?
    var silencePercent: Double?
    var userSpeakerAssumption: String? = nil

    enum CodingKeys: String, CodingKey {
        case speakerCount = "speaker_count"
        case totalWords = "total_words"
        case totalTurns = "total_turns"
        case conversationWPM = "conversation_wpm"
        case silencePercent = "silence_percent"
        case userSpeakerAssumption = "user_speaker_assumption"
    }
}

struct SpeakerMetrics: Codable, Hashable {
    var turns: Int? = nil
    var talkTimeSeconds: Double? = nil
    var talkTimePercent: Double? = nil
    var wordCount: Int? = nil
    var wordsPerMinute: Double? = nil
    var averageTurnSeconds: Double? = nil
    var averageVolumeDB: Double? = nil
    var averagePitchHz: Double? = nil
    var sentimentAverage: Double? = nil

    enum CodingKeys: String, CodingKey {
        case turns
        case talkTimeSeconds = "talk_time_seconds"
        case talkTimePercent = "talk_time_percent"
        case wordCount = "word_count"
        case wordsPerMinute = "words_per_minute"
        case averageTurnSeconds = "average_turn_seconds"
        case averageVolumeDB = "average_volume_db"
        case averagePitchHz = "average_pitch_hz"
        case sentimentAverage = "sentiment_average"
    }
}

struct TurnTaking: Codable, Hashable {
    var turnCount: Int? = nil
    var averageTurnSeconds: Double? = nil
    var medianTurnSeconds: Double? = nil
    var longestTurnSeconds: Double? = nil
    var shortestTurnSeconds: Double? = nil
    var veryShortResponses: Int? = nil
    var monologuesOver45Seconds: Int? = nil
    var speakerChanges: Int? = nil
    var averageResponseLatencySeconds: Double? = nil
    var fastResponsesUnder300ms: Int? = nil
    var slowResponsesOver2Seconds: Int? = nil

    enum CodingKeys: String, CodingKey {
        case turnCount = "turn_count"
        case averageTurnSeconds = "average_turn_seconds"
        case medianTurnSeconds = "median_turn_seconds"
        case longestTurnSeconds = "longest_turn_seconds"
        case shortestTurnSeconds = "shortest_turn_seconds"
        case veryShortResponses = "very_short_responses"
        case monologuesOver45Seconds = "monologues_over_45s"
        case speakerChanges = "speaker_changes"
        case averageResponseLatencySeconds = "average_response_latency_seconds"
        case fastResponsesUnder300ms = "fast_responses_under_300ms"
        case slowResponsesOver2Seconds = "slow_responses_over_2s"
    }
}

struct LanguageMetrics: Codable, Hashable {
    var fillersPerMinute: Double? = nil
    var questionCount: Int? = nil
    var questionsPerMinute: Double? = nil
    var followUpQuestionEstimate: Int? = nil
    var backchannelCount: Int? = nil
    var backchannelsPerMinute: Double? = nil
    var validationPhraseCount: Int? = nil
    var advicePhraseCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case fillersPerMinute = "fillers_per_minute"
        case questionCount = "question_count"
        case questionsPerMinute = "questions_per_minute"
        case followUpQuestionEstimate = "follow_up_question_estimate"
        case backchannelCount = "backchannel_count"
        case backchannelsPerMinute = "backchannels_per_minute"
        case validationPhraseCount = "validation_phrase_count"
        case advicePhraseCount = "advice_phrase_count"
    }
}

struct SilenceMetrics: Codable, Hashable {
    var totalSilenceSeconds: Double? = nil
    var averageBetweenTurnPauseSeconds: Double? = nil
    var longPausesOver2Seconds: Int? = nil

    enum CodingKeys: String, CodingKey {
        case totalSilenceSeconds = "total_silence_seconds"
        case averageBetweenTurnPauseSeconds = "average_between_turn_pause_seconds"
        case longPausesOver2Seconds = "long_pauses_over_2s"
    }
}

struct AudioQuality: Codable, Hashable {
    var averageVolumeDB: Double? = nil
    var dynamicRangeDB: Double? = nil
    var pitchRangeHz: Double? = nil
    var pitchVariabilityHz: Double? = nil
    var confidence: String? = nil

    enum CodingKeys: String, CodingKey {
        case averageVolumeDB = "average_volume_db"
        case dynamicRangeDB = "dynamic_range_db"
        case pitchRangeHz = "pitch_range_hz"
        case pitchVariabilityHz = "pitch_variability_hz"
        case confidence = "audio_quality_confidence"
    }
}

struct Sentiment: Codable, Hashable {
    var average: Double? = nil
    var minimum: Double? = nil
    var maximum: Double? = nil
    var endingAverage: Double? = nil
    var largestShift: Double? = nil

    enum CodingKeys: String, CodingKey {
        case average
        case minimum
        case maximum
        case endingAverage = "ending_average_last_3_turns"
        case largestShift = "largest_shift"
    }
}

struct Interjections: Codable, Hashable {
    var estimatedCount: Int?

    enum CodingKeys: String, CodingKey {
        case estimatedCount = "estimated_count"
    }
}

struct InsightResult: Codable, Hashable {
    var version: String? = nil
    var speakerFocus: String? = nil
    var confidence: Double? = nil
    var scores: [String: InsightScore]? = nil
    var contextualizedScores: [String: InsightScore]? = nil
    var middleLayer: [String: MiddleLayerScore]? = nil
    var context: ConversationContext? = nil
    var primaryFocus: [InsightPriority]? = nil
    var notes: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case version
        case speakerFocus = "speaker_focus"
        case confidence
        case scores
        case contextualizedScores = "contextualized_scores"
        case middleLayer = "middle_layer"
        case context
        case primaryFocus = "primary_focus"
        case notes
    }

    var displayScores: [String: InsightScore] {
        contextualizedScores ?? scores ?? [:]
    }
}

struct InsightScore: Codable, Hashable {
    var score: Double? = nil
    var confidence: Double? = nil
    var drivers: [String]? = nil
    var practice: String? = nil
    var contextWeight: Double? = nil
    var priority: Double? = nil
    var importance: String? = nil

    enum CodingKeys: String, CodingKey {
        case score
        case confidence
        case drivers
        case practice
        case contextWeight = "context_weight"
        case priority
        case importance
    }
}

struct MiddleLayerScore: Codable, Hashable {
    var score: Double? = nil
    var confidence: Double? = nil
}

struct ConversationContext: Codable, Hashable {
    var type: String? = nil
    var confidence: Double? = nil
    var brief: String? = nil
    var signals: [String]? = nil
    var whyItMatters: String? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case confidence
        case brief
        case signals
        case whyItMatters = "why_it_matters"
    }
}

struct InsightPriority: Codable, Hashable {
    var variable: String? = nil
    var score: Double? = nil
    var priority: Double? = nil
    var importance: String? = nil
    var practice: String? = nil
}

struct InterpretationResult: Codable, Hashable {
    var version: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var context: ConversationContext? = nil
    var discussionBrief: String? = nil
    var summary: String? = nil
    var actionPlan: [String]? = nil
    var limitations: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case version
        case provider
        case model
        case context
        case discussionBrief = "discussion_brief"
        case summary
        case actionPlan = "action_plan"
        case limitations
    }
}

struct TranscriptTurn: Identifiable, Codable, Hashable {
    var id: String { "\(speaker)-\(startSeconds)-\(endSeconds)" }
    var speaker: String
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case startSeconds = "start"
        case endSeconds = "end"
    }
}

enum PairingMode: String, CaseIterable, Identifiable {
    case bluetoothProvisioning = "BLE provisioning"
    case softAPProvisioning = "Device setup network"
    case phoneRelay = "Phone relay"
    case knownNetworks = "Known networks"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .bluetoothProvisioning:
            "The app finds the XIAO over Bluetooth LE, sends backend and Wi-Fi settings, then the device uploads directly when online."
        case .softAPProvisioning:
            "The XIAO temporarily creates a setup Wi-Fi network; the app joins it and posts configuration to the device."
        case .phoneRelay:
            "The wearable transfers audio to the phone over BLE or local Wi-Fi, and the phone uploads through cellular or Wi-Fi."
        case .knownNetworks:
            "The device stores approved SSIDs and only connects where credentials were already provisioned."
        }
    }
}
