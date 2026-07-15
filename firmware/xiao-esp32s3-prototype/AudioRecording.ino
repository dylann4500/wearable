/*
  Wearable Device to Improve Speech Prototype
  Written By: James Wang
  ChatGPT 5.5 used for some complex aspects

  Press and hold a pushbutton on D0 to record audio.
  Release the button to stop recording.
  LED on D1 stays ON whenever powered, and flashes while recording.
  Saves WAV files to /Audio on the microSD card.
  Does not overwrite previous recordings.

  Updated for ESP32 Arduino 3.x using ESP_I2S.h
*/

#include <Arduino.h>
#include <FS.h> //file system library
#include <SD.h> //this is the SD card library
#include <SPI.h> //enables SPI communication
#include <ESP_I2S.h> //enables I2S protocol to talk to the MEMS mic
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <NimBLEDevice.h>
#include "firmware_config.h"

// -------------------- I2S object --------------------

I2SClass I2S;

// -------------------- Audio settings --------------------

#define SAMPLE_RATE 16000U
#define SAMPLE_BITS 16
#define WAV_HEADER_SIZE 44
#define VOLUME_GAIN 3

// -------------------- Pin settings --------------------

const int BUTTON_PIN = D0;
const int RECORD_LED_PIN = D1;

// XIAO ESP32S3 Sense microSD CS pin
const int SD_CS_PIN = 21;
const uint32_t SD_SPI_FREQUENCY = 1000000;

// XIAO ESP32S3 Sense onboard MEMS microphone pins
const int I2S_PDM_CLK_PIN = 42;
const int I2S_PDM_DATA_PIN = 41;

// -------------------- File settings --------------------

const char *AUDIO_DIR = "/Audio";

const unsigned long WIFI_CONNECT_TIMEOUT_MS = 15000;
// iOS commonly negotiates a 185-byte ATT MTU, leaving 182 bytes for a
// characteristic value. Reserve 6 bytes for our offset/length header.
const size_t BLE_TRANSFER_CHUNK_SIZE = 160;
const uint8_t BLE_TRANSFER_WINDOW_CHUNKS = 8;
const unsigned long BLE_TRANSFER_ACK_TIMEOUT_MS = 5000;
const uint8_t BLE_TRANSFER_WINDOW_RETRY_LIMIT = 5;

// -------------------- BLE settings --------------------

const char *BLE_DEVICE_NAME = "XIAO Speech Prototype";
const char *BLE_SERVICE_UUID = "8f2a0001-7b4f-4f9d-9d3f-2f5c0a7a9000";
const char *BLE_CONTROL_UUID = "8f2a0002-7b4f-4f9d-9d3f-2f5c0a7a9000";
const char *BLE_STATUS_UUID = "8f2a0003-7b4f-4f9d-9d3f-2f5c0a7a9000";
const char *BLE_MANIFEST_UUID = "8f2a0004-7b4f-4f9d-9d3f-2f5c0a7a9000";
const char *BLE_DATA_UUID = "8f2a0005-7b4f-4f9d-9d3f-2f5c0a7a9000";

NimBLECharacteristic *bleStatusCharacteristic = nullptr;
NimBLECharacteristic *bleManifestCharacteristic = nullptr;
NimBLECharacteristic *bleDataCharacteristic = nullptr;

// -------------------- Recording state --------------------

volatile bool isRecording = false;
volatile bool bleRecordingRequested = false;
volatile bool bleClientConnected = false;
volatile bool bleTransferInProgress = false;
volatile bool bleTransferReceiverReady = false;
volatile bool bleTransferAckReceived = false;
volatile uint32_t bleTransferAckOffset = 0;
volatile bool storageReady = false;
TaskHandle_t bleRecordTaskHandle = nullptr;
TaskHandle_t bleTransferTaskHandle = nullptr;
String bleActiveRecordingPath = "";
String bleTransferPath = "";
uint32_t bleTransferOffset = 0;

bool continueButtonRecording();
bool continueBleRecording();
void recordAudioFile(const char *audioFileName, bool (*shouldContinueRecording)());
void publishRecordingManifest();
void setupBle();

bool tryRecoverStorage() {
  SD.end();
  if (!SD.begin(SD_CS_PIN, SPI, SD_SPI_FREQUENCY) || SD.cardType() == CARD_NONE) {
    return false;
  }
  if (!makeAudioDirectoryIfNeeded()) {
    return false;
  }
  cleanupTemporaryRecordings();

  storageReady = true;
  Serial.println("MicroSD storage ready.");
  bleNotifyStatus("STORAGE_READY");
  return true;
}

// -------------------- Button helper --------------------

bool buttonPressed() {
  // INPUT_PULLUP logic:
  // Not pressed = HIGH
  // Pressed     = LOW
  return digitalRead(BUTTON_PIN) == LOW;
}

bool continueButtonRecording() {
  return buttonPressed();
}

