# XIAO Remote Upload Test Guide

This guide explains how to test the XIAO ESP32S3 Sense wearable with the deployed web platform.

You do **not** need access to the Vercel account or Render account. The deployed frontend and backend should already be running.

Your job is to:

1. Configure the XIAO firmware with Wi-Fi and server settings.
2. Flash the firmware onto the XIAO.
3. Record a short clip.
4. Confirm the clip uploads to the deployed server.
5. Confirm the uploaded clip appears and analyzes on the web app.

## Deployed Platform Values

Use these exact platform URLs:

```text
Vercel frontend URL:
  https://wearable-eta.vercel.app/

Render backend URL:
  https://wearable-fgvq.onrender.com/

Device upload token:
  loooongrandomsecrettt
```

What each URL is for:

```text
https://wearable-eta.vercel.app/
  Open this in a browser to see uploaded recordings and results.

https://wearable-fgvq.onrender.com/
  The XIAO uploads recordings here. You usually do not need to open this directly.
```

The only values you need to provide yourself are:

```text
Wi-Fi SSID:
  The name of the Wi-Fi network or phone hotspot.

Wi-Fi password:
  The password for that Wi-Fi network or phone hotspot.
```

## Important Concept

The XIAO does not upload to the Vercel website.

The workflow is:

```text
XIAO records WAV to microSD
        |
        v
XIAO uploads WAV to Render backend
        |
        v
Render backend analyzes the audio
        |
        v
Vercel frontend displays the uploaded recording and metrics
```

So:

- Humans use the Vercel URL.
- The XIAO uses the Render backend URL.
- Both are needed.

## What You Need

Hardware:

- XIAO ESP32S3 Sense
- microSD card inserted in the XIAO setup
- USB cable that supports data, not just charging
- Button and LED hardware already wired as expected by the firmware

Software:

- This codebase
- Node/npm
- Python 3.11 or 3.12
- PlatformIO
- Serial Monitor, either through PlatformIO, Arduino IDE, or another serial tool

Network:

- A simple home Wi-Fi network or phone hotspot
- Avoid public Wi-Fi with login pages, such as school, airport, hotel, or coffee shop Wi-Fi

The XIAO needs a normal Wi-Fi name and password. It usually cannot handle Wi-Fi networks that require clicking through a web login page.

## Step 1: Open the Web App

Open this in your browser:

```text
https://wearable-eta.vercel.app/
```

You should see the conversation analyzer web app.

At this point, it may show existing recordings or no recordings. That is fine.

Leave this page open. After the XIAO uploads a recording, this is where the recording should appear.

## Step 2: Confirm the Backend Is Online

Open this in a browser:

```text
https://wearable-fgvq.onrender.com/api/health
```

Expected response:

```json
{"status":"ok"}
```

If you see this, the backend server is online.

If you do not see this, stop here and tell Dylan that the backend health check is not working.

## Step 3: Create the Firmware Config File

In the codebase, go to:

```text
firmware/xiao-esp32s3-prototype/
```

There is an example config file:

```text
firmware_config.example.h
```

Create a real local config file named:

```text
firmware_config.h
```

macOS/Linux terminal:

```bash
cp firmware_config.example.h firmware_config.h
```

Windows PowerShell:

```powershell
Copy-Item firmware_config.example.h firmware_config.h
```

Do not edit `firmware_config.example.h`. Edit `firmware_config.h`.

## Step 4: Edit `firmware_config.h`

Open:

```text
firmware/xiao-esp32s3-prototype/firmware_config.h
```

Set it like this, replacing only the Wi-Fi name and password:

```cpp
#pragma once

const char *WIFI_SSID = "YOUR_WIFI_NAME_HERE";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD_HERE";

const char *SERVER_BASE_URL = "https://wearable-fgvq.onrender.com";

const char *DEVICE_ID = "xiao-esp32s3-prototype-001";
const char *DEVICE_UPLOAD_TOKEN = "loooongrandomsecrettt";
```

