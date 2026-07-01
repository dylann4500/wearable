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
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
      continue
    }

    $version = & $command @($args + @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")) 2>$null
    if ($LASTEXITCODE -eq 0 -and ($version -eq "3.11" -or $version -eq "3.12")) {
      return @{ Command = $command; Args = $args }
    }
  }

  throw "Could not find Python 3.11 or 3.12."
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
}

& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $venvPython -m pip install -r requirements-diarization.txt
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Diarization dependencies installed. Run .\scripts\run.ps1 and upload an audio file."
