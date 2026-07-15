import Foundation
import Observation
import OSLog

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
    private var requestWatchdogTask: Task<Void, Never>?
    private var downloadQueue: [String] = []
    private var downloadRetryCounts: [String: Int] = [:]
    private var terminalDownloadFailures: Set<String> = []
    private var pendingDownloadFilename: String?
    private var controlCommandQueue: [Data] = []
    private var controlWriteInFlight = false
    private var statusNotificationsReady = false
    private var dataNotificationsReady = false
    private var protocolStarted = false
    private let acknowledgementWindowPackets = 8
    private let diskBufferSize = 32 * 1024
    private let maximumDownloadRetries = 3
    private let logger = Logger(subsystem: "com.example.WearableCompanion", category: "BLE")

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
        autoSyncNearestEnabled = true
        isAutoSyncing = true
        guard central.state == .poweredOn else { return }
        guard !isConnected else {
            beginManifestPolling()
            refreshRecordings()
            return
        }
        if case .scanning = state { return }
        if case .connecting = state { return }
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
        if activeDownload != nil || pendingDownloadFilename != nil {
            writeCommand("TRANSFER_STOP")
            cancelCurrentDownload(keepPartialFile: true)
        }
        appendStatus("AUTO_SYNC:Stopped")
    }

    func connect(to device: WearablePeripheral) {
        guard !isConnected else { return }
        if case .connecting = state { return }
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
        terminalDownloadFailures.remove(recording.filename)
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
        if terminalDownloadFailures.contains(recording.filename) {
            return .failed
        }
        if pendingDownloadFilename == recording.filename
            || downloadQueue.contains(recording.filename)
            || downloadProgress[recording.filename] == 0 {
            return .queued
        }
        return .onWearable
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private func writeCommand(_ command: String) {
        guard connectedPeripheral != nil, controlCharacteristic != nil else {
            appendStatus("ERROR:Not connected")
            return
        }

        guard let data = command.data(using: .utf8) else { return }
        controlCommandQueue.append(data)
        sendNextControlCommandIfPossible()
    }

    private func sendNextControlCommandIfPossible() {
        guard !controlWriteInFlight,
              !controlCommandQueue.isEmpty,
              let peripheral = connectedPeripheral,
              let controlCharacteristic
        else { return }

        let data = controlCommandQueue.removeFirst()
        if controlCharacteristic.properties.contains(.write) {
            controlWriteInFlight = true
            peripheral.writeValue(data, for: controlCharacteristic, type: .withResponse)
        } else if controlCharacteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else {
                controlCommandQueue.insert(data, at: 0)
                return
            }
            peripheral.writeValue(data, for: controlCharacteristic, type: .withoutResponse)
            sendNextControlCommandIfPossible()
        } else {
            appendStatus("ERROR:Control characteristic is not writable")
        }
    }

    private func scheduleNearestAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard let self, self.autoSyncNearestEnabled else { return }
                self.autoConnectTask = nil
                guard case .scanning = self.state else { return }
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
        logger.info("\(status, privacy: .public)")
        #if DEBUG
        print("[BLE] \(status)")
        #endif
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
            if let activeDownload, activeDownload.receivedBytes == activeDownload.totalBytes {
                finishLocalDownload()
            }
            return
        }

        if status.hasPrefix("TRANSFER_ERROR:") || status.hasPrefix("TRANSFER_STOPPED:") {
            failCurrentDownload(reason: status, keepPartialFile: true)
            return
        }

        if status.hasPrefix("ERROR:") || status.hasPrefix("BUSY:") {
            if activeDownload != nil || pendingDownloadFilename != nil {
                failCurrentDownload(reason: status, keepPartialFile: true)
            }
        }
    }

    private func handleManifest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        if text.hasPrefix("ERROR|") {
            appendStatus("ERROR:\(text.replacingOccurrences(of: "|", with: ":"))")
            return
        }

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
                .filter { $0.localFileURL == nil && !terminalDownloadFailures.contains($0.filename) }
                .map(\.filename)
            enqueueDownloads(missingFilenames, replaceQueue: true, skipLocalFiles: true)
        }
    }

    private func enqueueDownloads(_ filenames: [String], replaceQueue: Bool, skipLocalFiles: Bool) {
        let pending = filenames.filter { filename in
            guard activeDownload?.filename != filename else { return false }
            guard pendingDownloadFilename != filename else { return false }
            guard !terminalDownloadFailures.contains(filename) else { return false }
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
        guard isConnected, protocolStarted else { return }
        guard activeDownload == nil, pendingDownloadFilename == nil else { return }
        guard let filename = downloadQueue.first else {
            if isAutoSyncing {
                appendStatus("AUTO_SYNC:Complete")
            }
            isAutoSyncing = false
            return
        }

        downloadQueue.removeFirst()
        let offset = partialDownloadOffset(for: filename)
        pendingDownloadFilename = filename
        downloadProgress[filename] = progress(filename: filename, receivedBytes: offset)
        writeCommand("FETCH:\(filename):\(offset)")
        scheduleRequestWatchdog(for: filename)
    }

    private func startLocalDownload(from status: String) {
        let parts = status.split(separator: ":")
        guard parts.count >= 5,
              let totalBytes = Int(parts[2]),
              let requestedOffset = Int(parts[3]),
              let expectedCRC32 = UInt32(parts[4])
        else {
            failCurrentDownload(reason: "TRANSFER_ERROR:Malformed start status", keepPartialFile: false)
            return
        }
        let filename = String(parts[1])
        guard pendingDownloadFilename == filename else {
            appendStatus("TRANSFER_IGNORED:Unexpected start for \(filename)")
            writeCommand("TRANSFER_STOP")
            return
        }

        requestWatchdogTask?.cancel()
        requestWatchdogTask = nil
        do {
            guard let finalFileURL = Self.localAudioURL(filename: filename, existsOnly: false),
                  let partialFileURL = Self.partialAudioURL(filename: filename)
            else {
                appendStatus("ERROR:Cannot access documents directory")
                pendingDownloadFilename = nil
                return
            }

            try FileManager.default.createDirectory(
                at: partialFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existingSize = Self.fileSize(at: partialFileURL)
            guard existingSize == requestedOffset else {
                try? FileManager.default.removeItem(at: partialFileURL)
                pendingDownloadFilename = nil
                writeCommand("TRANSFER_STOP")
                scheduleRetry(filename: filename, reason: "TRANSFER_ERROR:Resume offset mismatch", keepPartialFile: false)
                return
            }

            if requestedOffset == 0, FileManager.default.fileExists(atPath: partialFileURL.path) {
                try FileManager.default.removeItem(at: partialFileURL)
            }
            if !FileManager.default.fileExists(atPath: partialFileURL.path),
               !FileManager.default.createFile(atPath: partialFileURL.path, contents: nil) {
                appendStatus("ERROR:Cannot create local audio file")
                pendingDownloadFilename = nil
                return
            }

            let handle = try FileHandle(forWritingTo: partialFileURL)
            try handle.seekToEnd()
            activeDownload = ActiveDownload(
                filename: filename,
                totalBytes: totalBytes,
                expectedCRC32: expectedCRC32,
                partialFileURL: partialFileURL,
                finalFileURL: finalFileURL,
                fileHandle: handle,
                receivedBytes: requestedOffset,
                unflushedData: Data(),
                packetsSinceAcknowledgement: 0,
                lastPublishedBytes: requestedOffset
            )
            pendingDownloadFilename = nil
            downloadProgress[filename] = progress(filename: filename, receivedBytes: requestedOffset)
            scheduleDownloadWatchdog()
            writeCommand("TRANSFER_READY:\(filename)")
        } catch {
            pendingDownloadFilename = nil
            appendStatus("ERROR:Cannot create local file: \(error.localizedDescription)")
            scheduleRetry(filename: filename, reason: "TRANSFER_ERROR:Local file setup failed", keepPartialFile: false)
        }
    }

    private func handleTransferData(_ data: Data) {
        guard var activeDownload, let packet = BLEDataPacket(data: data) else { return }

        if packet.offset < activeDownload.receivedBytes {
            writeCommand("TRANSFER_ACK:\(activeDownload.filename):\(activeDownload.receivedBytes)")
            return
        }
        guard packet.offset == activeDownload.receivedBytes else {
            appendStatus(
                "TRANSFER_GAP:\(activeDownload.filename):expected \(activeDownload.receivedBytes):received \(packet.offset)"
            )
            writeCommand("TRANSFER_ACK:\(activeDownload.filename):\(activeDownload.receivedBytes)")
            return
        }
        guard activeDownload.receivedBytes + packet.payload.count <= activeDownload.totalBytes else {
            failCurrentDownload(reason: "TRANSFER_ERROR:Payload exceeds declared file size", keepPartialFile: false)
            return
        }

        do {
            activeDownload.unflushedData.append(packet.payload)
            activeDownload.receivedBytes += packet.payload.count
            activeDownload.packetsSinceAcknowledgement += 1

            if activeDownload.unflushedData.count >= diskBufferSize
                || activeDownload.receivedBytes == activeDownload.totalBytes {
                try flushBufferedData(&activeDownload)
            }

            if activeDownload.receivedBytes - activeDownload.lastPublishedBytes >= 4 * 1024
                || activeDownload.receivedBytes == activeDownload.totalBytes {
                activeDownload.lastPublishedBytes = activeDownload.receivedBytes
                downloadProgress[activeDownload.filename] = min(
                    1,
                    Double(activeDownload.receivedBytes) / Double(activeDownload.totalBytes)
                )
            }

            let shouldAcknowledge = activeDownload.packetsSinceAcknowledgement >= acknowledgementWindowPackets
                || activeDownload.receivedBytes == activeDownload.totalBytes
            if shouldAcknowledge {
                activeDownload.packetsSinceAcknowledgement = 0
                writeCommand("TRANSFER_ACK:\(activeDownload.filename):\(activeDownload.receivedBytes)")
            }

            self.activeDownload = activeDownload
            scheduleDownloadWatchdog()

            if activeDownload.receivedBytes == activeDownload.totalBytes {
                finishLocalDownload()
            }
        } catch {
            failCurrentDownload(
                reason: "TRANSFER_ERROR:Write failed: \(error.localizedDescription)",
                keepPartialFile: false
            )
        }
    }

    private func flushBufferedData(_ activeDownload: inout ActiveDownload) throws {
        guard !activeDownload.unflushedData.isEmpty else { return }
        try activeDownload.fileHandle.write(contentsOf: activeDownload.unflushedData)
        activeDownload.unflushedData.removeAll(keepingCapacity: true)
    }

    private func finishLocalDownload() {
        guard var activeDownload else { return }
        downloadWatchdogTask?.cancel()
        downloadWatchdogTask = nil
        do {
            try flushBufferedData(&activeDownload)
            try activeDownload.fileHandle.close()
        } catch {
            failCurrentDownload(
                reason: "TRANSFER_ERROR:Close failed: \(error.localizedDescription)",
                keepPartialFile: false
            )
            return
        }

        let actualCRC32 = CRC32.checksum(fileAt: activeDownload.partialFileURL)
        let isComplete = activeDownload.receivedBytes == activeDownload.totalBytes
            && Self.isValidWAV(at: activeDownload.partialFileURL, expectedSize: activeDownload.totalBytes)
            && actualCRC32 == activeDownload.expectedCRC32

        guard isComplete else {
            self.activeDownload = nil
            try? FileManager.default.removeItem(at: activeDownload.partialFileURL)
            scheduleRetry(
                filename: activeDownload.filename,
                reason: "TRANSFER_ERROR:WAV or CRC validation failed",
                keepPartialFile: false
            )
            return
        }

        do {
            if FileManager.default.fileExists(atPath: activeDownload.finalFileURL.path) {
                try FileManager.default.removeItem(at: activeDownload.finalFileURL)
            }
            try FileManager.default.moveItem(
                at: activeDownload.partialFileURL,
                to: activeDownload.finalFileURL
            )
        } catch {
            self.activeDownload = nil
            scheduleRetry(
                filename: activeDownload.filename,
                reason: "TRANSFER_ERROR:Cannot commit downloaded file",
                keepPartialFile: true
            )
            return
        }

        recordings = recordings.map { recording in
            guard recording.filename == activeDownload.filename else { return recording }
            var updated = recording
            updated.localFileURL = activeDownload.finalFileURL
            return updated
        }
        downloadProgress[activeDownload.filename] = 1
        downloadRetryCounts[activeDownload.filename] = nil
        terminalDownloadFailures.remove(activeDownload.filename)
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
                self.failCurrentDownload(reason: "TRANSFER_TIMEOUT:\(filename)", keepPartialFile: true)
            }
        }
    }

    private func scheduleRequestWatchdog(for filename: String) {
        requestWatchdogTask?.cancel()
        requestWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                guard let self, self.pendingDownloadFilename == filename else { return }
                self.failCurrentDownload(
                    reason: "TRANSFER_REQUEST_TIMEOUT:\(filename)",
                    keepPartialFile: true
                )
            }
        }
    }

    private func failCurrentDownload(reason: String, keepPartialFile: Bool) {
        let filename = activeDownload?.filename ?? pendingDownloadFilename
        guard let filename else { return }
        writeCommand("TRANSFER_STOP")
        cancelCurrentDownload(keepPartialFile: keepPartialFile)
        scheduleRetry(filename: filename, reason: reason, keepPartialFile: keepPartialFile)
    }

    private func cancelCurrentDownload(keepPartialFile: Bool) {
        downloadWatchdogTask?.cancel()
        downloadWatchdogTask = nil
        requestWatchdogTask?.cancel()
        requestWatchdogTask = nil
        if let activeDownload {
            var download = activeDownload
            try? flushBufferedData(&download)
            try? download.fileHandle.close()
            if !keepPartialFile {
                try? FileManager.default.removeItem(at: download.partialFileURL)
            }
        }
        self.activeDownload = nil
        pendingDownloadFilename = nil
    }

    private func scheduleRetry(filename: String, reason: String, keepPartialFile: Bool) {
        if !keepPartialFile, let partialURL = Self.partialAudioURL(filename: filename) {
            try? FileManager.default.removeItem(at: partialURL)
        }

        let retryCount = downloadRetryCounts[filename, default: 0]
        if retryCount < maximumDownloadRetries {
            downloadRetryCounts[filename] = retryCount + 1
            downloadProgress[filename] = progress(
                filename: filename,
                receivedBytes: partialDownloadOffset(for: filename)
            )
            appendStatus("\(reason):Retrying")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    guard let self else { return }
                    if !self.downloadQueue.contains(filename) {
                        self.downloadQueue.insert(filename, at: 0)
                    }
                    self.startNextDownloadIfNeeded()
                }
            }
        } else {
            terminalDownloadFailures.insert(filename)
            downloadProgress[filename] = nil
            appendStatus("\(reason):Retry limit reached")
            startNextDownloadIfNeeded()
        }
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
        beginManifestPolling()
    }

    private func beginManifestPolling() {
        manifestPollingTask?.cancel()
        manifestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.autoSyncNearestEnabled,
                          self.isConnected,
                          self.activeDownload == nil,
                          self.pendingDownloadFilename == nil
                    else { return }
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

    private func partialDownloadOffset(for filename: String) -> Int {
        guard let recording = recordings.first(where: { $0.filename == filename }),
              let partialURL = Self.partialAudioURL(filename: filename)
        else { return 0 }

        let size = Self.fileSize(at: partialURL)
        guard size >= 0, size < recording.byteSize else {
            try? FileManager.default.removeItem(at: partialURL)
            return 0
        }
        return size
    }

    private func progress(filename: String, receivedBytes: Int) -> Double {
        guard let totalBytes = recordings.first(where: { $0.filename == filename })?.byteSize,
              totalBytes > 0
        else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
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

    private static func partialAudioURL(filename: String) -> URL? {
        localAudioURL(filename: "\(filename).part", existsOnly: false)
    }

    private static func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }
}

