import SwiftUI

struct DevicePairingView: View {
    @Environment(WearableBLEManager.self) private var bleManager
    @Environment(AudioPlaybackController.self) private var playback

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("XIAO wearable")
                            .font(.headline)
                        Text(bleManager.state.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    connectionIndicator
                }

                HStack {
                    Button {
                        bleManager.startScan()
                    } label: {
                        Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                    }

                    Button {
                        bleManager.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(!isConnected)
                }

                Button {
                    if bleManager.autoSyncNearestEnabled {
                        bleManager.stopAutoSyncNearest()
                    } else {
                        bleManager.startAutoSyncNearest()
                    }
                } label: {
                    Label(
                        bleManager.autoSyncNearestEnabled ? "Stop auto-sync nearest" : "Auto-sync nearest wearable",
                        systemImage: bleManager.autoSyncNearestEnabled ? "stop.circle" : "arrow.down.circle"
                    )
                }
                .buttonStyle(.borderedProminent)

                if bleManager.isAutoSyncing {
                    HStack {
                        ProgressView()
                        Text("Auto-syncing SD recordings")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Auto-sync scans briefly, connects to the strongest XIAO signal, lists SD recordings, downloads missing files, and makes them available for playback.")
            }

            if !bleManager.discoveredDevices.isEmpty {
                Section("Nearby devices") {
                    ForEach(bleManager.discoveredDevices) { device in
                        Button {
                            bleManager.connect(to: device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.headline)
                                    Text("RSSI \(device.rssi)dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Section("Record on wearable") {
                HStack {
                    Button {
                        bleManager.startWearableRecording()
                    } label: {
                        Label("Start", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected || bleManager.activeRecordingName != nil)

                    Button {
                        bleManager.stopWearableRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected || bleManager.activeRecordingName == nil)
                }

                if let activeRecordingName = bleManager.activeRecordingName {
                    Label(activeRecordingName, systemImage: "waveform")
                        .foregroundStyle(.red)
                } else {
                    Text("You can also use the hardware button; completed WAV files appear after refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    bleManager.refreshRecordings()
                } label: {
                    Label("Refresh SD recordings", systemImage: "arrow.clockwise")
                }
                .disabled(!isConnected)

                if bleManager.recordings.isEmpty {
                    Text("No recordings reported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bleManager.recordings) { recording in
                        WearableRecordingRow(recording: recording)
                    }
                }
            } header: {
                Text("Wearable recordings")
            } footer: {
                Text("Downloaded recordings are stored in the app's Documents folder and can be uploaded to the cloud later.")
            }

            if !bleManager.statusLog.isEmpty {
                Section("BLE status") {
                    ForEach(bleManager.statusLog, id: \.self) { status in
                        Text(status)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Device")
        .alert("Playback failed", isPresented: playbackErrorBinding) {
            Button("OK", role: .cancel) {
                playback.errorMessage = nil
            }
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }

    private var isConnected: Bool {
        if case .connected = bleManager.state {
            return true
        }
        return false
    }

    private var connectionIndicator: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 12, height: 12)
            .accessibilityLabel(isConnected ? "Connected" : "Not connected")
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.errorMessage = nil } }
        )
    }
}

private struct WearableRecordingRow: View {
    @Environment(WearableBLEManager.self) private var bleManager
    @Environment(AudioPlaybackController.self) private var playback

    var recording: WearableAudioRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.filename)
                        .font(.headline)
                    Text("\(recording.displaySize) · \(recording.syncState)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if recording.localFileURL != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let progress = bleManager.downloadProgress[recording.filename], progress > 0, progress < 1 {
                ProgressView(value: progress)
            }

            HStack {
                Button {
                    bleManager.download(recording)
                } label: {
                    Label(recording.localFileURL == nil ? "Download" : "Download again", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                if let localFileURL = recording.localFileURL {
                    Button {
                        playback.play(url: localFileURL)
                    } label: {
                        Label(playback.playingURL == localFileURL ? "Pause" : "Play", systemImage: playback.playingURL == localFileURL ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 6)
    }
}
