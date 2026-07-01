# Conversation Analytics MVP

Local web app for uploading an MP3 conversation and extracting practical speech and conversation metrics.

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

```bash
brew install ffmpeg
```

The setup expects Python 3.11 or 3.12 because audio/scientific packages may not have stable wheels for newer Python releases yet. If needed:

```bash
brew install python@3.12
```

Run the app:

```bash
./scripts/run.sh
```

Open:

```text
http://127.0.0.1:8000
```

The first run downloads a Whisper model. By default it uses `base.en`, which is a good balance for local testing. You can override it:

```bash
WHISPER_MODEL=tiny.en ./scripts/run.sh
WHISPER_MODEL=small.en ./scripts/run.sh
```

## Speaker Diarization

The app has two diarization paths:

1. **Preferred:** pyannote.audio speaker timeline diarization. This is more accurate because it first asks "who spoke when?" and then assigns Whisper words to that speaker timeline.
2. **Fallback:** local `resemblyzer` embeddings clustered by transcript turns, with smoothing for isolated speaker flips.

Install the optional diarization dependencies:

```bash
./scripts/install_diarization.sh
```

To enable the stronger pyannote path:

1. Create a Hugging Face account.
2. Accept the terms for `pyannote/speaker-diarization-3.1`.
3. Create a read token.
4. Run with:

```bash
HF_TOKEN=your_token_here ./scripts/run.sh
```

Without `HF_TOKEN`, the app still runs and uses the local embedding fallback. Without optional diarization dependencies, it labels all turns as `Speaker 1`.

## Frontend

The UI is a React/Vite app in `frontend/`. `./scripts/run.sh` installs and builds it automatically when `npm` is available, then FastAPI serves the built app at `http://127.0.0.1:8000`.

## Notes

- `Speaker 1` is treated as the user for user-specific summaries.
- Interjections are estimated from very short-latency speaker changes and short acknowledgments. True overlap detection still needs a dedicated overlap-aware diarization model.
- Audio files are saved under `uploads/`, which is git-ignored.
