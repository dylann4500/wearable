import Foundation

struct WearablePeripheral: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct WearableAudioRecording: Identifiable, Hashable {
    var id: String { filename }
    var filename: String
    var byteSize: Int
    var syncState: String
    var localFileURL: URL?

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

enum WearableConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case disconnected
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .connecting(let name): "Connecting to \(name)"
        case .connected(let name): "Connected to \(name)"
        case .disconnected: "Disconnected"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
