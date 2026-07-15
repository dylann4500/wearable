from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path
from typing import Any

from app.recordings import connect, get_recording, init_db, utc_now


VALID_SCOPES = {"conversation", "segment", "turn_pair", "turn"}


def init_label_db() -> None:
    init_db()
    with connect() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS labels (
                id TEXT PRIMARY KEY,
                recording_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                target TEXT NOT NULL,
                value TEXT NOT NULL,
                start_seconds REAL,
                end_seconds REAL,
                source TEXT NOT NULL,
                confidence REAL,
                rationale TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )


def create_label(recording_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    init_label_db()
    get_recording(recording_id, include_result=False)
    scope = str(payload.get("scope") or "conversation")
    if scope not in VALID_SCOPES:
        raise ValueError(f"Invalid label scope. Expected one of: {', '.join(sorted(VALID_SCOPES))}.")
    target = str(payload.get("target") or "").strip()
    if not target:
        raise ValueError("Label target is required.")
    if "value" not in payload:
        raise ValueError("Label value is required.")

    label_id = str(uuid.uuid4())
    now = utc_now()
    with connect() as connection:
        connection.execute(
            """
            INSERT INTO labels (
                id, recording_id, scope, target, value, start_seconds, end_seconds,
                source, confidence, rationale, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                label_id,
                recording_id,
                scope,
                target,
                json.dumps(payload["value"]),
                optional_float(payload.get("start_seconds")),
                optional_float(payload.get("end_seconds")),
                str(payload.get("source") or "human"),
                optional_float(payload.get("confidence")),
                payload.get("rationale"),
                now,
                now,
            ),
        )
    return get_label(label_id)


def list_labels(recording_id: str | None = None) -> list[dict[str, Any]]:
    init_label_db()
    with connect() as connection:
        if recording_id:
            rows = connection.execute(
                "SELECT * FROM labels WHERE recording_id = ? ORDER BY created_at DESC",
                (recording_id,),
            ).fetchall()
        else:
            rows = connection.execute("SELECT * FROM labels ORDER BY created_at DESC").fetchall()
    return [row_to_label(row) for row in rows]


def get_label(label_id: str) -> dict[str, Any]:
    init_label_db()
    with connect() as connection:
        row = connection.execute("SELECT * FROM labels WHERE id = ?", (label_id,)).fetchone()
    if row is None:
        raise KeyError(label_id)
    return row_to_label(row)


def export_training_rows() -> list[dict[str, Any]]:
    init_label_db()
    labels_by_recording: dict[str, list[dict[str, Any]]] = {}
    for label in list_labels():
        labels_by_recording.setdefault(label["recording_id"], []).append(label)

    rows = []
    for recording_id, labels in labels_by_recording.items():
        try:
            recording = get_recording(recording_id)
        except KeyError:
            continue
        result = recording.get("result") or {}
        features = ((result.get("insights") or {}).get("raw_feature_snapshot")) or {}
        rows.append(
            {
                "recording_id": recording_id,
                "source": recording.get("source"),
                "device_id": recording.get("device_id"),
                "features": features,
                "deterministic_scores": (result.get("insights") or {}).get("scores") or {},
                "interpretation_context": ((result.get("interpretation") or {}).get("context") or {}),
                "labels": labels,
            }
        )
    return rows


def write_training_jsonl(path: Path) -> Path:
    rows = export_training_rows()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + ("\n" if rows else ""), encoding="utf-8")
    return path


def row_to_label(row: sqlite3.Row) -> dict[str, Any]:
    data = dict(row)
    data["value"] = json.loads(data["value"])
    return data


def optional_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)