Example using a phone hotspot:

```cpp
const char *WIFI_SSID = "Dylan iPhone";
const char *WIFI_PASSWORD = "examplepassword123";
```

Important:

- Do not add a slash at the end of `SERVER_BASE_URL`.
- Correct:

  ```cpp
  const char *SERVER_BASE_URL = "https://wearable-fgvq.onrender.com";
  ```

- Incorrect:

  ```cpp
  const char *SERVER_BASE_URL = "https://wearable-fgvq.onrender.com/";
  ```

## Step 5: Install PlatformIO If Needed

From the repository root, try:

```bash
npm run build:firmware
```

If this works, continue to Step 6.

If it says PlatformIO is missing, install it.

macOS/Linux:

```bash
.venv/bin/python -m pip install platformio
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe -m pip install platformio
```

Then try again:

```bash
npm run build:firmware
```

Expected successful output includes:

```text
Processing xiao_esp32s3
...
Dependency Graph
|-- ESP_I2S
|-- HTTPClient
|-- WiFi
|-- NetworkClientSecure
...
[SUCCESS]
```

If firmware compilation fails, send Dylan the full terminal output.

## Step 6: Flash the XIAO

Connect the XIAO to your computer with a USB data cable.

From the repository root, run:

macOS/Linux:

```bash
PLATFORMIO_CORE_DIR=.platformio .venv/bin/pio run -e xiao_esp32s3 -t upload
```

Windows PowerShell:

```powershell
$env:PLATFORMIO_CORE_DIR = ".platformio"
.\.venv\Scripts\pio.exe run -e xiao_esp32s3 -t upload
```

Expected result:

```text
Uploading...
...
SUCCESS
```

If the computer cannot find the board:

- Make sure the USB cable supports data.
- Try another USB port.
- Press the reset/boot button if needed for flashing.
- Make sure the board appears as a serial device.

## Step 7: Open Serial Monitor

Open Serial Monitor at:

```text
115200 baud
```

With PlatformIO:

macOS/Linux:

```bash
PLATFORMIO_CORE_DIR=.platformio .venv/bin/pio device monitor -b 115200
```

Windows PowerShell:

```powershell
$env:PLATFORMIO_CORE_DIR = ".platformio"
.\.venv\Scripts\pio.exe device monitor -b 115200
```

After resetting the board, you should see startup logs.

Expected logs:

```text
XIAO ESP32S3 Sense Audio Recorder Starting...
I2S microphone OK.
MicroSD Card Type: SDHC
Connecting to Wi-Fi SSID: ...
Wi-Fi connected. Device IP: ...
Ready.
Press and hold the button on D0 to record.
```

If Wi-Fi fails, you may see:

```text
Wi-Fi connection failed. Upload will be retried later.
```

If that happens, check:

- Wi-Fi name spelling
- Wi-Fi password
- Whether the Wi-Fi network is 2.4 GHz compatible
- Whether the Wi-Fi uses a captive portal/login page
- Try a phone hotspot

## Step 8: Record a Short Test Clip

For the first test, keep it very short:

```text
5 to 10 seconds
```

Hold the record button.

Expected logs:

```text
Recording started...
Saving to: /Audio/audio0001.wav
Release button to stop recording.
```

Speak a short sentence, for example:

```text
This is a short XIAO upload test.
```

Release the button.

Expected logs:

```text
Recording stopped.
Audio data written: ...
WAV header updated.
File closed safely.
```

Immediately after that, the firmware should try to upload.

Expected upload logs:

```text
Uploading /Audio/audio0001.wav (...) to https://wearable-fgvq.onrender.com/api/device/recordings/raw?filename=audio0001.wav
Upload response status: 200
{...backend response...}
Upload complete. Marker written: /Audio/audio0001.wav.uploaded
Ready for next recording.
```

The most important line is:

```text
Upload response status: 200
```