extension WearableBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
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
        MainActor.assumeIsolated {
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

            if autoSyncNearestEnabled, case .scanning = state {
                scheduleNearestAutoConnect()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .connected(peripheral.name ?? "Wearable")
            autoConnectTask?.cancel()
            autoConnectTask = nil
            controlCommandQueue = []
            controlWriteInFlight = false
            statusNotificationsReady = false
            dataNotificationsReady = false
            protocolStarted = false
            reconnectTask?.cancel()
            reconnectTask = nil
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            state = .failed(error?.localizedDescription ?? "Could not connect.")
            connectedPeripheral = nil
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let interruptedFilename = activeDownload?.filename ?? pendingDownloadFilename
            cancelCurrentDownload(keepPartialFile: true)
            if let interruptedFilename,
               !terminalDownloadFailures.contains(interruptedFilename),
               !downloadQueue.contains(interruptedFilename) {
                downloadQueue.insert(interruptedFilename, at: 0)
            }
            state = error.map { .failed($0.localizedDescription) } ?? .disconnected
            manifestPollingTask?.cancel()
            manifestPollingTask = nil
            controlCommandQueue = []
            controlWriteInFlight = false
            controlCharacteristic = nil
            statusCharacteristic = nil
            manifestCharacteristic = nil
            dataCharacteristic = nil
            connectedPeripheral = nil
            statusNotificationsReady = false
            dataNotificationsReady = false
            protocolStarted = false
            scheduleReconnect()
        }
    }
}

extension WearableBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
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
        MainActor.assumeIsolated {
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
        MainActor.assumeIsolated {
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
        MainActor.assumeIsolated {
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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                appendStatus("ERROR:Control write failed: \(error.localizedDescription)")
            }
            controlWriteInFlight = false
            sendNextControlCommandIfPossible()
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            sendNextControlCommandIfPossible()
        }
    }
}

private struct ActiveDownload {
    var filename: String
    var totalBytes: Int
    var expectedCRC32: UInt32
    var partialFileURL: URL
    var finalFileURL: URL
    var fileHandle: FileHandle
    var receivedBytes: Int
    var unflushedData: Data
    var packetsSinceAcknowledgement: Int
    var lastPublishedBytes: Int
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
