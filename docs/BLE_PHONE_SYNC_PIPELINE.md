# BLE Phone Sync Pipeline

This is the phone-relay analysis path:

```text
XIAO ESP32S3 records WAV to microSD
  -> iPhone finds XIAO over BLE
  -> iPhone starts/stops recording or lists existing SD recordings
  -> XIAO sends selected WAV in BLE chunks
  -> iPhone validates and stores the WAV locally
  -> iPhone queues a file-backed HTTPS upload
  -> FastAPI creates an idempotent recording job
  -> backend runs transcription, diarization, metrics, and insights
  -> iPhone displays the completed scores and coaching evidence
```

## Firmware

The firmware advertises:

- Device name: `XIAO Speech Prototype`
- Service UUID: `8f2a0001-7b4f-4f9d-9d3f-2f5c0a7a9000`

Characteristics:

- Control write: `8f2a0002-7b4f-4f9d-9d3f-2f5c0a7a9000`
- Status read/notify: `8f2a0003-7b4f-4f9d-9d3f-2f5c0a7a9000`
- Recording manifest read: `8f2a0004-7b4f-4f9d-9d3f-2f5c0a7a9000`
- Binary data notify: `8f2a0005-7b4f-4f9d-9d3f-2f5c0a7a9000`

Control commands:

- `PING`
- `LIST`
- `RECORD_START`
- `RECORD_STOP`
- `FETCH:<filename>:<offset>`
- `TRANSFER_READY:<filename>`
- `TRANSFER_ACK:<filename>:<next-offset>`
- `TRANSFER_STOP`
- `MARK_SYNCED:<filename>`

The data characteristic uses an 8-packet sliding window. Each packet contains
a 32-bit file offset, a 16-bit payload length, and up to 160 payload bytes.
After each window, the phone acknowledges the next byte it expects. The
wearable retransmits from that offset after a gap, and reconnects resume from
the retained `.part` file. `TRANSFER_STARTED` includes the complete-file CRC32;
the phone validates size, WAV structure, and CRC before atomically committing
the local `.wav`.

## iOS App

Open:

```text
ios/WearableCompanionApp/WearableCompanionApp.xcodeproj
```

Use the Device tab:

Automatic path:

1. Tap `Auto-sync nearest wearable`.
2. Keep the XIAO nearby.
3. The app scans briefly, connects to the strongest matching wearable, refreshes the SD-card manifest, downloads recordings that are not already on the phone, and enables playback.

Manual path:

1. Tap `Scan`.
2. Tap `XIAO Speech Prototype`.
3. Tap `Start` to start recording on the wearable.
4. Tap `Stop` to finish the WAV file on the SD card.
5. Tap `Refresh SD recordings`.
6. Tap `Download`.
7. Tap `Play`.

Bluetooth does not work in the iOS Simulator for real hardware scanning. Use a physical iPhone.

## Notes

- Wi-Fi upload is disabled by default in `firmware_config.example.h` so BLE testing does not block on network credentials.
- Files remain on the SD card after phone sync. The firmware writes a `.phone_synced` marker when the iPhone confirms download.
- A verified local WAV emits a `CompletedWearableDownload`. `RecordingPipelineCoordinator`
  persists and deduplicates the relay job by filename, byte size, and CRC32. If
  the backend is disabled, the job remains in `Waiting for backend` state.
- Phone relay uses `POST /api/device/recordings/raw?filename=...` with
  `X-Device-Id`, `X-Device-Token`, and a stable `X-Upload-Id`. Repeating an
  upload ID returns the existing recording job instead of analyzing a duplicate.
- The coordinator serializes uploads and polls `GET /api/recordings/{id}` until
  analysis is complete or failed. The Insights tab reads the real
  `result.insights` and `result.interpretation` response rather than mock data.
- New recordings are written to a `.recording` temporary path and renamed to
  `.wav` only after the final header is safely written. The manifest also
  rejects legacy incomplete WAVs left by an interrupted recording.
- Transfers use 160-byte payloads with cumulative acknowledgements and
  backpressure instead of relying on a fixed delay between unacknowledged
  notifications.
