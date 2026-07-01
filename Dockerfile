FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    UPLOAD_DIR=/var/data/uploads \
    RUN_DIR=/var/data/analysis_runs \
    RESULT_DIR=/var/data/recording_results \
    RECORDINGS_DB=/var/data/recordings.sqlite3 \
    WHISPER_MODEL=tiny.en \
    WHISPER_DEVICE=cpu \
    WHISPER_COMPUTE_TYPE=int8

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
COPY requirements-diarization.txt .
ARG INSTALL_DIARIZATION=false
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && if [ "$INSTALL_DIARIZATION" = "true" ]; then pip install --no-cache-dir -r requirements-diarization.txt; fi

COPY app ./app

RUN mkdir -p /var/data/uploads /var/data/analysis_runs /var/data/recording_results

CMD uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
