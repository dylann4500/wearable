from __future__ import annotations

import os
import shutil
import tempfile
import uuid
from pathlib import Path

from fastapi import BackgroundTasks, File, Header, HTTPException, Query, Request, UploadFile
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles

from app.analyzer import UPLOAD_DIR, analyze_audio
from app.labels import create_label, export_training_rows, init_label_db, list_labels
from app.llm_interpreter import apply_contextualization, interpret_conversation
from app.recordings import (
    analyze_recording,
    create_recording,
    get_recording,
    init_db,
    list_recordings,
    save_recording_result,
)


app = FastAPI(title="Conversation Analytics MVP")
init_db()
init_label_db()

cors_origins = [
    origin.strip()
    for origin in os.getenv("CORS_ALLOW_ORIGINS", os.getenv("FRONTEND_URL", "*")).split(",")
    if origin.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

LEGACY_STATIC_DIR = Path(__file__).parent / "static"
FRONTEND_DIST = Path(__file__).resolve().parent.parent / "frontend" / "dist"

if FRONTEND_DIST.exists():
    app.mount("/assets", StaticFiles(directory=FRONTEND_DIST / "assets"), name="assets")
else:
    app.mount("/static", StaticFiles(directory=LEGACY_STATIC_DIR), name="static")


@app.get("/")
def index() -> FileResponse:
    if FRONTEND_DIST.exists():
        return FileResponse(FRONTEND_DIST / "index.html")
    return FileResponse(LEGACY_STATIC_DIR / "index.html")


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/recordings")
def recordings() -> list[dict]:
    return list_recordings()


@app.get("/api/recordings/{recording_id}")
def recording(recording_id: str) -> dict:
    try:
        return get_recording(recording_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Recording not found.") from exc


@app.post("/api/recordings")
async def upload_recording(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
) -> dict:
    if not file.filename:
        raise HTTPException(status_code=400, detail="Upload a file with a filename.")

    try:
        recording = create_recording(
            filename=file.filename,
            source="browser",
            fileobj=file.file,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Upload failed: {exc}") from exc

    background_tasks.add_task(analyze_recording, recording["id"])
    return recording


@app.post("/api/device/recordings")
async def upload_device_recording(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    x_device_id: str | None = Header(default=None),
    x_device_token: str | None = Header(default=None),
) -> dict:
    expected_token = os.getenv("DEVICE_UPLOAD_TOKEN", "dev-device-token")
    if x_device_token != expected_token:
        raise HTTPException(status_code=401, detail="Invalid device token.")
    if not x_device_id:
        raise HTTPException(status_code=400, detail="Missing X-Device-Id header.")
    if not file.filename:
        raise HTTPException(status_code=400, detail="Upload a file with a filename.")

    try:
        recording = create_recording(
            filename=file.filename,
            source="device",
            device_id=x_device_id,
            fileobj=file.file,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Device upload failed: {exc}") from exc

    background_tasks.add_task(analyze_recording, recording["id"])
    return recording


@app.post("/api/device/recordings/raw")
async def upload_raw_device_recording(
    request: Request,
    background_tasks: BackgroundTasks,
    filename: str = Query(...),
    x_device_id: str | None = Header(default=None),
    x_device_token: str | None = Header(default=None),
) -> dict:
    expected_token = os.getenv("DEVICE_UPLOAD_TOKEN", "dev-device-token")
    if x_device_token != expected_token:
        raise HTTPException(status_code=401, detail="Invalid device token.")
    if not x_device_id:
        raise HTTPException(status_code=400, detail="Missing X-Device-Id header.")

    try:
        with tempfile.NamedTemporaryFile() as temp_file:
            async for chunk in request.stream():
                temp_file.write(chunk)
            temp_file.flush()
            temp_file.seek(0)
            recording = create_recording(
                filename=filename,
                source="device",
                device_id=x_device_id,
                fileobj=temp_file,
            )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Device upload failed: {exc}") from exc

    background_tasks.add_task(analyze_recording, recording["id"])
    return recording


@app.post("/api/recordings/{recording_id}/analyze")
def analyze_existing_recording(recording_id: str, background_tasks: BackgroundTasks) -> dict:
    try:
        recording = get_recording(recording_id, include_result=False)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Recording not found.") from exc

    if recording["status"] == "processing":
        return recording

    background_tasks.add_task(analyze_recording, recording_id)
    return recording


@app.post("/api/recordings/{recording_id}/interpret")
def interpret_recording(recording_id: str) -> dict:
    try:
        recording = get_recording(recording_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Recording not found.") from exc

    if recording["status"] != "complete" or not recording.get("result"):
        raise HTTPException(status_code=409, detail="Recording must be complete before interpretation.")

    try:
        result = dict(recording["result"])
        interpretation = interpret_conversation(result)
        result["interpretation"] = interpretation
        result = apply_contextualization(result, interpretation)
        save_recording_result(recording_id, result)
        return get_recording(recording_id)
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Interpretation failed: {exc}") from exc


@app.get("/api/recordings/{recording_id}/labels")
def recording_labels(recording_id: str) -> list[dict]:
    try:
        get_recording(recording_id, include_result=False)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Recording not found.") from exc
    return list_labels(recording_id)


@app.post("/api/recordings/{recording_id}/labels")
def add_recording_label(recording_id: str, payload: dict) -> dict:
    try:
        return create_label(recording_id, payload)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Recording not found.") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/training/labels")
def training_labels() -> list[dict]:
    return export_training_rows()


@app.get("/api/training/labels.jsonl")
def training_labels_jsonl() -> PlainTextResponse:
    lines = [json_line(row) for row in export_training_rows()]
    return PlainTextResponse("\n".join(lines) + ("\n" if lines else ""), media_type="application/x-ndjson")


@app.post("/api/analyze")
async def analyze(file: UploadFile = File(...)) -> dict:
    if not file.filename:
        raise HTTPException(status_code=400, detail="Upload a file with a filename.")

    suffix = Path(file.filename).suffix.lower() or ".mp3"
    if suffix not in {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"}:
        raise HTTPException(status_code=400, detail="Upload an audio file: MP3, WAV, M4A, AAC, FLAC, or OGG.")

    upload_path = UPLOAD_DIR / f"{uuid.uuid4()}{suffix}"
    try:
        with upload_path.open("wb") as handle:
            shutil.copyfileobj(file.file, handle)
        return analyze_audio(upload_path, file.filename)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {exc}") from exc


def json_line(value: dict) -> str:
    import json

    return json.dumps(value, ensure_ascii=False)
