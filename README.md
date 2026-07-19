# Conversation Analytics MVP

Local web app for uploading an MP3 conversation and extracting practical speech and conversation metrics.

For full hardware handoff, setup, architecture, and real-world connectivity notes, read:

```text
docs/FRIEND_SETUP_AND_ARCHITECTURE.md
```

For the quickest public backend deployment to pair with the Vercel frontend, read:

```text
docs/BACKEND_RENDER_DEPLOYMENT.md
```

For the deployed Vercel + Render + XIAO hardware test workflow, read:

```text
docs/XIAO_DEPLOYED_PLATFORM_TEST_RUNBOOK.md
```

## What It Does

- Upload an MP3 or other audio file.
- Converts audio to mono 16 kHz WAV with `ffmpeg`.
- Transcribes with local Whisper via `faster-whisper`.
- Segments the conversation into turns.
- Diarizes speakers with pyannote.audio when configured, falling back to local speaker embeddings (`resemblyzer`).
- Computes practical MVP metrics:
  - talk-time share
  - turn count and turn length
  - response latency
  - short responses and monologues
  - filler words
  - questions and follow-up questions
  - backchannels
  - speaking rate
  - pauses
  - volume and pitch summaries
  - sentiment trajectory
  - interjection / interruption heuristics
  - vocabulary and lexical complexity
  - environmental audio-quality estimates

Metrics that require custom-trained social/contextual models are intentionally excluded or treated as heuristics.

## Setup

Install `ffmpeg` once:

macOS:

```bash
brew install ffmpeg
```

Windows PowerShell:

```powershell
winget install Gyan.FFmpeg
```

The setup expects Python 3.11 or 3.12 because audio/scientific packages may not have stable wheels for newer Python releases yet. If needed:

macOS:

```bash
brew install python@3.12
```

Windows PowerShell:

```powershell
winget install Python.Python.3.12
winget install OpenJS.NodeJS.LTS
```

Run the app:

macOS/Linux:

```bash
./scripts/run.sh
```

Windows PowerShell:

```powershell
.\scripts\run.ps1
```

Open:

```text
http://127.0.0.1:8000
```

The first run downloads a Whisper model. By default it uses `base.en`, which is a good balance for local testing. You can override it:

macOS/Linux:

```bash
WHISPER_MODEL=tiny.en ./scripts/run.sh
WHISPER_MODEL=small.en ./scripts/run.sh
```

Windows PowerShell:

```powershell
$env:WHISPER_MODEL = "tiny.en"
.\scripts\run.ps1
```

## Speaker Diarization

The app has two diarization paths:

1. **Preferred:** pyannote.audio speaker timeline diarization. This is more accurate because it first asks "who spoke when?" and then assigns Whisper words to that speaker timeline.
2. **Fallback:** local `resemblyzer` embeddings clustered by transcript turns, with smoothing for isolated speaker flips.

Install the optional diarization dependencies:

macOS/Linux:

```bash
./scripts/install_diarization.sh
```

Windows PowerShell:

```powershell
.\scripts\install_diarization.ps1
```

To enable the stronger pyannote path:

1. Create a Hugging Face account.
2. Accept the terms for `pyannote/speaker-diarization-3.1`.
3. Create a read token.
4. Run with:

macOS/Linux:

```bash
HF_TOKEN=your_token_here ./scripts/run.sh
```

Windows PowerShell:

```powershell
$env:HF_TOKEN = "your_token_here"
.\scripts\run.ps1
```

Without `HF_TOKEN`, the app still runs and uses the local embedding fallback. Without optional diarization dependencies, it labels all turns as `Speaker 1`.

## Frontend

The UI is a React/Vite app in `frontend/`. `./scripts/run.sh` installs and builds it automatically when `npm` is available, then FastAPI serves the built app at `http://127.0.0.1:8000`.

## Wearable End-to-End MVP

The app now has a device ingestion path for the XIAO ESP32S3 wearable:

```text
Wearable records WAV to microSD
        -> uploads the finished file over Wi-Fi
        -> FastAPI stores a recording job
        -> background analysis runs Whisper/diarization
        -> the React dashboard shows status and results
```

### Backend Device Uploads

Set a shared token before running the backend:

macOS/Linux:

```bash
DEVICE_UPLOAD_TOKEN=dev-device-token ./scripts/run.sh
```

Windows PowerShell:

```powershell
$env:DEVICE_UPLOAD_TOKEN = "dev-device-token"
.\scripts\run.ps1
```

For local testing, open:

```text
http://127.0.0.1:8000
```

Useful endpoints:

- `POST /api/device/recordings/raw?filename=audio0001.wav` receives raw bytes from firmware.
- `POST /api/device/recordings` receives multipart uploads.
- `POST /api/recordings` receives browser test uploads.
- `GET /api/recordings` lists all recording jobs.
- `GET /api/recordings/{id}` returns one job and its result when complete.

Device requests must include:

```text
X-Device-Id: xiao-esp32s3-prototype-001
X-Device-Token: dev-device-token
```

Phone relays also send a stable `X-Upload-Id` derived from the verified WAV.
The backend uses it as an idempotency key, so reconnects and app relaunches do
not create duplicate analysis jobs.

### Test Without Hardware

Run the app, then simulate the wearable upload from your laptop:

macOS/Linux:

```bash
python scripts/simulate_device_upload.py path/to/audio.wav \
  --server http://127.0.0.1:8000 \
  --device-id simulated-xiao \
  --token dev-device-token
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe scripts\simulate_device_upload.py path\to\audio.wav `
  --server http://127.0.0.1:8000 `
  --device-id simulated-xiao `
  --token dev-device-token
```

The upload should appear in the sidebar as `Uploaded` or `Processing`, then change to `Complete` when analysis finishes.

You can also run the no-hardware API test suite. It mocks the expensive analyzer and verifies the device upload/job/result path:

```bash
npm test
```

### Testing With the XIAO

In `firmware/xiao-esp32s3-prototype/`, create a local firmware config:

macOS/Linux:

```bash
cp firmware_config.example.h firmware_config.h
```

Windows PowerShell:

```powershell
Copy-Item firmware_config.example.h firmware_config.h
```

Then update `firmware_config.h`:

```cpp
const char *WIFI_SSID = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";
const char *SERVER_BASE_URL = "http://192.168.1.42:8000";
const char *DEVICE_UPLOAD_TOKEN = "dev-device-token";
```

For same-network testing, use the laptop's LAN IP, not `127.0.0.1`. For remote testing, use an HTTPS tunnel such as ngrok and set `SERVER_BASE_URL` to that public URL.

When the board starts, it scans `/Audio` for `.wav` files without a `.uploaded` marker and tries to upload them. After each new recording, it uploads the file immediately. The Serial Monitor logs Wi-Fi connection status, upload URL, HTTP status, and backend response.

Compile-check the firmware from the repository root:

macOS/Linux:

```bash
.venv/bin/python -m pip install platformio
npm run build:firmware
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe -m pip install platformio
npm run build:firmware
```

This uses the pioarduino ESP32 platform because the sketch depends on the ESP32 Arduino 3.x `ESP_I2S.h` API.

## Notes

- `Speaker 1` is treated as the user for user-specific summaries.
- Interjections are estimated from very short-latency speaker changes and short acknowledgments. True overlap detection still needs a dedicated overlap-aware diarization model.
- Audio files are saved under `uploads/`, which is git-ignored.
- Recording job metadata is stored in `recordings.sqlite3`, and completed analysis JSON is stored under `recording_results/`.
