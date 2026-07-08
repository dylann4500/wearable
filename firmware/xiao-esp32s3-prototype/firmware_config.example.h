#pragma once

// Copy this file to firmware_config.h before flashing the board.
// firmware_config.h is ignored by git so local Wi-Fi credentials are not committed.

const char *WIFI_SSID = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

// For laptop-on-same-Wi-Fi testing, use the laptop LAN URL, for example:
// "http://192.168.1.42:8000". Do not use 127.0.0.1 on the board.
const char *SERVER_BASE_URL = "http://192.168.1.42:8000";

const char *DEVICE_ID = "xiao-esp32s3-prototype-001";

// Must match DEVICE_UPLOAD_TOKEN on the FastAPI server.
const char *DEVICE_UPLOAD_TOKEN = "dev-device-token";

// Keep this false when testing the BLE phone-sync pipeline.
// Set true only when you want the prototype to upload directly over known Wi-Fi.
const bool ENABLE_WIFI_UPLOAD = false;
