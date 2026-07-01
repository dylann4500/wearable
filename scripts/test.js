#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const isWindows = process.platform === "win32";
const python = path.join(root, ".venv", isWindows ? "Scripts/python.exe" : "bin/python");
const npm = isWindows ? "npm.cmd" : "npm";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: "inherit",
    shell: false,
    env: {
      ...process.env,
      PYTHONPYCACHEPREFIX: process.env.PYTHONPYCACHEPREFIX || path.join(os.tmpdir(), "wearable-pycache"),
      ...options.env,
    },
  });

  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
}

run(python, [
  "-m",
  "py_compile",
  "app/main.py",
  "app/analyzer.py",
  "app/recordings.py",
  "scripts/simulate_device_upload.py",
  "tests/test_recordings_api.py",
]);

run(python, ["-m", "unittest", "discover", "-s", "tests"]);
run(npm, ["--prefix", "frontend", "run", "build"]);
