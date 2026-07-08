# iOS Companion MVP Product Shape

This app starts as the control plane for the wearable, not as a replacement for the backend analysis pipeline.

## What The iOS App Should Do First

- Pair with the XIAO ESP32 wearable.
- Provision device identity, backend URL, upload token, and connectivity settings.
- Show recording jobs from the existing FastAPI backend.
- Allow manual phone uploads for testing the same pipeline as the React app.
- Poll job status and render completed metrics, transcript turns, and audio quality warnings.
- Explain device health: storage, firmware version, last upload, last connection, and pending files.

## What Stays On The Backend

The current backend should remain the MVP processing engine.

- `ffmpeg` conversion to mono 16 kHz WAV.
- `faster-whisper` transcription.
- `pyannote.audio` diarization when configured.
- `resemblyzer` embedding fallback.
- sentiment, language, timing, pause, pitch, volume, and interruption heuristics.
- storage of raw uploads, job metadata, and completed JSON results.

These Python/audio/ML dependencies are not a good direct fit for an iOS app. Some can be rewritten or replaced later with Core ML, WhisperKit, native DSP, or serverless jobs, but that is a product and accuracy project, not a quick port.

## Can We Use The Current Backend Processing In iOS?

Yes, as a remote service. The iOS app can call the existing API:

- `GET /api/recordings`
- `GET /api/recordings/{id}`
- `POST /api/recordings`

The wearable can continue to call:

- `POST /api/device/recordings/raw?filename=...`
- `POST /api/device/recordings`

The immediate gap is authentication. The current shared `X-Device-Token` works for prototype testing, but production pairing should mint per-device scoped upload tokens and let the app rotate or revoke them.

## Pairing The XIAO ESP32 Prototype

The target pairing flow should be BLE-first:

1. The XIAO advertises a custom BLE setup service while unpaired or while a setup button is held.
2. The iOS app scans for that service and shows nearby devices.
3. The app reads device ID, firmware version, capabilities, storage state, and pairing challenge.
4. The app sends backend URL and a scoped upload token.
5. If direct upload is enabled, the app sends Wi-Fi credentials for one or more approved networks.
6. The XIAO confirms by sending a health event or uploading a tiny test payload.

The current firmware does not yet implement BLE provisioning. It reads Wi-Fi credentials from `firmware_config.h`, connects as a Wi-Fi station, uploads finished WAV files, and writes `.uploaded` marker files after successful upload.

## How Can The Wearable Work Without Explicit Wi-Fi Credentials?

It cannot generally connect to arbitrary protected Wi-Fi without credentials. The realistic options are:

- Open networks: works only for networks with no password and no captive portal. This is unreliable in the real world.
- Captive portals: poor fit for a headless ESP32 wearable because they require web login, terms acceptance, cookies, or enterprise identity.
- Known networks: the app provisions credentials for home, office, lab, or phone hotspot networks. The device stores and tries those networks.
- Phone relay: the wearable sends audio or completed files to the phone, and the iPhone uploads through cellular or its own Wi-Fi. This is the strongest walking-around model.
- Phone hotspot: the iPhone exposes a hotspot and the app provisions those credentials to the wearable. This may still require user/system interaction on iOS.

For the MVP, use direct Wi-Fi upload for lab testing and phone relay as the product direction for roaming.

## Recommended Connectivity Roadmap

1. Keep direct upload for the current prototype.
2. Add BLE setup advertising to the ESP32 firmware.
3. Add iOS BLE scanning and provisioning.
4. Add per-device backend token provisioning.
5. Add device status endpoint and health events.
6. Decide between direct upload, phone relay, or both for production.

## Minimum Native Screens

- Recordings: list backend jobs, upload test audio, inspect status and completed metrics.
- Device: search/pair wearable, choose provisioning model, show device status.
- Insights: summary metrics and explainable coaching rules.
- Settings: backend URL, token status, device security, and processing boundaries.

## Apple Platform APIs To Plan Around

- Core Bluetooth: scan for the wearable's custom BLE service and exchange provisioning data.
- `NEHotspotConfiguration`: let the app add or join a specific Wi-Fi network configuration with user permission.
- Hotspot Helper: only consider this for captive-portal participation if the product qualifies for the required entitlement and review path.