That means the XIAO successfully sent the recording to the deployed backend.

## Step 9: Check the Web App

Go back to:

```text
https://wearable-eta.vercel.app/
```

Within a few seconds, the recording should appear in the sidebar.

It may show:

```text
Uploaded
```

or:

```text
Processing
```

Wait for it to become:

```text
Complete
```

Then the metrics should appear.

Current deployed backend notes:

- Diarization is disabled on the low-memory hosted backend.
- Speaker labels may show mostly `Speaker 1`.
- This is expected.
- The purpose of this test is remote recording, upload, processing, and display.

## Step 10: Understand Upload Retry Behavior

After a successful upload, the firmware creates a marker file:

```text
/Audio/audio0001.wav.uploaded
```

This tells the firmware:

```text
Do not upload audio0001.wav again.
```

If upload fails, the `.uploaded` marker is not created.

That means the board will try again later:

- after reboot
- after another recording
- when Wi-Fi becomes available again

If you want to force a file to upload again, remove the `.uploaded` marker from the SD card.

## Common Problems

### Problem: Backend Health Check Does Not Work

Open:

```text
https://wearable-fgvq.onrender.com/api/health
```

Expected:

```json
{"status":"ok"}
```

If it does not show this, tell Dylan:

```text
Backend health check failed.
```

### Problem: Upload Status Is 401

Serial Monitor:

```text
Upload response status: 401
```

Meaning:

```text
The device upload token is wrong.
```

Check `firmware_config.h`:

```cpp
const char *DEVICE_UPLOAD_TOKEN = "loooongrandomsecrettt";
```

Then reflash the board.

### Problem: Upload Status Is 404

Meaning:

```text
The server URL is probably wrong.
```

Check `firmware_config.h`:

```cpp
const char *SERVER_BASE_URL = "https://wearable-fgvq.onrender.com";
```

Do not use the Vercel URL for `SERVER_BASE_URL`.

### Problem: Upload Status Is 500

Meaning:

```text
The backend received the request but crashed or failed while handling it.
```

Send Dylan:

- Serial Monitor logs
- exact status code
- time of the test
- approximate recording length

### Problem: Web App Does Not Show the Recording

First check Serial Monitor.

If Serial Monitor did not show:

```text
Upload response status: 200
```

then the file did not successfully upload.

If Serial Monitor did show `200`, try:

- refresh the Vercel page
- wait 30 seconds
- check if the recording appears in the sidebar

If it still does not appear, send Dylan:

- Serial Monitor logs
- screenshot of the web app
- time of upload

### Problem: Recording Stays Processing for a Long Time

This can happen because the deployed backend is small and CPU-based.

For the first test:

```text
Use a 5 to 10 second clip.
```

Longer recordings can take several minutes.

### Problem: Wi-Fi Does Not Connect

Try a phone hotspot.

Avoid:

- school Wi-Fi
- hotel Wi-Fi
- airport Wi-Fi
- coffee shop Wi-Fi
- any Wi-Fi that requires a browser login page

The XIAO needs a normal SSID and password.

## What to Send Back After Testing

If anything fails, send Dylan:

1. Full Serial Monitor logs from startup through upload attempt.
2. The upload status code, if any.
3. Whether this URL works in a browser:

   ```text
   https://wearable-fgvq.onrender.com/api/health
   ```

4. Whether the Vercel web app opened:

   ```text
   https://wearable-eta.vercel.app/
   ```

5. Approximate recording length.
6. Whether you used home Wi-Fi or a phone hotspot.
7. Screenshot of the Vercel page if the recording does not appear.

## Successful Test Checklist

The test is successful if all of these happen:

```text
XIAO boots successfully
XIAO connects to Wi-Fi
XIAO records WAV to SD
XIAO uploads to https://wearable-fgvq.onrender.com
Serial Monitor shows Upload response status: 200
Vercel page shows the new recording
Recording changes to Complete
Metrics appear
```

