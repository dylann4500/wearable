from __future__ import annotations

import shutil
import uuid
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.analyzer import UPLOAD_DIR, analyze_audio


app = FastAPI(title="Conversation Analytics MVP")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
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