bool continueBleRecording() {
  return bleRecordingRequested;
}

void bleNotifyStatus(String status) {
  Serial.print("BLE status: ");
  Serial.println(status);

  if (bleStatusCharacteristic != nullptr) {
    bleStatusCharacteristic->setValue(status.c_str());
    bleStatusCharacteristic->notify();
  }
}

// -------------------- LED task --------------------

void recordLedTask(void *parameter) {
  bool ledState = true;

  while (true) {
    if (isRecording) {
      ledState = !ledState;
      digitalWrite(RECORD_LED_PIN, ledState ? HIGH : LOW);
      vTaskDelay(500 / portTICK_PERIOD_MS);
    } else {
      // Device is powered and idle, so LED stays ON.
      ledState = true;
      digitalWrite(RECORD_LED_PIN, HIGH);
      vTaskDelay(50 / portTICK_PERIOD_MS);
    }
  }
}

// -------------------- WAV header helper --------------------

void generate_wav_header(uint8_t *wav_header, uint32_t wav_size, uint32_t sample_rate) {
  uint32_t file_size = wav_size + WAV_HEADER_SIZE - 8;
  uint32_t byte_rate = sample_rate * SAMPLE_BITS / 8;

  const uint8_t set_wav_header[] = {
    'R', 'I', 'F', 'F',

    (uint8_t)(file_size),
    (uint8_t)(file_size >> 8),
    (uint8_t)(file_size >> 16),
    (uint8_t)(file_size >> 24),

    'W', 'A', 'V', 'E',

    'f', 'm', 't', ' ',
    0x10, 0x00, 0x00, 0x00,

    0x01, 0x00,
    0x01, 0x00,

    (uint8_t)(sample_rate),
    (uint8_t)(sample_rate >> 8),
    (uint8_t)(sample_rate >> 16),
    (uint8_t)(sample_rate >> 24),

    (uint8_t)(byte_rate),
    (uint8_t)(byte_rate >> 8),
    (uint8_t)(byte_rate >> 16),
    (uint8_t)(byte_rate >> 24),

    0x02, 0x00,
    0x10, 0x00,

    'd', 'a', 't', 'a',

    (uint8_t)(wav_size),
    (uint8_t)(wav_size >> 8),
    (uint8_t)(wav_size >> 16),
    (uint8_t)(wav_size >> 24),
  };

  memcpy(wav_header, set_wav_header, sizeof(set_wav_header));
}

// -------------------- SD helpers --------------------

bool makeAudioDirectoryIfNeeded() {
  if (SD.exists(AUDIO_DIR)) {
    return true;
  }

  Serial.println("Creating /Audio directory...");

  if (SD.mkdir(AUDIO_DIR)) {
    Serial.println("/Audio directory created.");
    return true;
  } else {
    Serial.println("Failed to create /Audio directory!");
    return false;
  }
}

void clearAudioDirectory() {
  File dir = SD.open(AUDIO_DIR);
  if (!dir || !dir.isDirectory()) {
    Serial.println("CLEAR_RECORDINGS_FAILED:Cannot open /Audio");
    return;
  }

  int removedCount = 0;
  while (true) {
    File entry = dir.openNextFile();
    if (!entry) {
      break;
    }

    String path = normalizeAudioPath(String(entry.name()));
    bool isDirectory = entry.isDirectory();
    entry.close();

    if (!isDirectory && SD.remove(path)) {
      removedCount++;
    }
  }
  dir.close();

  publishRecordingManifest();
  Serial.printf("CLEAR_RECORDINGS_DONE:%d\n", removedCount);
}

void cleanupTemporaryRecordings() {
  File dir = SD.open(AUDIO_DIR);
  if (!dir || !dir.isDirectory()) {
    return;
  }

  while (true) {
    File entry = dir.openNextFile();
    if (!entry) {
      break;
    }

    String path = normalizeAudioPath(String(entry.name()));
    bool isDirectory = entry.isDirectory();
    entry.close();
    if (!isDirectory && hasSuffix(path, ".recording")) {
      if (SD.remove(path)) {
        Serial.printf("Removed incomplete temporary recording: %s\n", path.c_str());
      }
    }
  }
  dir.close();
}

String getNextAudioFileName() {
  int fileNumber = 1;
  char fileName[48];

  while (true) {
    sprintf(fileName, "/Audio/audio%04d.wav", fileNumber);

    if (!SD.exists(fileName)) {
      return String(fileName);
    }

    fileNumber++;
  }
}

bool hasSuffix(String value, const char *suffix) {
  return value.endsWith(suffix);
}

String baseName(String path) {
  int slashIndex = path.lastIndexOf('/');
  if (slashIndex >= 0) {
    return path.substring(slashIndex + 1);
  }
  return path;
}

String normalizeAudioPath(String path) {
  if (path.startsWith("/")) {
    return path;
  }
  return String(AUDIO_DIR) + "/" + path;
}

