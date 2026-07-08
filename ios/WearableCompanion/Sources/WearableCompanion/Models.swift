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
    var metadata: Metadata?
    var summary: Summary?
    var speakers: Speakers?
    var turnTaking: TurnTaking?
    var language: LanguageMetrics?
    var silenceAndPauses: SilenceMetrics?
    var audioQuality: AudioQuality?
    var sentiment: Sentiment?
    var interjections: Interjections?
    var transcript: [TranscriptTurn]?

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
        case transcript
    }
}

struct Metadata: Codable, Hashable {
    var fileName: String?
    var durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case durationSeconds = "duration_seconds"
    }
}

struct Summary: Codable, Hashable {
    var speakerCount: Int?
    var totalWords: Int?
    var totalTurns: Int?
    var conversationWPM: Double?
    var silencePercent: Double?

    enum CodingKeys: String, CodingKey {
        case speakerCount = "speaker_count"
        case totalWords = "total_words"
        case totalTurns = "total_turns"
        case conversationWPM = "conversation_wpm"
        case silencePercent = "silence_percent"
    }
}

struct Speakers: Codable, Hashable {
    var talkTimeShare: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case talkTimeShare = "talk_time_share"
    }
}

struct TurnTaking: Codable, Hashable {
    var averageTurnSeconds: Double?
    var medianResponseLatencySeconds: Double?
    var monologueCount: Int?

    enum CodingKeys: String, CodingKey {
        case averageTurnSeconds = "average_turn_seconds"
        case medianResponseLatencySeconds = "median_response_latency_seconds"
        case monologueCount = "monologue_count"
    }
}

struct LanguageMetrics: Codable, Hashable {
    var fillersPerMinute: Double?
    var questionCount: Int?
    var followUpQuestionCount: Int?

    enum CodingKeys: String, CodingKey {
        case fillersPerMinute = "fillers_per_minute"
        case questionCount = "question_count"
        case followUpQuestionCount = "follow_up_question_count"
    }
}

struct SilenceMetrics: Codable, Hashable {
    var longPauseCount: Int?
    var totalPauseSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case longPauseCount = "long_pause_count"
        case totalPauseSeconds = "total_pause_seconds"
    }
}

struct AudioQuality: Codable, Hashable {
    var clippingPercent: Double?
    var estimatedSNR: Double?

    enum CodingKeys: String, CodingKey {
        case clippingPercent = "clipping_percent"
        case estimatedSNR = "estimated_snr"
    }
}

struct Sentiment: Codable, Hashable {
    var overall: String?
    var trajectory: String?
}

struct Interjections: Codable, Hashable {
    var estimatedCount: Int?

    enum CodingKeys: String, CodingKey {
        case estimatedCount = "estimated_count"
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
