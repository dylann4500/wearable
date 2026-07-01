#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG_PATH="firmware/xiao-esp32s3-prototype/firmware_config.h"
EXAMPLE_PATH="firmware/xiao-esp32s3-prototype/firmware_config.example.h"

if [ ! -f "$CONFIG_PATH" ]; then
  cp "$EXAMPLE_PATH" "$CONFIG_PATH"
  echo "Created $CONFIG_PATH from the example template."
  echo "Edit it with real Wi-Fi/server values before flashing to hardware."
fi

export PLATFORMIO_CORE_DIR="${PLATFORMIO_CORE_DIR:-.platformio}"

if [ -x ".venv/bin/pio" ]; then
  .venv/bin/pio run -e xiao_esp32s3
elif command -v pio >/dev/null 2>&1; then
  pio run -e xiao_esp32s3
else
  echo "PlatformIO is not installed." >&2
  echo "Install it with: .venv/bin/python -m pip install platformio" >&2
  exit 1
fi
