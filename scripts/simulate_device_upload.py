#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload a local audio file through the same raw endpoint used by the wearable firmware."
    )
    parser.add_argument("audio_file", type=Path, help="Path to a WAV, MP3, M4A, AAC, FLAC, or OGG file.")
    parser.add_argument("--server", default="http://127.0.0.1:8000", help="FastAPI base URL.")
    parser.add_argument("--device-id", default="simulated-xiao", help="Device ID header.")
    parser.add_argument("--token", default="dev-device-token", help="Device upload token.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    audio_file = args.audio_file.expanduser().resolve()
    if not audio_file.exists():
        print(f"File not found: {audio_file}", file=sys.stderr)
        return 1

    filename = urllib.parse.quote(audio_file.name)
    url = f"{args.server.rstrip('/')}/api/device/recordings/raw?filename={filename}"
    content_type = mimetypes.guess_type(audio_file.name)[0] or "application/octet-stream"

    request = urllib.request.Request(
        url,
        data=audio_file.read_bytes(),
        method="POST",
        headers={
            "Content-Type": content_type,
            "X-Device-Id": args.device_id,
            "X-Device-Token": args.token,
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8"), file=sys.stderr)
        return 1

    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
