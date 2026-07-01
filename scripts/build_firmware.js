#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const isWindows = process.platform === "win32";
const configPath = path.join(root, "firmware", "xiao-esp32s3-prototype", "firmware_config.h");
const examplePath = path.join(root, "firmware", "xiao-esp32s3-prototype", "firmware_config.example.h");
const venvPio = path.join(root, ".venv", isWindows ? "Scripts/pio.exe" : "bin/pio");

if (!fs.existsSync(configPath)) {
  fs.copyFileSync(examplePath, configPath);
  console.log(`Created ${path.relative(root, configPath)} from the example template.`);
  console.log("Edit it with real Wi-Fi/server values before flashing to hardware.");
}

const command = fs.existsSync(venvPio) ? venvPio : "pio";
const result = spawnSync(command, ["run", "-e", "xiao_esp32s3"], {
  cwd: root,
  stdio: "inherit",
  shell: false,
  env: {
    ...process.env,
    PLATFORMIO_CORE_DIR: process.env.PLATFORMIO_CORE_DIR || path.join(root, ".platformio"),
  },
});

if (result.error) {
  console.error(result.error.message);
  console.error("PlatformIO is not installed. Install it with:");
  console.error(isWindows ? ".venv\\Scripts\\python.exe -m pip install platformio" : ".venv/bin/python -m pip install platformio");
  process.exit(1);
}

process.exit(result.status || 0);