String uploadedMarkerName(String audioFileName) {
  return String(audioFileName) + ".uploaded";
}

String urlEncode(String value) {
  String encoded = "";
  const char *hex = "0123456789ABCDEF";

  for (size_t i = 0; i < value.length(); i++) {
    char c = value.charAt(i);
    bool safe =
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '~';

    if (safe) {
      encoded += c;
    } else {
      encoded += '%';
      encoded += hex[(c >> 4) & 0x0F];
      encoded += hex[c & 0x0F];
    }
  }

  return encoded;
}

bool connectToWiFiIfNeeded() {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }

  Serial.printf("Connecting to Wi-Fi SSID: %s\n", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long startedAt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < WIFI_CONNECT_TIMEOUT_MS) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Wi-Fi connection failed. Upload will be retried later.");
    return false;
  }

  Serial.print("Wi-Fi connected. Device IP: ");
  Serial.println(WiFi.localIP());
  return true;
}

bool uploadAudioFile(String audioFileName) {
  if (!ENABLE_WIFI_UPLOAD) {
    Serial.println("Wi-Fi upload disabled. File will remain available for BLE sync.");
    return false;
  }

  if (!connectToWiFiIfNeeded()) {
    return false;
  }

  File file = SD.open(audioFileName, FILE_READ);
  if (!file) {
    Serial.printf("Failed to open %s for upload.\n", audioFileName.c_str());
    return false;
  }

  String filename = baseName(audioFileName);
  String url = String(SERVER_BASE_URL) + "/api/device/recordings/raw?filename=" + urlEncode(filename);

  Serial.printf("Uploading %s (%u bytes) to %s\n", audioFileName.c_str(), (unsigned int)file.size(), url.c_str());

  WiFiClient client;
  WiFiClientSecure secureClient;
  HTTPClient http;
  http.setTimeout(30000);

  bool isHttps = url.startsWith("https://");
  if (isHttps) {
    // MVP/testing shortcut: skip certificate validation for hosted HTTPS APIs.
    // Production firmware should pin the server certificate or CA instead.
    secureClient.setInsecure();
  }

  bool httpStarted = isHttps ? http.begin(secureClient, url) : http.begin(client, url);
  if (!httpStarted) {
    Serial.println("HTTP begin failed.");
    file.close();
    return false;
  }

  http.addHeader("Content-Type", "application/octet-stream");
  http.addHeader("X-Device-Id", DEVICE_ID);
  http.addHeader("X-Device-Token", DEVICE_UPLOAD_TOKEN);

  int statusCode = http.sendRequest("POST", &file, file.size());
  String response = http.getString();

  http.end();
  file.close();

  Serial.printf("Upload response status: %d\n", statusCode);
  Serial.println(response);

  if (statusCode < 200 || statusCode >= 300) {
    Serial.println("Upload failed. File will be retried later.");
    return false;
  }

  String marker = uploadedMarkerName(audioFileName);
  File markerFile = SD.open(marker, FILE_WRITE);
  if (markerFile) {
    markerFile.println("uploaded");
    markerFile.close();
  }

  Serial.printf("Upload complete. Marker written: %s\n", marker.c_str());
  return true;
}

void uploadPendingAudioFiles() {
  File dir = SD.open(AUDIO_DIR);
  if (!dir || !dir.isDirectory()) {
    Serial.println("Cannot scan /Audio for pending uploads.");
    return;
  }

  while (true) {
    File entry = dir.openNextFile();
    if (!entry) {
      break;
    }

    String audioFileName = normalizeAudioPath(String(entry.name()));
    bool isDirectory = entry.isDirectory();
    entry.close();

    if (isDirectory || !hasSuffix(audioFileName, ".wav")) {
      continue;
    }

    String marker = uploadedMarkerName(audioFileName);
    if (SD.exists(marker)) {
      continue;
    }

    if (ENABLE_WIFI_UPLOAD) {
      uploadAudioFile(audioFileName);
    }
  }

  dir.close();
}

// -------------------- BLE file sync helpers --------------------

String recordingPathFromName(String filename) {
  filename.trim();
  filename.replace("/", "");
  return String(AUDIO_DIR) + "/" + filename;
}

uint32_t readUint32LE(const uint8_t *buffer) {
  return (uint32_t)buffer[0]
    | ((uint32_t)buffer[1] << 8)
    | ((uint32_t)buffer[2] << 16)
    | ((uint32_t)buffer[3] << 24);
}

