import Foundation
import Observation

#if canImport(CoreBluetooth)
import CoreBluetooth

@MainActor
@Observable
final class WearableBLEManager: NSObject {
    private let serviceUUID = CBUUID(string: "8f2a0001-7b4f-4f9d-9d3f-2f5c0a7a9000")
    private let controlUUID = CBUUID(string: "8f2a0002-7b4f-4f9d-9d3f-2f5c0a7a9000")
    private let statusUUID = CBUUID(string: "8f2a0003-7b4f-4f9d-9d3f-2f5c0a7a9000")
    private let manifestUUID = CBUUID(string: "8f2a0004-7b4f-4f9d-9d3f-2f5c0a7a9000")
    private let dataUUID = CBUUID(string: "8f2a0005-7b4f-4f9d-9d3f-2f5c0a7a9000")

    private var central: CBCentralManager!
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var manifestCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var activeDownload: ActiveDownload?
    private var autoConnectTask: Task<Void, Never>?
    private var downloadQueue: [String] = []

    var state: WearableConnectionState = .idle
    var discoveredDevices: [WearablePeripheral] = []
    var recordings: [WearableAudioRecording] = []
    var statusLog: [String] = []
    var activeRecordingName: String?
    var downloadProgress: [String: Double] = [:]
    var autoSyncNearestEnabled = false
    var isAutoSyncing = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            state = .failed("Bluetooth is \(central.state.displayName).")
            return
        }

        discoveredDevices = []
        discoveredPeripherals = [:]
        state = .scanning
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if case .scanning = state {
            state = .idle
        }
    }

    func startAutoSyncNearest() {
        autoSyncNearestEnabled = true
        isAutoSyncing = true
        appendStatus("AUTO_SYNC:Scanning for nearest wearable")
        startScan()
        scheduleNearestAutoConnect()
    }

    func stopAutoSyncNearest() {
        autoSyncNearestEnabled = false
        isAutoSyncing = false
        autoConnectTask?.cancel()
        autoConnectTask = nil
        downloadQueue = []
        stopScan()
        if activeDownload != nil {
            writeCommand("TRANSFER_STOP")
        }
        appendStatus("AUTO_SYNC:Stopped")
    }

    func connect(to device: WearablePeripheral) {
        guard let peripheral = discoveredPeripherals[device.id] else { return }
        state = .connecting(device.name)
        central.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func refreshRecordings() {
        writeCommand("LIST")
    }

    func startWearableRecording() {
        writeCommand("RECORD_START")
    }

    func stopWearableRecording() {
        writeCommand("RECORD_STOP")
    }

    func download(_ recording: WearableAudioRecording) {
        enqueueDownloads([recording.filename], replaceQueue: true, skipLocalFiles: false)
    }

    func localURL(for recording: WearableAudioRecording) -> URL? {
        recordings.first(where: { $0.filename == recording.filename })?.localFileURL
    }

    private func writeCommand(_ command: String) {
        guard let peripheral = connectedPeripheral, let controlCharacteristic else {
            appendStatus("ERROR:Not connected")
            return
        }

        guard let data = command.data(using: .utf8) else { return }
        let writeType: CBCharacteristicWriteType = controlCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: controlCharacteristic, type: writeType)
    }

    private func scheduleNearestAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard let self, self.autoSyncNearestEnabled else { return }
                guard let nearest = self.discoveredDevices.max(by: { $0.rssi < $1.rssi }) else {
                    self.appendStatus("AUTO_SYNC:No wearable found")
                    self.isAutoSyncing = false
                    return
                }
                self.appendStatus("AUTO_SYNC:Connecting to \(nearest.name)")
                self.connect(to: nearest)
            }
        }
    }

    private func appendStatus(_ status: String) {
        statusLog.insert(status, at: 0)
        statusLog = Array(statusLog.prefix(20))
    }

    private func handleStatus(_ status: String) {
        appendStatus(status)

        if status.hasPrefix("LIST_READY") {
            if let manifestCharacteristic {
                connectedPeripheral?.readValue(for: manifestCharacteristic)
            }
            return
        }

        if status.hasPrefix("RECORDING_STARTED:") {
            activeRecordingName = String(status.dropFirst("RECORDING_STARTED:".count))
            return
        }

        if status.hasPrefix("RECORDED:") {
            activeRecordingName = nil
            refreshRecordings()
            return
        }

        if status == "RECORDING_STOPPING" {
            return
        }

        if status.hasPrefix("TRANSFER_STARTED:") {
            startLocalDownload(from: status)
            return
        }

        if status.hasPrefix("TRANSFER_DONE:") {
            finishLocalDownload(from: status)
        }
    }

    private func handleManifest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let existingLocalURLs = Dictionary(uniqueKeysWithValues: recordings.compactMap { recording in
            recording.localFileURL.map { (recording.filename, $0) }
        })

        recordings = text
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count >= 3, let byteSize = Int(parts[1]) else { return nil }
                let filename = String(parts[0])
                return WearableAudioRecording(
                    filename: filename,
                    byteSize: byteSize,
                    syncState: String(parts[2]),
                    localFileURL: existingLocalURLs[filename] ?? Self.localAudioURL(filename: filename, existsOnly: true)
                )
            }

        if autoSyncNearestEnabled {
            let missingFilenames = recordings
                .filter { $0.localFileURL == nil }
                .map(\.filename)
            enqueueDownloads(missingFilenames, replaceQueue: true, skipLocalFiles: true)
        }
    }

    private func enqueueDownloads(_ filenames: [String], replaceQueue: Bool, skipLocalFiles: Bool) {
        let pending = filenames.filter { filename in
            recordings.contains(where: { recording in
                recording.filename == filename && (!skipLocalFiles || recording.localFileURL == nil)
            })
        }

        if replaceQueue {
            downloadQueue = pending
        } else {
            downloadQueue.append(contentsOf: pending.filter { !downloadQueue.contains($0) })
        }

        startNextDownloadIfNeeded()
    }

    private func startNextDownloadIfNeeded() {
        guard activeDownload == nil else { return }
        guard let filename = downloadQueue.first else {
            if isAutoSyncing {
                appendStatus("AUTO_SYNC:Complete")
            }
            isAutoSyncing = false
            return
        }

        downloadQueue.removeFirst()
        downloadProgress[filename] = 0
        writeCommand("FETCH:\(filename):0")
    }

    private func startLocalDownload(from status: String) {
        let parts = status.split(separator: ":")
        guard parts.count >= 4, let totalBytes = Int(parts[2]) else { return }
        let filename = String(parts[1])
        do {
            guard let fileURL = Self.localAudioURL(filename: filename, existsOnly: false) else {
                appendStatus("ERROR:Cannot access documents directory")
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)
            activeDownload = ActiveDownload(filename: filename, totalBytes: totalBytes, fileURL: fileURL, fileHandle: handle, receivedBytes: 0)
            downloadProgress[filename] = 0
        } catch {
            appendStatus("ERROR:Cannot create local file: \(error.localizedDescription)")
        }
    }

    private func handleTransferData(_ data: Data) {
        guard var activeDownload, data.count >= 6 else { return }
        let payloadLength = Int(UInt16(data[4]) | UInt16(data[5]) << 8)
        guard data.count >= 6 + payloadLength else { return }

        let payload = data.subdata(in: 6..<(6 + payloadLength))
        do {
            try activeDownload.fileHandle.write(contentsOf: payload)
            activeDownload.receivedBytes += payloadLength
            self.activeDownload = activeDownload
            downloadProgress[activeDownload.filename] = min(1, Double(activeDownload.receivedBytes) / Double(activeDownload.totalBytes))
        } catch {
            appendStatus("ERROR:Write failed: \(error.localizedDescription)")
        }
    }

    private func finishLocalDownload(from status: String) {
        guard let activeDownload else { return }
        do {
            try activeDownload.fileHandle.close()
        } catch {
            appendStatus("ERROR:Close failed: \(error.localizedDescription)")
        }

        recordings = recordings.map { recording in
            guard recording.filename == activeDownload.filename else { return recording }
            var updated = recording
            updated.localFileURL = activeDownload.fileURL
            return updated
        }
        downloadProgress[activeDownload.filename] = 1
        writeCommand("MARK_SYNCED:\(activeDownload.filename)")
        self.activeDownload = nil
        startNextDownloadIfNeeded()
    }

    private static func localAudioURL(filename: String, existsOnly: Bool) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = documents.appending(path: "WearableAudio", directoryHint: .isDirectory).appending(path: filename)
        if existsOnly && !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        return url
    }
}

