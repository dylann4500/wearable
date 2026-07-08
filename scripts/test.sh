#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/wearable-pycache}"

.venv/bin/python -m py_compile \
  app/main.py \
  app/analyzer.py \
  app/insights.py \
  app/labels.py \
  app/llm_interpreter.py \
  app/recordings.py \
  scripts/survey_insight_models.py \
  scripts/simulate_device_upload.py \
  tests/test_recordings_api.py \
  tests/test_insights.py

.venv/bin/python -m unittest discover -s tests

npm --prefix frontend run build