bool isFinalizedWAV(String path, size_t expectedSize) {
  if (expectedSize <= WAV_HEADER_SIZE) {
    return false;
  }

  File file = SD.open(path, FILE_READ);
  if (!file) {
    return false;
  }

  uint8_t header[WAV_HEADER_SIZE];
  size_t bytesRead = file.read(header, sizeof(header));
  file.close();
  if (bytesRead != sizeof(header)
      || memcmp(header, "RIFF", 4) != 0
      || memcmp(header + 8, "WAVE", 4) != 0
      || memcmp(header + 36, "data", 4) != 0) {
    return false;
  }

  uint32_t riffSize = readUint32LE(header + 4);
  uint32_t dataSize = readUint32LE(header + 40);
  uint32_t expectedRiffSize = expectedSize - 8;
  uint32_t expectedDataSize = expectedSize - WAV_HEADER_SIZE;
  if (riffSize == expectedRiffSize && dataSize == expectedDataSize) {
    return true;
  }

  header[4] = expectedRiffSize & 0xFF;
  header[5] = (expectedRiffSize >> 8) & 0xFF;
  header[6] = (expectedRiffSize >> 16) & 0xFF;
  header[7] = (expectedRiffSize >> 24) & 0xFF;
  header[40] = expectedDataSize & 0xFF;
  header[41] = (expectedDataSize >> 8) & 0xFF;
  header[42] = (expectedDataSize >> 16) & 0xFF;
  header[43] = (expectedDataSize >> 24) & 0xFF;

  File repairFile = SD.open(path, FILE_WRITE);
  if (!repairFile || !repairFile.seek(0)) {
    if (repairFile) {
      repairFile.close();
    }
    return false;
  }
  bool repaired = repairFile.write(header, sizeof(header)) == sizeof(header);
  repairFile.close();
  if (repaired) {
    Serial.printf("Repaired interrupted WAV header: %s\n", path.c_str());
  }
  return repaired;
}

String buildRecordingManifest() {
  String manifest = "";
  File dir = SD.open(AUDIO_DIR);
  if (!dir || !dir.isDirectory()) {
    return "ERROR|Cannot open /Audio\n";
  }

  while (true) {
    File entry = dir.openNextFile();
    if (!entry) {
      break;
    }

    String audioFileName = normalizeAudioPath(String(entry.name()));
    bool isDirectory = entry.isDirectory();
    size_t size = entry.size();
    entry.close();

    if (isDirectory || !hasSuffix(audioFileName, ".wav")) {
      continue;
    }

    // Do not advertise a WAV until its final header is written and the file is closed.
    if (audioFileName == bleActiveRecordingPath) {
      continue;
    }
    if (!isFinalizedWAV(audioFileName, size)) {
      Serial.printf("Skipping incomplete WAV in manifest: %s\n", audioFileName.c_str());
      continue;
    }

    String syncedMarker = String(audioFileName) + ".phone_synced";
    manifest += baseName(audioFileName);
    manifest += "|";
    manifest += String((uint32_t)size);
    manifest += "|";
    manifest += SD.exists(syncedMarker) ? "synced" : "pending";
    manifest += "\n";
  }

  dir.close();
  return manifest;
}

void publishRecordingManifest() {
  if (!storageReady) {
    if (bleManifestCharacteristic != nullptr) {
      bleManifestCharacteristic->setValue("");
    }
    bleNotifyStatus("ERROR:SD card unavailable");
    return;
  }

  String manifest = buildRecordingManifest();
  if (manifest.startsWith("ERROR|")) {
    if (bleManifestCharacteristic != nullptr) {
      bleManifestCharacteristic->setValue("");
    }
    bleNotifyStatus("ERROR:Cannot open /Audio");
    return;
  }
  if (bleManifestCharacteristic != nullptr) {
    bleManifestCharacteristic->setValue(manifest.c_str());
  }
  bleNotifyStatus(String("LIST_READY:") + String(manifest.length()));
}

void bleRecordTask(void *parameter) {
  String audioFileName = getNextAudioFileName();
  bleNotifyStatus(String("RECORDING_STARTED:") + baseName(audioFileName));

  recordAudioFile(audioFileName.c_str(), continueBleRecording);

  bleRecordingRequested = false;
  bleRecordTaskHandle = nullptr;

  publishRecordingManifest();
  bleNotifyStatus(String("RECORDED:") + baseName(audioFileName));
  vTaskDelete(NULL);
}

void writeUint32LE(uint8_t *buffer, uint32_t value) {
  buffer[0] = value & 0xFF;
  buffer[1] = (value >> 8) & 0xFF;
  buffer[2] = (value >> 16) & 0xFF;
  buffer[3] = (value >> 24) & 0xFF;
}

void writeUint16LE(uint8_t *buffer, uint16_t value) {
  buffer[0] = value & 0xFF;
  buffer[1] = (value >> 8) & 0xFF;
}

uint32_t updateCRC32(uint32_t crc, const uint8_t *data, size_t length) {
  for (size_t index = 0; index < length; index++) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
    }
  }
  return crc;
}

