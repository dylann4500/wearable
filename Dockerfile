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
    && apt-get install -y --no-install-recommends build-essential ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
COPY requirements-diarization.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir -r requirements-diarization.txt

COPY app ./app

RUN mkdir -p /var/data/uploads /var/data/analysis_runs /var/data/recording_results

EXPOSE 8000

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
