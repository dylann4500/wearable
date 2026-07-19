import Foundation
import Observation

@Observable
final class BackendClient {
    var baseURL: URL

    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func listRecordings() async throws -> [Recording] {
        let request = URLRequest(url: baseURL.appending(path: "/api/recordings"))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode([Recording].self, from: data)
    }

    func getRecording(id: Recording.ID) async throws -> Recording {
        let request = URLRequest(url: baseURL.appending(path: "/api/recordings/\(id)"))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(Recording.self, from: data)
    }

    func uploadRecording(fileURL: URL) async throws -> Recording {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "/api/recordings"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var formData = MultipartFormData(boundary: boundary)
        try formData.appendFile(fieldName: "file", fileURL: fileURL)
        request.httpBody = formData.finalize()

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(Recording.self, from: data)
    }

    func uploadWearableRecording(
        fileURL: URL,
        filename: String,
        deviceID: String,
        deviceToken: String,
        uploadID: String
    ) async throws -> Recording {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/device/recordings/raw"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components?.url else {
            throw BackendClientError.requestFailed("Could not construct the wearable upload URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.setValue(Data(uploadID.utf8).base64EncodedString(), forHTTPHeaderField: "X-Upload-Id")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize(at: fileURL)), forHTTPHeaderField: "Content-Length")

        // A file-backed upload avoids loading a potentially large wearable WAV
        // into memory and is compatible with a background URLSession later.
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try validate(response: response, data: data)
        return try decoder.decode(Recording.self, from: data)
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? decoder.decode(APIError.self, from: data) {
                throw BackendClientError.requestFailed(apiError.detail)
            }
            throw BackendClientError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }
    }
}

enum BackendClientError: LocalizedError {
    case requestFailed(String)
    case analysisTimedOut

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            message
        case .analysisTimedOut:
            "The backend did not finish analysis before the polling timeout."
        }
    }
}

enum RelayPipelineStage: String, Codable, Equatable {
    case waitingForBackend
    case queued
    case uploading
    case processing
    case complete
    case failed

    var label: String {
        switch self {
        case .waitingForBackend: "Waiting for backend"
        case .queued: "Queued for analysis"
        case .uploading: "Uploading for analysis"
        case .processing: "Analyzing conversation"
        case .complete: "Insights ready"
        case .failed: "Analysis failed"
        }
    }
}

struct RelayPipelineJob: Identifiable, Codable, Equatable {
    let id: String
    let filename: String
    let byteSize: Int
    let crc32: UInt32
    let localPath: String
    let deviceID: String
    var backendRecordingID: String?
    var stage: RelayPipelineStage
    var errorMessage: String?

    var localFileURL: URL { URL(fileURLWithPath: localPath) }
}

@MainActor
@Observable
final class RecordingPipelineCoordinator {
    private let defaults: UserDefaults
    private let storageKey = "WearableRelayPipelineJobs.v1"
    private var workerTask: Task<Void, Never>?