uint32_t calculateFileCRC32(File &file) {
  uint32_t originalPosition = file.position();
  uint32_t crc = 0xFFFFFFFFU;
  uint8_t buffer[512];

  file.seek(0);
  while (file.available()) {
    size_t bytesRead = file.read(buffer, sizeof(buffer));
    if (bytesRead == 0) {
      break;
    }
    crc = updateCRC32(crc, buffer, bytesRead);
  }
  file.seek(originalPosition);
  return crc ^ 0xFFFFFFFFU;
}

void bleTransferTask(void *parameter) {
  String path = bleTransferPath;
  uint32_t offset = bleTransferOffset;
  bleTransferInProgress = true;

  File file = SD.open(path, FILE_READ);
  if (!file) {
    bleNotifyStatus(String("ERROR:Cannot open ") + baseName(path));
    bleTransferInProgress = false;
    bleTransferTaskHandle = nullptr;
    vTaskDelete(NULL);
    return;
  }

  uint32_t fileSize = file.size();
  if (offset > fileSize) {
    offset = 0;
  }

  uint32_t fileCRC32 = calculateFileCRC32(file);
  file.seek(offset);
  bleTransferAckOffset = offset;
  bleTransferAckReceived = false;
  bleNotifyStatus(
    String("TRANSFER_STARTED:")
      + baseName(path)
      + ":"
      + String(fileSize)
      + ":"
      + String(offset)
      + ":"
      + String(fileCRC32)
  );

  unsigned long readyDeadline = millis() + 5000;
  while (bleClientConnected && bleTransferInProgress && !bleTransferReceiverReady && millis() < readyDeadline) {
    vTaskDelay(10 / portTICK_PERIOD_MS);
  }

  if (!bleTransferReceiverReady) {
    file.close();
    bleTransferInProgress = false;
    bleTransferTaskHandle = nullptr;
    bleNotifyStatus(String("TRANSFER_ERROR:Phone not ready:") + baseName(path));
    vTaskDelete(NULL);
    return;
  }

  uint8_t packet[6 + BLE_TRANSFER_CHUNK_SIZE];
  bool sendFailed = false;
  uint8_t windowRetryCount = 0;
  while (file.available() && bleClientConnected && bleTransferInProgress) {
    uint32_t windowStart = file.position();
    uint32_t windowEnd = windowStart;
    bleTransferAckReceived = false;

    for (uint8_t chunkIndex = 0;
         chunkIndex < BLE_TRANSFER_WINDOW_CHUNKS && file.available() && bleTransferInProgress;
         chunkIndex++) {
      uint32_t currentOffset = file.position();
      size_t bytesRead = file.read(packet + 6, BLE_TRANSFER_CHUNK_SIZE);
      if (bytesRead == 0) {
        break;
      }

      writeUint32LE(packet, currentOffset);
      writeUint16LE(packet + 4, (uint16_t)bytesRead);
      if (!bleDataCharacteristic->notify(packet, bytesRead + 6)) {
        sendFailed = true;
        break;
      }
      windowEnd = file.position();

      // ACK windows provide the backpressure; this small delay avoids filling
      // the controller queue inside a single connection event.
      vTaskDelay(3 / portTICK_PERIOD_MS);
    }

    if (sendFailed || windowEnd == windowStart) {
      break;
    }

    unsigned long ackStartedAt = millis();
    while (bleClientConnected
           && bleTransferInProgress
           && !bleTransferAckReceived
           && millis() - ackStartedAt < BLE_TRANSFER_ACK_TIMEOUT_MS) {
      vTaskDelay(5 / portTICK_PERIOD_MS);
    }

    if (!bleTransferAckReceived) {
      sendFailed = true;
      break;
    }

    uint32_t acknowledgedOffset = bleTransferAckOffset;
    if (acknowledgedOffset < windowStart || acknowledgedOffset > windowEnd) {
      sendFailed = true;
      break;
    }

    if (acknowledgedOffset < windowEnd) {
      windowRetryCount++;
      if (windowRetryCount > BLE_TRANSFER_WINDOW_RETRY_LIMIT || !file.seek(acknowledgedOffset)) {
        sendFailed = true;
        break;
      }
      continue;
    }

    windowRetryCount = 0;
  }

  bool completed = !sendFailed && file.position() >= fileSize;
  file.close();
  bleTransferInProgress = false;
  bleTransferTaskHandle = nullptr;

  if (sendFailed) {
    bleNotifyStatus(
      String("TRANSFER_ERROR:BLE transfer stalled:")
        + baseName(path)
        + ":"
        + String(bleTransferAckOffset)
    );
  } else if (completed) {
    bleNotifyStatus(String("TRANSFER_DONE:") + baseName(path) + ":" + String(fileSize));
  } else {
    bleNotifyStatus(String("TRANSFER_STOPPED:") + baseName(path));
  }

  vTaskDelete(NULL);
}

