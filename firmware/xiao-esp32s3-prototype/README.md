This is the code that will be uploaded onto the XIAO ESP32S3 board for our MVP.

## Wi-Fi Upload Configuration

Before flashing, copy the example config and edit the local copy:

macOS/Linux:

```bash
cp firmware_config.example.h firmware_config.h
```

Windows PowerShell:

```powershell
Copy-Item firmware_config.example.h firmware_config.h
```

Then set these values in `firmware_config.h`:

```cpp
const char *WIFI_SSID = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";
const char *SERVER_BASE_URL = "http://192.168.1.42:8000";
const char *DEVICE_ID = "xiao-esp32s3-prototype-001";
const char *DEVICE_UPLOAD_TOKEN = "dev-device-token";
```

Use the laptop/server LAN IP for same-Wi-Fi testing. Do not use `127.0.0.1` on the board because that points back to the board itself.

The firmware:

1. Records 16 kHz mono WAV files to `/Audio`.
2. Connects to Wi-Fi after startup and after each recording.
3. Uploads pending `.wav` files to `/api/device/recordings/raw`.
4. Writes a `.uploaded` marker next to successfully uploaded files.

Watch the Serial Monitor at `115200` baud. Useful messages include the device IP, upload URL, HTTP status code, and backend JSON response.

## Build With PlatformIO

From the repository root:

```bash
npm run build:firmware
```

The repository includes `platformio.ini` with the `seeed_xiao_esp32s3` board target. The sketch currently uses `ESP_I2S.h`, so use an ESP32 Arduino core/toolchain version that supports the Arduino 3.x I2S API.
The checked-in PlatformIO config uses the pioarduino stable ESP32 platform because the default PlatformIO ESP32 platform may still install an Arduino 2.x core without `ESP_I2S.h`.

If PlatformIO is not installed in the local Python environment yet:

macOS/Linux:

```bash
.venv/bin/python -m pip install platformio
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe -m pip install platformio
```
