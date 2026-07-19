#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

pick_python() {
  for candidate in \
    python3.12 \
    python3.11 \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    /usr/local/opt/python@3.12/bin/python3.12 \
    /usr/local/opt/python@3.11/bin/python3.11; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  echo "Could not find Python 3.11 or 3.12. Install one with: brew install python@3.12" >&2
  return 1
}

PYTHON_BIN="$(pick_python)"

if [ ! -d .venv ]; then
  "$PYTHON_BIN" -m venv .venv
elif ! .venv/bin/python - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info[:2] in {(3, 11), (3, 12)} else 1)
PY
then
  echo "Recreating .venv with a supported Python for audio packages."
  rm -rf .venv
  "$PYTHON_BIN" -m venv .venv
fi

source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
if [ -n "${HF_TOKEN:-}" ] || [ -n "${HUGGINGFACE_TOKEN:-}" ] || [ "${INSTALL_DIARIZATION:-0}" = "1" ]; then
  python -m pip install -r requirements-diarization.txt
  python -m pip install 'setuptools<81'
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Warning: ffmpeg is required for uploads. Install it with: brew install ffmpeg"
fi

if command -v npm >/dev/null 2>&1; then
  if [ ! -d frontend/node_modules ]; then
    npm --prefix frontend install
  fi
  npm --prefix frontend run build
else
  echo "Warning: npm is not installed. Serving the legacy static UI instead of the React build."
fi

export PYTHONPATH="$PWD"
uvicorn app.main:app \
  --host "${HOST:-127.0.0.1}" \
  --port "${PORT:-8000}" \
  --reload \
  --reload-exclude ".venv/*" \
  --reload-exclude "frontend/node_modules/*" \
  --reload-dir app \
  --reload-dir frontend/src
