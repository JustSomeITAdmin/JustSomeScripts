<#
.SYNOPSIS
  Install Intune RCA on a Windows machine into a self-contained virtual env.
  Works from a git clone (editable install) or from a built wheel.

.DESCRIPTION
  Place this script next to the wheel (intune_rca-*.whl), or in the repo root
  (it will find dist\*.whl). It creates a venv, installs the tool, and prints how
  to run it. Re-running upgrades in place.

  Requirements on the target machine:
    * Windows (parsers use Get-WinEvent, expand.exe, Get-WindowsUpdateLog, tracerpt)
    * Python 3.11+  (https://www.python.org/downloads/ — tick "Add to PATH")
    * Optional: Ollama + a model, only for the LLM agent (`rca investigate`)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -VenvPath C:\Tools\rca-venv
#>
param(
    [string]$VenvPath = "$PSScriptRoot\rca-venv",
    [string]$Wheel
)
$ErrorActionPreference = 'Stop'

function Find-Python {
    foreach ($cand in @('py -3', 'python', 'python3')) {
        $parts = $cand.Split(' ')
        $exe = Get-Command $parts[0] -ErrorAction SilentlyContinue
        if ($exe) {
            $ver = & $parts[0] $parts[1..($parts.Length-1)] -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null
            if ($ver -and [version]$ver -ge [version]'3.11') { return $cand }
        }
    }
    return $null
}

Write-Host "== Intune RCA installer ==" -ForegroundColor Cyan

$py = Find-Python
if (-not $py) {
    Write-Host "Python 3.11+ not found. Install from https://www.python.org/downloads/ (tick 'Add to PATH'), then re-run." -ForegroundColor Red
    exit 1
}
Write-Host "Using Python: $py"

if (-not $Wheel) {
    $Wheel = Get-ChildItem -Path $PSScriptRoot, "$PSScriptRoot\dist" -Filter 'intune_rca-*.whl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$Source = $null
if (-not $Wheel -or -not (Test-Path $Wheel)) {
    if (Test-Path (Join-Path $PSScriptRoot 'pyproject.toml')) {
        $Source = $PSScriptRoot      # git checkout: editable install; data + custom_rules stay in this folder
        Write-Host "Source checkout: $Source"
    } else {
        Write-Host "No wheel and no pyproject.toml found. Clone the repo or put intune_rca-*.whl next to this script." -ForegroundColor Red
        exit 1
    }
} else { Write-Host "Wheel: $Wheel" }

if (-not (Test-Path $VenvPath)) {
    Write-Host "Creating venv at $VenvPath ..."
    $pyParts = $py.Split(' ')
    & $pyParts[0] $pyParts[1..($pyParts.Length-1)] -m venv $VenvPath
}
$venvPy = Join-Path $VenvPath 'Scripts\python.exe'

Write-Host "Installing ..."
& $venvPy -m pip install --upgrade pip --quiet
if ($Source) { & $venvPy -m pip install -e "$Source" --quiet }
else         { & $venvPy -m pip install --upgrade --force-reinstall "$Wheel" --quiet }

$rca = Join-Path $VenvPath 'Scripts\rca.exe'
Write-Host ""
Write-Host "Installed. Verify:" -ForegroundColor Green
& $rca --help | Select-Object -First 3

Write-Host ""
Write-Host "Run it:" -ForegroundColor Cyan
Write-Host "  $rca web                 # local web UI (http://127.0.0.1:8000)"
Write-Host "  $rca new-case -s '...'   # or use the CLI"
Write-Host ""
if ($Source) { Write-Host "Data is stored in  $Source\data  (source checkout; gitignored)." }
else         { Write-Host "Data is stored under  $env:USERPROFILE\.intune-rca  (override with RCA_HOME)." }
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "Note: the LLM agent (rca investigate) needs Ollama + a model:" -ForegroundColor Yellow
    Write-Host "  winget install Ollama.Ollama ;  ollama pull qwen2.5:7b"
}
