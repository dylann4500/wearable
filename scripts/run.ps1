$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Find-Python {
  $candidates = @(
    @{ Command = "py"; Args = @("-3.12") },
    @{ Command = "py"; Args = @("-3.11") },
    @{ Command = "python"; Args = @() },
    @{ Command = "python3"; Args = @() }
  )

  foreach ($candidate in $candidates) {
    $command = $candidate["Command"]
    $args = $candidate["Args"]
    $cmd = Get-Command $command -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
      continue
    }

    $version = & $command @($args + @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")) 2>$null
    if ($LASTEXITCODE -eq 0 -and ($version -eq "3.11" -or $version -eq "3.12")) {
      return @{ Command = $command; Args = $args }
    }
  }

  throw "Could not find Python 3.11 or 3.12. Install Python from https://www.python.org/downloads/windows/ and enable 'Add python.exe to PATH'."
}

function Invoke-Python($pythonSpec, [string[]]$arguments) {
  & $pythonSpec["Command"] @($pythonSpec["Args"] + $arguments)
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

$pythonSpec = Find-Python
$venvPython = Join-Path $RepoRoot ".venv\Scripts\python.exe"

if (!(Test-Path $venvPython)) {
  Invoke-Python $pythonSpec @("-m", "venv", ".venv")
} else {
  & $venvPython -c "import sys; raise SystemExit(0 if sys.version_info[:2] in {(3, 11), (3, 12)} else 1)"
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -Recurse -Force ".venv"
    Invoke-Python $pythonSpec @("-m", "venv", ".venv")
  }
}

& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $venvPython -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Write-Warning "ffmpeg is required for uploads. Install it with: winget install Gyan.FFmpeg"
}

if ($null -ne (Get-Command npm -ErrorAction SilentlyContinue)) {
  if (!(Test-Path "frontend\node_modules")) {
    npm --prefix frontend install
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  npm --prefix frontend run build
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Warning "npm is not installed. Serving the legacy static UI instead of the React build."
}

$env:PYTHONPATH = "$RepoRoot"
$port = if ($env:PORT) { $env:PORT } else { "8000" }

& $venvPython -m uvicorn app.main:app --host 127.0.0.1 --port $port --reload --reload-dir app --reload-dir frontend/src
