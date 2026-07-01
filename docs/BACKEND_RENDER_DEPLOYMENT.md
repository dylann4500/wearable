# Backend Deployment on Render

Use this to deploy the FastAPI backend publicly while the frontend stays on Vercel.

## Target Architecture

```text
Vercel frontend
  VITE_API_BASE_URL=https://your-render-service.onrender.com

Render backend
  FastAPI upload/status/results API
  ffmpeg + Whisper analyzer
  persistent disk mounted at /var/data

Wearable firmware
  SERVER_BASE_URL=https://your-render-service.onrender.com
```

## Render Service Settings

Create a new Render **Web Service** from the GitHub repository.

Use these settings:

```text
Runtime: Docker
Dockerfile path: Dockerfile
Instance type: paid/starter or better for always-on testing
```

Free instances can sleep. For wearable testing, use an always-on paid instance so the device does not upload into a sleeping server.

## Persistent Disk

Add a persistent disk:

```text
Mount path: /var/data
Size: 1 GB or larger
```

The Dockerfile configures:

```text
UPLOAD_DIR=/var/data/uploads
RUN_DIR=/var/data/analysis_runs
RESULT_DIR=/var/data/recording_results
RECORDINGS_DB=/var/data/recordings.sqlite3
```

This preserves uploaded audio, analysis runs, result JSON, and the SQLite job database across restarts.

## Environment Variables

Set these in Render:

```text
DEVICE_UPLOAD_TOKEN=choose-a-long-random-secret
WHISPER_MODEL=tiny.en
WHISPER_DEVICE=cpu
WHISPER_COMPUTE_TYPE=int8
```

Optional:

```text
HF_TOKEN=your_hugging_face_token
```

Use `tiny.en` first for faster CPU testing. Move to `base.en` or better once the deploy works.

## Health Check

After deploy, open:

```text
https://your-render-service.onrender.com/api/health
```

Expected:

```json
{"status":"ok"}
```

## Connect Vercel Frontend

In Vercel project settings, set:

```text
VITE_API_BASE_URL=https://your-render-service.onrender.com
```

Redeploy the Vercel app.

## Connect Wearable

In `firmware_config.h`, set:

```cpp
const char *SERVER_BASE_URL = "https://your-render-service.onrender.com";
const char *DEVICE_UPLOAD_TOKEN = "same-secret-as-render";
```

The wearable still needs Wi-Fi credentials or a hotspot:

```cpp
const char *WIFI_SSID = "your_wifi_or_hotspot";
const char *WIFI_PASSWORD = "your_password";
```

## Test Without Hardware

Run this locally:

```bash
python scripts/simulate_device_upload.py path/to/audio.wav \
  --server https://your-render-service.onrender.com \
  --device-id simulated-xiao \
  --token same-secret-as-render
```

Expected:

1. The upload returns a recording ID.
2. Vercel frontend shows the new recording.
3. Status eventually becomes `Complete`.

## Important Limitations

- CPU Whisper is slow. Use short audio files and `tiny.en` for MVP testing.
- The current backend uses FastAPI background tasks, not a separate queue worker. This is acceptable for simple MVP testing but not the final production architecture.
- SQLite on a persistent disk is okay for one backend instance. Do not scale this service horizontally while using SQLite and a single disk.
- A wearable cannot upload without internet. If it does not know local Wi-Fi credentials, use a phone hotspot, Wi-Fi provisioning flow, phone bridge, or cellular hardware in the future.
