from __future__ import annotations

import json
import os
import shutil
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO

from app.analyzer import UPLOAD_DIR, analyze_audio


DB_PATH = Path(os.getenv("RECORDINGS_DB", "recordings.sqlite3"))
RESULT_DIR = Path(os.getenv("RESULT_DIR", "recording_results"))
SUPPORTED_AUDIO_SUFFIXES = {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"}

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
RESULT_DIR.mkdir(parents=True, exist_ok=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def connect() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    return connection


def init_db() -> None:
    with connect() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS recordings (
                id TEXT PRIMARY KEY,
                device_id TEXT,
                original_filename TEXT NOT NULL,
                storage_path TEXT NOT NULL,
                status TEXT NOT NULL,
                source TEXT NOT NULL,
                error TEXT,
                result_path TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                completed_at TEXT
            )
            """
        )


def validate_audio_filename(filename: str) -> str:
    suffix = Path(filename).suffix.lower() or ".wav"
    if suffix not in SUPPORTED_AUDIO_SUFFIXES:
        allowed = ", ".join(sorted(SUPPORTED_AUDIO_SUFFIXES))
        raise ValueError(f"Unsupported audio file type. Expected one of: {allowed}.")
    return suffix


def create_recording(
    *,
    filename: str,
    source: str,
    fileobj: BinaryIO,
    device_id: str | None = None,
) -> dict[str, Any]:
    init_db()
    suffix = validate_audio_filename(filename)
    recording_id = str(uuid.uuid4())
    upload_path = UPLOAD_DIR / f"{recording_id}{suffix}"

    with upload_path.open("wb") as handle:
        shutil.copyfileobj(fileobj, handle)

    now = utc_now()
    with connect() as connection:
        connection.execute(
            """
            INSERT INTO recordings (
                id, device_id, original_filename, storage_path, status, source,
                created_at, updated_at
            )
            VALUES (?, ?, ?, ?, 'uploaded', ?, ?, ?)
            """,
            (recording_id, device_id, filename, str(upload_path), source, now, now),
        )

    return get_recording(recording_id, include_result=False)


def list_recordings() -> list[dict[str, Any]]:
    init_db()
    with connect() as connection:
        rows = connection.execute(
            """
            SELECT * FROM recordings
            ORDER BY created_at DESC
            """
        ).fetchall()
    return [row_to_dict(row, include_result=False) for row in rows]


def get_recording(recording_id: str, *, include_result: bool = True) -> dict[str, Any]:
    init_db()
    with connect() as connection:
        row = connection.execute(
            "SELECT * FROM recordings WHERE id = ?",
            (recording_id,),
        ).fetchone()
    if row is None:
        raise KeyError(recording_id)
    return row_to_dict(row, include_result=include_result)


def mark_processing(recording_id: str) -> None:
    update_recording(recording_id, status="processing", error=None)


def mark_complete(recording_id: str, result: dict[str, Any]) -> None:
    result_path = RESULT_DIR / f"{recording_id}.json"
    result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    now = utc_now()
    with connect() as connection:
        connection.execute(
            """
            UPDATE recordings
            SET status = 'complete',
                result_path = ?,
                error = NULL,
                updated_at = ?,
                completed_at = ?
            WHERE id = ?
            """,
            (str(result_path), now, now, recording_id),
        )


def mark_failed(recording_id: str, error: str) -> None:
    update_recording(recording_id, status="failed", error=error[:2000])


def update_recording(recording_id: str, **fields: Any) -> None:
    if not fields:
        return
    fields["updated_at"] = utc_now()
    assignments = ", ".join(f"{name} = ?" for name in fields)
    values = list(fields.values())
    values.append(recording_id)
    with connect() as connection:
        connection.execute(
            f"UPDATE recordings SET {assignments} WHERE id = ?",
            values,
        )


def analyze_recording(recording_id: str) -> None:
    try:
        recording = get_recording(recording_id, include_result=False)
        if recording["status"] == "processing":
            return
        mark_processing(recording_id)
        result = analyze_audio(Path(recording["storage_path"]), recording["original_filename"])
        mark_complete(recording_id, result)
    except Exception as exc:
        mark_failed(recording_id, str(exc))


def row_to_dict(row: sqlite3.Row, *, include_result: bool) -> dict[str, Any]:
    data = dict(row)
    data["result"] = None
    if include_result and data.get("result_path"):
        result_path = Path(data["result_path"])
        if result_path.exists():
            data["result"] = json.loads(result_path.read_text(encoding="utf-8"))
    return data
