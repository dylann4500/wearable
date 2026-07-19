import XCTest
@testable import WearableCompanion

final class WearableCompanionTests: XCTestCase {
    func testMockRecordingHasCompletedResult() throws {
        let recording = try XCTUnwrap(MockData.recordings.first)

        XCTAssertEqual(recording.status, .complete)
        XCTAssertNotNil(recording.result?.summary)
    }

    func testBLEDataPacketParsesOffsetAndPayload() throws {
        let data = Data([
            0xA0, 0x00, 0x00, 0x00,
            0x03, 0x00,
            0x52, 0x49, 0x46,
        ])

        let packet = try XCTUnwrap(BLEDataPacket(data: data))

        XCTAssertEqual(packet.offset, 160)
        XCTAssertEqual(packet.payload, Data([0x52, 0x49, 0x46]))
    }

    func testBLEDataPacketRejectsInvalidLength() {
        let data = Data([
            0x00, 0x00, 0x00, 0x00,
            0x04, 0x00,
            0x01, 0x02,
        ])

        XCTAssertNil(BLEDataPacket(data: data))
    }

    func testCRC32MatchesStandardVector() {
        XCTAssertEqual(
            CRC32.checksum(data: Data("123456789".utf8)),
            0xCBF4_3926
        )
    }

    func testBackendAnalysisContractDecodesInsightsAndSpeakerMetrics() throws {
        let json = #"""
        {
          "id": "recording-1",
          "device_id": "xiao-test",
          "original_filename": "audio0001.wav",
          "status": "complete",
          "source": "device",
          "error": null,
          "created_at": "2026-07-15T18:00:00Z",
          "updated_at": "2026-07-15T18:01:00Z",
          "completed_at": "2026-07-15T18:01:00Z",
          "result": {
            "summary": {
              "speaker_count": 2,
              "total_words": 320,
              "total_turns": 24,
              "conversation_wpm": 148.2,
              "silence_percent": 11.4,
              "user_speaker_assumption": "Speaker 1"
            },
            "speakers": {
              "Speaker 1": {"talk_time_percent": 57.0, "word_count": 180},
              "Speaker 2": {"talk_time_percent": 43.0, "word_count": 140}
            },
            "turn_taking": {"average_response_latency_seconds": 0.72},
            "language": {"follow_up_question_estimate": 7},
            "silence_and_pauses": {"long_pauses_over_2s": 4},
            "insights": {
              "version": "conversation-intelligence-v1",
              "speaker_focus": "Speaker 1",
              "confidence": 0.82,
              "scores": {
                "warmth": {
                  "score": 74.0,
                  "confidence": 0.8,
                  "drivers": ["Frequent acknowledgments"],
                  "practice": "Reflect before advising."
                }
              }
            },
            "interpretation": {
              "provider": "mock",
              "context": {"type": "work_meeting", "brief": "Project planning."},
              "summary": "A balanced planning conversation."
            },
            "transcript": []
          }
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let recording = try decoder.decode(Recording.self, from: Data(json.utf8))

        XCTAssertEqual(recording.result?.speakers?["Speaker 1"]?.talkTimePercent, 57)
        XCTAssertEqual(recording.result?.language?.followUpQuestionEstimate, 7)
        XCTAssertEqual(recording.result?.insights?.scores?["warmth"]?.score, 74)
        XCTAssertEqual(recording.result?.interpretation?.context?.type, "work_meeting")
    }

    @MainActor
    func testRelayPipelineDeduplicatesVerifiedDownloadWhileBackendIsDisabled() throws {
        let suiteName = "WearableCompanionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = RecordingPipelineCoordinator(defaults: defaults)
        let backend = BackendClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        let download = CompletedWearableDownload(
            filename: "audio0001.wav",
            byteSize: 1024,
            crc32: 0xCBF4_3926,
            localFileURL: URL(fileURLWithPath: "/tmp/audio0001.wav"),
            deviceID: "xiao-test"
        )

        coordinator.enqueue(download, backendEnabled: false, backend: backend, deviceToken: "test")
        coordinator.enqueue(download, backendEnabled: false, backend: backend, deviceToken: "test")

        XCTAssertEqual(coordinator.jobs.count, 1)
        XCTAssertEqual(coordinator.jobs.first?.stage, .waitingForBackend)
    }

    @MainActor
    func testRelayPipelineUploadsVerifiedFileAndPublishesInsights() async throws {
        let suiteName = "WearableCompanionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-\(UUID().uuidString).wav")
        try Data("RIFF-test-WAVE".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PipelineURLProtocol.self]
        let backend = BackendClient(
            baseURL: URL(string: "https://pipeline.example")!,
            session: URLSession(configuration: configuration)
        )
        PipelineURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let body = #"""
            {
              "id": "backend-recording-1",
              "device_id": "xiao-test",
              "original_filename": "audio0002.wav",
              "status": "complete",
              "source": "device",
              "error": null,
              "created_at": "2026-07-15T18:00:00Z",
              "updated_at": "2026-07-15T18:01:00Z",
              "completed_at": "2026-07-15T18:01:00Z",
              "result": {
                "insights": {
                  "speaker_focus": "Speaker 1",
                  "confidence": 0.8,
                  "scores": {"warmth": {"score": 71, "confidence": 0.8}}
                },
                "transcript": []
              }
            }
            """#
            return (response, Data(body.utf8))
        }

        let coordinator = RecordingPipelineCoordinator(defaults: defaults)
        coordinator.enqueue(
            CompletedWearableDownload(
                filename: "audio0002.wav",
                byteSize: 14,
                crc32: 1234,
                localFileURL: fileURL,
                deviceID: "xiao-test"
            ),
            backendEnabled: true,
            backend: backend,
            deviceToken: "test-token"
        )

        for _ in 0..<100 where coordinator.jobs.first?.stage != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.jobs.first?.stage, .complete)
        XCTAssertEqual(coordinator.latestCompletedRecording?.result?.insights?.scores?["warmth"]?.score, 71)
        XCTAssertEqual(PipelineURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Device-Token"), "test-token")
        XCTAssertNotNil(PipelineURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Upload-Id"))
    }
}

private final class PipelineURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
