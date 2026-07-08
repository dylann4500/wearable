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
    private var manifestPollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var downloadWatchdogTask: Task<Void, Never>?
    private var downloadQueue: [String] = []
    private var downloadRetryCounts: [String: Int] = [:]
    private var statusNotificationsReady = false
    private var dataNotificationsReady = false
    private var protocolStarted = false

    var state: WearableConnectionState = .idle
    var discoveredDevices: [WearablePeripheral] = []
    var recordings: [WearableAudioRecording] = []
    var statusLog: [String] = []
    var activeRecordingName: String?
    var downloadProgress: [String: Double] = [:]
    var autoSyncNearestEnabled = true
    var isAutoSyncing = false

    override init() {
        super.init()
        UserDefaults.standard.removeObject(forKey: "PendingWearableRecordingDeletions")
        recordings = Self.loadLocalRecordings()
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
        guard !isConnected else {
            autoSyncNearestEnabled = true
            beginManifestPolling()
            refreshRecordings()
            return
        }
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
        manifestPollingTask?.cancel()
        manifestPollingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
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
        downloadRetryCounts[recording.filename] = 0
        enqueueDownloads([recording.filename], replaceQueue: true, skipLocalFiles: false)
    }

    func localURL(for recording: WearableAudioRecording) -> URL? {
        recordings.first(where: { $0.filename == recording.filename })?.localFileURL
    }

    func transferState(for recording: WearableAudioRecording) -> WearableTransferState {
        if recording.localFileURL != nil {
            return .downloaded
        }
        if activeDownload?.filename == recording.filename {
            return .downloading(downloadProgress[recording.filename] ?? 0)
        }
        if downloadQueue.contains(recording.filename) || downloadProgress[recording.filename] == 0 {
            return .queued
        }
        return .onWearable
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
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
                    self.scheduleReconnect()
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
            return
        }

        if status.hasPrefix("TRANSFER_ERROR:") || status.hasPrefix("TRANSFER_STOPPED:") {
            failActiveDownload(reason: status)
        }
    }

    private func handleManifest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let remoteRecordings: [WearableAudioRecording] = text
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count >= 3, let byteSize = Int(parts[1]) else { return nil }
                let filename = String(parts[0])
                let localURL = Self.validatedLocalAudioURL(filename: filename, expectedSize: byteSize)
                return WearableAudioRecording(
                    filename: filename,
                    byteSize: byteSize,
                    syncState: String(parts[2]),
                    localFileURL: localURL
                )
            }
        let remoteNames = Set(remoteRecordings.map(\.filename))
        recordings = remoteRecordings + recordings.filter {
            $0.localFileURL != nil && !remoteNames.contains($0.filename)
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
            guard activeDownload?.filename != filename else { return false }
            return recordings.contains(where: { recording in
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
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                appendStatus("ERROR:Cannot create local audio file")
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            activeDownload = ActiveDownload(filename: filename, totalBytes: totalBytes, fileURL: fileURL, fileHandle: handle, receivedBytes: 0)
            downloadProgress[filename] = 0
            scheduleDownloadWatchdog()
            writeCommand("TRANSFER_READY:\(filename)")
        } catch {
            appendStatus("ERROR:Cannot create local file: \(error.localizedDescription)")
        }
    }

    private func handleTransferData(_ data: Data) {
        guard var activeDownload, data.count >= 6 else { return }
        let packetOffset = Int(
            UInt32(data[0])
                | UInt32(data[1]) << 8
                | UInt32(data[2]) << 16
                | UInt32(data[3]) << 24
        )
        let payloadLength = Int(UInt16(data[4]) | UInt16(data[5]) << 8)
        guard data.count >= 6 + payloadLength else { return }
        guard !activeDownload.isCorrupted else { return }
        guard packetOffset == activeDownload.receivedBytes else {
            activeDownload.isCorrupted = true
            self.activeDownload = activeDownload
            appendStatus("TRANSFER_GAP:\(activeDownload.filename):expected \(activeDownload.receivedBytes):received \(packetOffset)")
            writeCommand("TRANSFER_STOP")
            return
        }

        let payload = data.subdata(in: 6..<(6 + payloadLength))
        do {
            try activeDownload.fileHandle.write(contentsOf: payload)
            activeDownload.receivedBytes += payloadLength
            self.activeDownload = activeDownload
            downloadProgress[activeDownload.filename] = min(1, Double(activeDownload.receivedBytes) / Double(activeDownload.totalBytes))
            scheduleDownloadWatchdog()
        } catch {
            appendStatus("ERROR:Write failed: \(error.localizedDescription)")
        }
    }

    private func finishLocalDownload(from status: String) {
        guard let activeDownload else { return }
        downloadWatchdogTask?.cancel()
        downloadWatchdogTask = nil
        do {
            try activeDownload.fileHandle.close()
        } catch {
            appendStatus("ERROR:Close failed: \(error.localizedDescription)")
        }

        let isComplete = !activeDownload.isCorrupted
            && activeDownload.receivedBytes == activeDownload.totalBytes
            && Self.isValidWAV(at: activeDownload.fileURL, expectedSize: activeDownload.totalBytes)

        guard isComplete else {
            try? FileManager.default.removeItem(at: activeDownload.fileURL)
            downloadProgress[activeDownload.filename] = 0
            self.activeDownload = nil

            let retryCount = downloadRetryCounts[activeDownload.filename, default: 0]
            if retryCount < 2 {
                downloadRetryCounts[activeDownload.filename] = retryCount + 1
                downloadQueue.insert(activeDownload.filename, at: 0)
                appendStatus("TRANSFER_RETRY:\(activeDownload.filename)")
            } else {
                downloadProgress[activeDownload.filename] = nil
                appendStatus("ERROR:Transfer validation failed for \(activeDownload.filename)")
            }
            startNextDownloadIfNeeded()
            return
        }

        recordings = recordings.map { recording in
            guard recording.filename == activeDownload.filename else { return recording }
            var updated = recording
            updated.localFileURL = activeDownload.fileURL
            return updated
        }
        downloadProgress[activeDownload.filename] = 1
        downloadRetryCounts[activeDownload.filename] = nil
        writeCommand("MARK_SYNCED:\(activeDownload.filename)")
        self.activeDownload = nil
        startNextDownloadIfNeeded()
    }

    private func scheduleDownloadWatchdog() {
        downloadWatchdogTask?.cancel()
        guard let activeDownload else { return }
        let filename = activeDownload.filename
        let receivedBytes = activeDownload.receivedBytes
        downloadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                guard let self,
                      let current = self.activeDownload,
                      current.filename == filename,
                      current.receivedBytes == receivedBytes
                else { return }
                self.writeCommand("TRANSFER_STOP")
                self.failActiveDownload(reason: "TRANSFER_TIMEOUT:\(filename)")
            }
        }
    }

    private func failActiveDownload(reason: String) {
        guard let activeDownload else { return }
        downloadWatchdogTask?.cancel()
        downloadWatchdogTask = nil
        try? activeDownload.fileHandle.close()
        try? FileManager.default.removeItem(at: activeDownload.fileURL)
        self.activeDownload = nil
        downloadProgress[activeDownload.filename] = 0

        let retryCount = downloadRetryCounts[activeDownload.filename, default: 0]
        if retryCount < 2 {
            downloadRetryCounts[activeDownload.filename] = retryCount + 1
            appendStatus("\(reason):Retrying")
            let filename = activeDownload.filename
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                await MainActor.run {
                    guard let self else { return }
                    self.enqueueDownloads([filename], replaceQueue: false, skipLocalFiles: true)
                }
            }
        } else {
            downloadProgress[activeDownload.filename] = nil
            appendStatus("\(reason):Retry limit reached")
        }
        startNextDownloadIfNeeded()
    }

    private func beginProtocolIfReady() {
        guard controlCharacteristic != nil,
              statusNotificationsReady,
              dataNotificationsReady,
              !protocolStarted
        else { return }
        protocolStarted = true
        writeCommand("PING")
        refreshRecordings()
    }

    private func beginManifestPolling() {
        manifestPollingTask?.cancel()
        manifestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.autoSyncNearestEnabled, self.isConnected else { return }
                    self.refreshRecordings()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard autoSyncNearestEnabled, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                guard let self, self.autoSyncNearestEnabled, !self.isConnected else { return }
                self.reconnectTask = nil
                self.startAutoSyncNearest()
            }
        }
    }

    private static func loadLocalRecordings() -> [WearableAudioRecording] {
        guard let directory = localAudioURL(filename: "", existsOnly: false),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return urls
            .filter { ["wav", "mp3", "m4a"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if url.pathExtension.lowercased() == "wav", !isValidWAV(at: url, expectedSize: size) {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return WearableAudioRecording(
                    filename: url.lastPathComponent,
                    byteSize: size,
                    syncState: "local",
                    localFileURL: url
                )
            }
            .sorted { $0.filename > $1.filename }
    }

    private static func validatedLocalAudioURL(filename: String, expectedSize: Int) -> URL? {
        guard let url = localAudioURL(filename: filename, existsOnly: true) else { return nil }
        guard isValidWAV(at: url, expectedSize: expectedSize) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private static func isValidWAV(at url: URL, expectedSize: Int) -> Bool {
        guard expectedSize > 44,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue == expectedSize,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }

        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44),
              header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[36..<40], encoding: .ascii) == "data"
        else { return false }

        let riffSize = Int(readUInt32LE(header, at: 4))
        let dataSize = Int(readUInt32LE(header, at: 40))
        return riffSize == expectedSize - 8 && dataSize == expectedSize - 44
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
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
                if autoSyncNearestEnabled {
                    startAutoSyncNearest()
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
            statusNotificationsReady = false
            dataNotificationsReady = false
            protocolStarted = false
            reconnectTask?.cancel()
            reconnectTask = nil
            beginManifestPolling()
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            state = .failed(error?.localizedDescription ?? "Could not connect.")
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            state = error.map { .failed($0.localizedDescription) } ?? .disconnected
            manifestPollingTask?.cancel()
            manifestPollingTask = nil
            downloadWatchdogTask?.cancel()
            downloadWatchdogTask = nil
            statusNotificationsReady = false
            dataNotificationsReady = false
            protocolStarted = false
            scheduleReconnect()
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

            beginProtocolIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                appendStatus("ERROR:Notification setup failed: \(error.localizedDescription)")
                return
            }

            if characteristic.uuid == statusUUID {
                statusNotificationsReady = characteristic.isNotifying
            } else if characteristic.uuid == dataUUID {
                dataNotificationsReady = characteristic.isNotifying
            }
            beginProtocolIfReady()
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
    var isCorrupted = false
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
    var autoSyncNearestEnabled = true
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
    func transferState(for recording: WearableAudioRecording) -> WearableTransferState {
        recording.localFileURL == nil ? .onWearable : .downloaded
    }
}
#endif