    var jobs: [RelayPipelineJob]
    var latestCompletedRecording: Recording?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RelayPipelineJob].self, from: data) {
            jobs = decoded.map { job in
                var resumed = job
                if ![.complete, .failed].contains(resumed.stage) {
                    resumed.stage = .waitingForBackend
                }
                return resumed
            }
        } else {
            jobs = []
        }
    }

    func enqueue(
        _ download: CompletedWearableDownload,
        backendEnabled: Bool,
        backend: BackendClient,
        deviceToken: String
    ) {
        enqueueLocalFile(
            url: download.localFileURL,
            filename: download.filename,
            byteSize: download.byteSize,
            crc32: download.crc32,
            deviceID: download.deviceID,
            backendEnabled: backendEnabled,
            backend: backend,
            deviceToken: deviceToken
        )
    }

    func resumeLocalRecordings(
        _ recordings: [WearableAudioRecording],
        backendEnabled: Bool,
        backend: BackendClient,
        deviceToken: String
    ) {
        for recording in recordings {
            guard let url = recording.localFileURL,
                  let checksum = CRC32.checksum(fileAt: url)
            else { continue }
            enqueueLocalFile(
                url: url,
                filename: recording.filename,
                byteSize: recording.byteSize,
                crc32: checksum,
                deviceID: "xiao-ios-relay",
                backendEnabled: backendEnabled,
                backend: backend,
                deviceToken: deviceToken
            )
        }

        if backendEnabled {
            for index in jobs.indices where jobs[index].stage == .waitingForBackend || jobs[index].stage == .failed {
                jobs[index].stage = .queued
                jobs[index].errorMessage = nil
            }
            persist()
            startWorker(backend: backend, deviceToken: deviceToken)
        }
    }

    func stage(for localFileURL: URL) -> RelayPipelineStage? {
        jobs.first(where: { $0.localPath == localFileURL.path })?.stage
    }

    func error(for localFileURL: URL) -> String? {
        jobs.first(where: { $0.localPath == localFileURL.path })?.errorMessage
    }

    private func enqueueLocalFile(
        url: URL,
        filename: String,
        byteSize: Int,
        crc32: UInt32,
        deviceID: String,
        backendEnabled: Bool,
        backend: BackendClient,
        deviceToken: String
    ) {
        let id = "\(filename)|\(byteSize)|\(String(crc32, radix: 16))"
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            guard jobs[index].stage != .complete else { return }
            guard jobs[index].stage != .uploading, jobs[index].stage != .processing else { return }
            jobs[index].stage = backendEnabled ? .queued : .waitingForBackend
            jobs[index].errorMessage = nil
        } else {
            jobs.append(
                RelayPipelineJob(
                    id: id,
                    filename: filename,
                    byteSize: byteSize,
                    crc32: crc32,
                    localPath: url.path,
                    deviceID: deviceID,
                    backendRecordingID: nil,
                    stage: backendEnabled ? .queued : .waitingForBackend,
                    errorMessage: nil
                )
            )
        }
        persist()
        if backendEnabled {
            startWorker(backend: backend, deviceToken: deviceToken)
        }
    }

    private func startWorker(backend: BackendClient, deviceToken: String) {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainQueue(backend: backend, deviceToken: deviceToken)
        }
    }

    private func drainQueue(backend: BackendClient, deviceToken: String) async {
        while !Task.isCancelled,
              let jobID = jobs.first(where: { $0.stage == .queued })?.id {
            await process(jobID: jobID, backend: backend, deviceToken: deviceToken)
        }
        workerTask = nil
    }

    private func process(jobID: String, backend: BackendClient, deviceToken: String) async {
        guard let initialIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        do {
            var backendRecordingID = jobs[initialIndex].backendRecordingID
            if backendRecordingID == nil {
                jobs[initialIndex].stage = .uploading
                jobs[initialIndex].errorMessage = nil
                persist()

                let uploaded = try await backend.uploadWearableRecording(
                    fileURL: jobs[initialIndex].localFileURL,
                    filename: jobs[initialIndex].filename,
                    deviceID: jobs[initialIndex].deviceID,
                    deviceToken: deviceToken,
                    uploadID: jobs[initialIndex].id
                )
                backendRecordingID = uploaded.id
                update(jobID: jobID) { job in
                    job.backendRecordingID = uploaded.id
                    job.stage = uploaded.status == .complete ? .complete : .processing
                }
                if uploaded.status == .complete {
                    latestCompletedRecording = uploaded
                    return
                }
            } else {
                update(jobID: jobID) { $0.stage = .processing }
            }

            guard let backendRecordingID else { return }
            let completed = try await pollUntilComplete(id: backendRecordingID, backend: backend)
            latestCompletedRecording = completed
            update(jobID: jobID) { job in
                job.stage = .complete
                job.errorMessage = nil
            }
        } catch is CancellationError {
            update(jobID: jobID) { $0.stage = .waitingForBackend }
        } catch {
            update(jobID: jobID) { job in
                job.stage = .failed
                job.errorMessage = error.localizedDescription
            }
        }
    }

    private func pollUntilComplete(id: Recording.ID, backend: BackendClient) async throws -> Recording {
        for _ in 0..<900 {
            let recording = try await backend.getRecording(id: id)
            switch recording.status {
            case .complete:
                return recording
            case .failed:
                throw BackendClientError.requestFailed(recording.error ?? "Backend analysis failed.")
            case .uploaded, .processing:
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw BackendClientError.analysisTimedOut
    }

    private func update(jobID: String, mutation: (inout RelayPipelineJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutation(&jobs[index])
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private struct APIError: Codable {
    let detail: String
}

private struct MultipartFormData {
    var boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func appendFile(fieldName: String, fileURL: URL) throws {
        let filename = fileURL.lastPathComponent
        let mimeType = mimeTypeForFileExtension(fileURL.pathExtension)

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n")
    }

    mutating func finalize() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }

    private func mimeTypeForFileExtension(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "aac": "audio/aac"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        default: "application/octet-stream"
        }
    }
}
