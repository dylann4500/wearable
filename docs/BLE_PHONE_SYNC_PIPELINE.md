# BLE Phone Sync Pipeline

This is the no-cloud MVP path:

```text
XIAO ESP32S3 records WAV to microSD
  -> iPhone finds XIAO over BLE
  -> iPhone starts/stops recording or lists existing SD recordings
  -> XIAO sends selected WAV in BLE chunks
  -> iPhone stores the WAV locally
  -> iPhone plays it back and can upload it later
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
- `TRANSFER_STOP`
- `MARK_SYNCED:<filename>`

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
- The first transfer uses conservative 180-byte BLE payloads. This favors reliability for bring-up; throughput tuning can come later.
