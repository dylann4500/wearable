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

struct CompletedWearableDownload: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let byteSize: Int
    let crc32: UInt32
    let localFileURL: URL
    let deviceID: String

    init(
        id: UUID = UUID(),
        filename: String,
        byteSize: Int,
        crc32: UInt32,
        localFileURL: URL,
        deviceID: String
    ) {
        self.id = id
        self.filename = filename
        self.byteSize = byteSize
        self.crc32 = crc32
        self.localFileURL = localFileURL
        self.deviceID = deviceID
    }
}

enum WearableTransferState: Equatable {
    case onWearable
    case queued
    case downloading(Double)
    case downloaded
    case failed

    var label: String {
        switch self {
        case .onWearable: "On wearable"
        case .queued: "Queued"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .downloaded: "On this iPhone"
        case .failed: "Transfer failed"
        }
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

struct BLEDataPacket: Equatable {
    var offset: Int
    var payload: Data

    init?(data: Data) {
        guard data.count >= 6 else { return nil }
        let offset = Int(
            UInt32(data[0])
                | UInt32(data[1]) << 8
                | UInt32(data[2]) << 16
                | UInt32(data[3]) << 24
        )
        let payloadLength = Int(UInt16(data[4]) | UInt16(data[5]) << 8)
        guard payloadLength > 0, data.count == 6 + payloadLength else { return nil }

        self.offset = offset
        payload = data.subdata(in: 6..<data.count)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var entry = UInt32(value)
        for _ in 0..<8 {
            entry = (entry >> 1) ^ (0xEDB88320 & (0 &- (entry & 1)))
        }
        return entry
    }

    static func checksum(data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ UInt32.max
    }

    static func checksum(fileAt url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var crc = UInt32.max
        do {
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                for byte in data {
                    let index = Int((crc ^ UInt32(byte)) & 0xFF)
                    crc = (crc >> 8) ^ table[index]
                }
            }
            return crc ^ UInt32.max
        } catch {
            return nil
        }
    }
}
