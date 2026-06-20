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

// XIAO ESP32S3 Sense onboard MEMS microphone pins
const int I2S_PDM_CLK_PIN = 42;
const int I2S_PDM_DATA_PIN = 41;

// -------------------- File settings --------------------

const char *AUDIO_DIR = "/Audio";

// -------------------- Recording state --------------------

volatile bool isRecording = false;

// -------------------- Button helper --------------------

bool buttonPressed() {
  // INPUT_PULLUP logic:
  // Not pressed = HIGH
  // Pressed     = LOW
  return digitalRead(BUTTON_PIN) == LOW;
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

void recordWhileButtonHeld(const char *audioFileName) {
  Serial.println();
  Serial.println("Recording started...");
  Serial.printf("Saving to: %s\n", audioFileName);
  Serial.println("Release button to stop recording.");

  File file = SD.open(audioFileName, FILE_WRITE);

  if (!file) {
    Serial.println("Failed to open audio file for writing!");
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
    return;
  }

  uint32_t totalBytesWritten = 0;
  isRecording = true;

  while (buttonPressed()) {
    size_t bytesRead = I2S.readBytes((char *)rec_buffer, BUFFER_SIZE);

    if (bytesRead == 0) {
      Serial.println("I2S read failed!");
      break;
    }

    applyVolumeGain(rec_buffer, bytesRead);

    size_t bytesWritten = file.write(rec_buffer, bytesRead);

    if (bytesWritten != bytesRead) {
      Serial.println("SD write failed!");
      break;
    }

    totalBytesWritten += bytesWritten;
  }

  isRecording = false;

  // Return LED to steady ON after recording.
  digitalWrite(RECORD_LED_PIN, HIGH);

  // Now that we know the real audio size,
  // go back to the beginning and rewrite the WAV header.
  generate_wav_header(wav_header, totalBytesWritten, SAMPLE_RATE);
  file.seek(0);
  file.write(wav_header, WAV_HEADER_SIZE);

  free(rec_buffer);
  file.close();

  Serial.println("Recording stopped.");
  Serial.printf("Audio data written: %lu bytes\n", totalBytesWritten);
  Serial.println("WAV header updated.");
  Serial.println("File closed safely.");
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
  if (!SD.begin(SD_CS_PIN)) {
    Serial.println("Failed to mount MicroSD card!");

    while (1) {
      // Keep LED solid ON to show device still has power.
      digitalWrite(RECORD_LED_PIN, HIGH);
      delay(1000);
    }
  }

  uint8_t cardType = SD.cardType();

  if (cardType == CARD_NONE) {
    Serial.println("No MicroSD card inserted!");

    while (1) {
      // Keep LED solid ON to show device still has power.
      digitalWrite(RECORD_LED_PIN, HIGH);
      delay(1000);
    }
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

    while (1) {
      // Keep LED solid ON to show device still has power.
      digitalWrite(RECORD_LED_PIN, HIGH);
      delay(1000);
    }
  }

  Serial.println("Ready.");
  Serial.println("Press and hold the button on D0 to record.");
}

// -------------------- Loop --------------------

void loop() {
  if (buttonPressed()) {
    delay(30); // debounce

    if (buttonPressed()) {
      String audioFileName = getNextAudioFileName();

      recordWhileButtonHeld(audioFileName.c_str());

      delay(200); // prevent accidental double-trigger

      Serial.println("Ready for next recording.");
    }
  }
}