extension WearableBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                if case .failed = state {
                    state = .idle
                }
            } else {
                state = .failed("Bluetooth is \(central.state.displayName).")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name
                ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ?? "XIAO Wearable"
            discoveredPeripherals[peripheral.identifier] = peripheral
            let device = WearablePeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }

            if autoSyncNearestEnabled {
                scheduleNearestAutoConnect()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            state = .connected(peripheral.name ?? "Wearable")
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            state = .failed(error?.localizedDescription ?? "Could not connect.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            state = error.map { .failed($0.localizedDescription) } ?? .disconnected
        }
    }
}

extension WearableBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                state = .failed(error.localizedDescription)
                return
            }

            peripheral.services?
                .filter { $0.uuid == serviceUUID }
                .forEach { peripheral.discoverCharacteristics([controlUUID, statusUUID, manifestUUID, dataUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                state = .failed(error.localizedDescription)
                return
            }

            service.characteristics?.forEach { characteristic in
                switch characteristic.uuid {
                case controlUUID:
                    controlCharacteristic = characteristic
                case statusUUID:
                    statusCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case manifestUUID:
                    manifestCharacteristic = characteristic
                case dataUUID:
                    dataCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }

            if controlCharacteristic != nil {
                writeCommand("PING")
                refreshRecordings()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                appendStatus("ERROR:\(error.localizedDescription)")
                return
            }

            guard let data = characteristic.value else { return }
            switch characteristic.uuid {
            case statusUUID:
                if let status = String(data: data, encoding: .utf8) {
                    handleStatus(status)
                }
            case manifestUUID:
                handleManifest(data)
            case dataUUID:
                handleTransferData(data)
            default:
                break
            }
        }
    }
}

private struct ActiveDownload {
    var filename: String
    var totalBytes: Int
    var fileURL: URL
    var fileHandle: FileHandle
    var receivedBytes: Int
}

private extension CBManagerState {
    var displayName: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "powered off"
        case .poweredOn: "powered on"
        @unknown default: "unavailable"
        }
    }
}
#else
@MainActor
@Observable
final class WearableBLEManager {
    var state: WearableConnectionState = .failed("Core Bluetooth is unavailable on this platform.")
    var discoveredDevices: [WearablePeripheral] = []
    var recordings: [WearableAudioRecording] = []
    var statusLog: [String] = []
    var activeRecordingName: String?
    var downloadProgress: [String: Double] = [:]
    var autoSyncNearestEnabled = false
    var isAutoSyncing = false

    func startScan() {}
    func stopScan() {}
    func startAutoSyncNearest() {}
    func stopAutoSyncNearest() {}
    func connect(to device: WearablePeripheral) {}
    func disconnect() {}
    func refreshRecordings() {}
    func startWearableRecording() {}
    func stopWearableRecording() {}
    func download(_ recording: WearableAudioRecording) {}
    func localURL(for recording: WearableAudioRecording) -> URL? { nil }
}
#endif
