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

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            message
        }
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
