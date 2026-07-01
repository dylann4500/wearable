from __future__ import annotations

import io
import os
import tempfile
import unittest
import wave
from pathlib import Path

from fastapi.testclient import TestClient

import app.recordings as recordings
from app.main import app

ROOT = Path(__file__).resolve().parents[1]


def tiny_wav_bytes() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 1600)
    return buffer.getvalue()


class RecordingApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        recordings.DB_PATH = root / "recordings.sqlite3"
        recordings.RESULT_DIR = root / "recording_results"
        recordings.UPLOAD_DIR = root / "uploads"
        recordings.RESULT_DIR.mkdir()
        recordings.UPLOAD_DIR.mkdir()
        recordings.init_db()
        os.environ["DEVICE_UPLOAD_TOKEN"] = "test-token"

        self.original_analyze_audio = recordings.analyze_audio
        recordings.analyze_audio = lambda path, name: {
            "metadata": {
                "file_name": name,
                "duration_seconds": 0.1,
                "diarization": {"enabled": False, "status": "mocked"},
            },
            "summary": {"duration_seconds": 0.1, "speaker_count": 1},
            "speakers": {},
            "turn_taking": {},
            "language": {},
            "silence_and_pauses": {},
            "audio_quality": {},
            "sentiment": {},
            "interjections": {"events": [], "estimated_count": 0},
            "transcript": [],
        }
        self.client = TestClient(app)

    def tearDown(self) -> None:
        recordings.analyze_audio = self.original_analyze_audio
        os.environ.pop("DEVICE_UPLOAD_TOKEN", None)
        self.temp_dir.cleanup()

    def test_device_raw_upload_requires_valid_token(self) -> None:
        response = self.client.post(
            "/api/device/recordings/raw?filename=audio0001.wav",
            content=tiny_wav_bytes(),
            headers={
                "X-Device-Id": "test-device",
                "X-Device-Token": "wrong-token",
                "Content-Type": "application/octet-stream",
            },
        )

        self.assertEqual(response.status_code, 401)

    def test_device_raw_upload_creates_completed_job(self) -> None:
        response = self.client.post(
            "/api/device/recordings/raw?filename=audio0001.wav",
            content=tiny_wav_bytes(),
            headers={
                "X-Device-Id": "test-device",
                "X-Device-Token": "test-token",
                "Content-Type": "application/octet-stream",
            },
        )

        self.assertEqual(response.status_code, 200)
        recording_id = response.json()["id"]

        detail = self.client.get(f"/api/recordings/{recording_id}")
        payload = detail.json()

        self.assertEqual(detail.status_code, 200)
        self.assertEqual(payload["source"], "device")
        self.assertEqual(payload["device_id"], "test-device")
        self.assertEqual(payload["status"], "complete")
        self.assertEqual(payload["result"]["metadata"]["file_name"], "audio0001.wav")

    def test_browser_upload_uses_same_job_pipeline(self) -> None:
        response = self.client.post(
            "/api/recordings",
            files={"file": ("browser.wav", tiny_wav_bytes(), "audio/wav")},
        )

        self.assertEqual(response.status_code, 200)
        recording_id = response.json()["id"]
        detail = self.client.get(f"/api/recordings/{recording_id}").json()

        self.assertEqual(detail["source"], "browser")
        self.assertEqual(detail["status"], "complete")
        self.assertEqual(detail["result"]["metadata"]["file_name"], "browser.wav")


class FirmwareHandoffTest(unittest.TestCase):
    def test_sketch_config_include_has_example_template(self) -> None:
        firmware_dir = ROOT / "firmware" / "xiao-esp32s3-prototype"
        sketch = (firmware_dir / "AudioRecording.ino").read_text(encoding="utf-8")
        example = (firmware_dir / "firmware_config.example.h").read_text(encoding="utf-8")
        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        platformio = (ROOT / "platformio.ini").read_text(encoding="utf-8")
        package_json = (ROOT / "package.json").read_text(encoding="utf-8")
        run_ps1 = ROOT / "scripts" / "run.ps1"
        install_diarization_ps1 = ROOT / "scripts" / "install_diarization.ps1"
        test_js = ROOT / "scripts" / "test.js"
        build_firmware_js = ROOT / "scripts" / "build_firmware.js"

        self.assertIn('#include "firmware_config.h"', sketch)
        self.assertIn("firmware/xiao-esp32s3-prototype/firmware_config.h", gitignore)
        self.assertIn("src_dir = firmware/xiao-esp32s3-prototype", platformio)
        self.assertIn("pioarduino/platform-espressif32", platformio)
        self.assertIn("board = seeed_xiao_esp32s3", platformio)
        self.assertIn("node scripts/test.js", package_json)
        self.assertIn("node scripts/build_firmware.js", package_json)
        self.assertTrue(run_ps1.exists())
        self.assertTrue(install_diarization_ps1.exists())
        self.assertTrue(test_js.exists())
        self.assertTrue(build_firmware_js.exists())
        for name in (
            "WIFI_SSID",
            "WIFI_PASSWORD",
            "SERVER_BASE_URL",
            "DEVICE_ID",
            "DEVICE_UPLOAD_TOKEN",
        ):
            self.assertIn(name, example)


if __name__ == "__main__":
    unittest.main()