void startBleRecording() {
  if (!storageReady) {
    bleNotifyStatus("ERROR:SD card unavailable");
    return;
  }

  if (bleTransferInProgress || bleTransferTaskHandle != nullptr) {
    bleNotifyStatus("BUSY:Transfer running");
    return;
  }

  if (isRecording || bleRecordTaskHandle != nullptr) {
    bleNotifyStatus("BUSY:Already recording");
    return;
  }

  bleRecordingRequested = true;
  xTaskCreate(
    bleRecordTask,
    "BLE Record Task",
    8192,
    NULL,
    1,
    &bleRecordTaskHandle
  );
}

void stopBleRecording() {
  if (!bleRecordingRequested) {
    bleNotifyStatus("IDLE:Not recording");
    return;
  }

  bleRecordingRequested = false;
  bleNotifyStatus("RECORDING_STOPPING");
}

void startBleTransfer(String filename, uint32_t offset) {
  if (!storageReady) {
    bleNotifyStatus("TRANSFER_ERROR:SD card unavailable");
    return;
  }

  if (isRecording || bleRecordTaskHandle != nullptr) {
    bleNotifyStatus("BUSY:Recording in progress");
    return;
  }

  if (bleTransferTaskHandle != nullptr || bleTransferInProgress) {
    bleNotifyStatus("BUSY:Transfer already running");
    return;
  }

  String path = recordingPathFromName(filename);
  if (path == bleActiveRecordingPath) {
    bleNotifyStatus(String("BUSY:Recording not finalized ") + filename);
    return;
  }
  if (!SD.exists(path)) {
    bleNotifyStatus(String("ERROR:Missing ") + filename);
    return;
  }

  bleTransferPath = path;
  bleTransferOffset = offset;
  bleTransferReceiverReady = false;
  bleTransferAckReceived = false;
  BaseType_t taskCreated = xTaskCreate(
    bleTransferTask,
    "BLE Transfer Task",
    8192,
    NULL,
    1,
    &bleTransferTaskHandle
  );
  if (taskCreated != pdPASS) {
    bleTransferTaskHandle = nullptr;
    bleTransferInProgress = false;
    bleNotifyStatus(String("TRANSFER_ERROR:Cannot start transfer:") + filename);
  }
}

void stopBleTransfer() {
  if (!bleTransferInProgress) {
    bleNotifyStatus("IDLE:No transfer");
    return;
  }

  bleTransferInProgress = false;
  bleTransferAckReceived = true;
}

void markPhoneSynced(String filename) {
  String path = recordingPathFromName(filename);
  if (!SD.exists(path)) {
    bleNotifyStatus(String("ERROR:Missing ") + filename);
    return;
  }

  File markerFile = SD.open(String(path) + ".phone_synced", FILE_WRITE);
  if (markerFile) {
    markerFile.println("synced");
    markerFile.close();
  }
  publishRecordingManifest();
  bleNotifyStatus(String("PHONE_SYNCED:") + filename);
}

void handleBleCommand(String command) {
  command.trim();
  Serial.print("BLE command: ");
  Serial.println(command);

  if (command == "PING") {
    bleNotifyStatus(String("PONG:") + DEVICE_ID);
    return;
  }

  if (command == "LIST") {
    if (bleTransferInProgress || bleTransferTaskHandle != nullptr) {
      bleNotifyStatus("BUSY:Transfer running");
      return;
    }
    publishRecordingManifest();
    return;
  }

  if (command == "RECORD_START") {
    startBleRecording();
    return;
  }

  if (command == "RECORD_STOP") {
    stopBleRecording();
    return;
  }

  if (command == "TRANSFER_STOP") {
    stopBleTransfer();
    return;
  }

  if (command.startsWith("TRANSFER_READY:")) {
    String filename = command.substring(String("TRANSFER_READY:").length());
    if (recordingPathFromName(filename) == bleTransferPath && bleTransferInProgress) {
      bleTransferReceiverReady = true;
    }
    return;
  }

  if (command.startsWith("TRANSFER_ACK:")) {
    int firstColon = command.indexOf(':');
    int secondColon = command.indexOf(':', firstColon + 1);
    if (secondColon > 0) {
      String filename = command.substring(firstColon + 1, secondColon);
      uint32_t acknowledgedOffset = (uint32_t)command.substring(secondColon + 1).toInt();
      if (recordingPathFromName(filename) == bleTransferPath && bleTransferInProgress) {
        bleTransferAckOffset = acknowledgedOffset;
        bleTransferAckReceived = true;
      }
    }
    return;
  }

  if (command.startsWith("FETCH:")) {
    int firstColon = command.indexOf(':');
    int secondColon = command.indexOf(':', firstColon + 1);
    String filename = secondColon > 0
      ? command.substring(firstColon + 1, secondColon)
      : command.substring(firstColon + 1);
    uint32_t offset = secondColon > 0
      ? (uint32_t)command.substring(secondColon + 1).toInt()
      : 0;
    startBleTransfer(filename, offset);
    return;
  }

  if (command.startsWith("MARK_SYNCED:")) {
    markPhoneSynced(command.substring(String("MARK_SYNCED:").length()));
    return;
  }

  bleNotifyStatus(String("ERROR:Unknown command ") + command);
}

class WearableServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &connInfo) override {
    bleClientConnected = true;
    Serial.print("BLE client connected: ");
    Serial.println(connInfo.getAddress().toString().c_str());
    bleNotifyStatus(String("CONNECTED:") + DEVICE_ID);
  }

  void onDisconnect(NimBLEServer *server, NimBLEConnInfo &connInfo, int reason) override {
    bleClientConnected = false;
    bleTransferInProgress = false;
    Serial.println("BLE client disconnected.");
    NimBLEDevice::startAdvertising();
  }
};

class ControlCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *characteristic, NimBLEConnInfo &connInfo) override {
    std::string value = characteristic->getValue();
    handleBleCommand(String(value.c_str()));
  }
};

void setupBle() {
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new WearableServerCallbacks());

  NimBLEService *service = server->createService(BLE_SERVICE_UUID);

  NimBLECharacteristic *controlCharacteristic = service->createCharacteristic(
    BLE_CONTROL_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  controlCharacteristic->setCallbacks(new ControlCharacteristicCallbacks());

  bleStatusCharacteristic = service->createCharacteristic(
    BLE_STATUS_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  bleStatusCharacteristic->setValue("BOOTING");

  bleManifestCharacteristic = service->createCharacteristic(
    BLE_MANIFEST_UUID,
    NIMBLE_PROPERTY::READ
  );
  bleManifestCharacteristic->setValue("");

  bleDataCharacteristic = service->createCharacteristic(
    BLE_DATA_UUID,
    NIMBLE_PROPERTY::NOTIFY
  );

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setName(BLE_DEVICE_NAME);
  advertising->enableScanResponse(true);
  advertising->start();

  Serial.println("BLE advertising started.");
  bleNotifyStatus(String("READY:") + DEVICE_ID);
}

// -------------------- Audio helper --------------------

void applyVolumeGain(uint8_t *buffer, size_t bytesRead) {
  for (size_t i = 0; i + 1 < bytesRead; i += 2) {
    int16_t sample = *(int16_t *)(buffer + i);

    int32_t amplified = sample << VOLUME_GAIN;

    if (amplified > 32767) {
      amplified = 32767;
    } else if (amplified < -32768) {
      amplified = -32768;
    }

    *(int16_t *)(buffer + i) = (int16_t)amplified;
  }
}

// -------------------- Main recording function --------------------

void recordAudioFile(const char *audioFileName, bool (*shouldContinueRecording)()) {
  Serial.println();
  Serial.println("Recording started...");
  Serial.printf("Saving to: %s\n", audioFileName);
  Serial.println("Release button to stop recording.");
  String finalPath = String(audioFileName);
  String temporaryPath = finalPath + ".recording";
  bleActiveRecordingPath = finalPath;
  if (SD.exists(temporaryPath)) {
    SD.remove(temporaryPath);
  }

  File file = SD.open(temporaryPath, FILE_WRITE);

  if (!file) {
    Serial.println("Failed to open audio file for writing!");
    bleActiveRecordingPath = "";
    return;
  }

  // We do not know the final audio size yet.
  // So write a temporary WAV header first.
  uint8_t wav_header[WAV_HEADER_SIZE];
  generate_wav_header(wav_header, 0, SAMPLE_RATE);
  file.write(wav_header, WAV_HEADER_SIZE);

  const size_t BUFFER_SIZE = 1024;
  uint8_t *rec_buffer = (uint8_t *)malloc(BUFFER_SIZE);

  if (rec_buffer == NULL) {
    Serial.println("Failed to allocate recording buffer!");
    file.close();
    bleActiveRecordingPath = "";
    return;
  }

  uint32_t totalBytesWritten = 0;
  bool recordingSucceeded = true;
  isRecording = true;

  while (shouldContinueRecording()) {
    size_t bytesRead = I2S.readBytes((char *)rec_buffer, BUFFER_SIZE);

    if (bytesRead == 0) {
      Serial.println("I2S read failed!");
      recordingSucceeded = false;
      break;
    }

    applyVolumeGain(rec_buffer, bytesRead);

    size_t bytesWritten = file.write(rec_buffer, bytesRead);

    if (bytesWritten != bytesRead) {
      Serial.println("SD write failed!");
      recordingSucceeded = false;
      break;
    }

    totalBytesWritten += bytesWritten;
  }

  isRecording = false;

  // Return LED to steady ON after recording.
  digitalWrite(RECORD_LED_PIN, HIGH);

  if (recordingSucceeded && totalBytesWritten > 0) {
    // Now that we know the real audio size,
    // go back to the beginning and rewrite the WAV header.
    generate_wav_header(wav_header, totalBytesWritten, SAMPLE_RATE);
    if (!file.seek(0) || file.write(wav_header, WAV_HEADER_SIZE) != WAV_HEADER_SIZE) {
      recordingSucceeded = false;
    }
  } else {
    recordingSucceeded = false;
  }

  free(rec_buffer);
  file.close();

  if (recordingSucceeded) {
    if (SD.exists(finalPath)) {
      SD.remove(finalPath);
    }
    recordingSucceeded = SD.rename(temporaryPath, finalPath);
  }
  if (!recordingSucceeded) {
    SD.remove(temporaryPath);
  }
  bleActiveRecordingPath = "";

  if (recordingSucceeded) {
    Serial.println("Recording stopped.");
    Serial.printf("Audio data written: %lu bytes\n", totalBytesWritten);
    Serial.println("WAV header updated.");
    Serial.println("File closed safely.");
  } else {
    Serial.println("Recording failed; incomplete temporary file removed.");
  }
}

void recordWhileButtonHeld(const char *audioFileName) {
  recordAudioFile(audioFileName, continueButtonRecording);
}

// -------------------- Setup --------------------

void setup() {
  Serial.begin(115200);
  delay(1500);

  Serial.println();
  Serial.println("XIAO ESP32S3 Sense Audio Recorder Starting...");

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(RECORD_LED_PIN, OUTPUT);

  // Device is powered, so LED starts ON.
  digitalWrite(RECORD_LED_PIN, HIGH);

  // Start LED blinking task
  xTaskCreate(
    recordLedTask,
    "Record LED Task",
    2048,
    NULL,
    1,
    NULL
  );

  // I2S setup for onboard MEMS mic
  I2S.setPinsPdmRx(I2S_PDM_CLK_PIN, I2S_PDM_DATA_PIN);

  if (!I2S.begin(I2S_MODE_PDM_RX, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("Failed to initialize I2S microphone!");

    while (1) {
      // Keep LED solid ON to show device still has power.
      digitalWrite(RECORD_LED_PIN, HIGH);
      delay(1000);
    }
  }

  Serial.println("I2S microphone OK.");

  // Initialize SD card
  if (!SD.begin(SD_CS_PIN, SPI, SD_SPI_FREQUENCY)) {
    Serial.println("Failed to mount MicroSD card!");
    setupBle();
    bleNotifyStatus("ERROR:SD mount failed");
    return;
  }

  uint8_t cardType = SD.cardType();

  if (cardType == CARD_NONE) {
    Serial.println("No MicroSD card inserted!");
    setupBle();
    bleNotifyStatus("ERROR:No SD card");
    return;
  }

  Serial.print("MicroSD Card Type: ");

  if (cardType == CARD_MMC) {
    Serial.println("MMC");
  } else if (cardType == CARD_SD) {
    Serial.println("SDSC");
  } else if (cardType == CARD_SDHC) {
    Serial.println("SDHC");
  } else {
    Serial.println("UNKNOWN");
  }

  if (!makeAudioDirectoryIfNeeded()) {
    Serial.println("Cannot continue without /Audio directory.");
    setupBle();
    bleNotifyStatus("ERROR:Cannot create /Audio");
    return;
  }

  cleanupTemporaryRecordings();
  storageReady = true;
  setupBle();

  if (ENABLE_WIFI_UPLOAD) {
    uploadPendingAudioFiles();
  } else {
    Serial.println("Wi-Fi upload disabled. Pending files are available over BLE.");
  }

  Serial.println("Ready.");
  Serial.println("Press and hold the button on D0 to record.");
}

// -------------------- Loop --------------------

void loop() {
  if (!storageReady) {
    static unsigned long lastStorageRetryMs = 0;
    if (millis() - lastStorageRetryMs >= 3000) {
      lastStorageRetryMs = millis();
      Serial.println("Retrying MicroSD mount...");
      tryRecoverStorage();
    }
    delay(20);
    return;
  }

  if (Serial.available()) {
    String command = Serial.readStringUntil('\n');
    command.trim();
    if (command == "CLEAR_RECORDINGS") {
      clearAudioDirectory();
    } else if (command == "RECORD_START") {
      startBleRecording();
    } else if (command == "RECORD_STOP") {
      stopBleRecording();
    } else if (command == "LIST") {
      publishRecordingManifest();
    }
  }

  static bool hardwareButtonArmed = false;
  if (!buttonPressed()) {
    hardwareButtonArmed = true;
  }

  if (storageReady && hardwareButtonArmed && !isRecording && buttonPressed()) {
    delay(30); // debounce

    if (buttonPressed()) {
      hardwareButtonArmed = false;
      String audioFileName = getNextAudioFileName();

      recordWhileButtonHeld(audioFileName.c_str());

      if (ENABLE_WIFI_UPLOAD) {
        uploadAudioFile(audioFileName);
      } else {
        bleNotifyStatus(String("RECORDED:") + baseName(audioFileName));
      }

      delay(200); // prevent accidental double-trigger

      Serial.println("Ready for next recording.");
    }
  }
}
