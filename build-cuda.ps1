# build-cuda.ps1 — Build llama.cpp with CUDA for NVIDIA GPUs
#
# Auto-detects Visual Studio (searches 2022/2025/17/18 folder names and all
# editions), then builds llama.cpp with GGML_CUDA=ON. Works on any NVIDIA GPU.
#
# Result: start-windows-gpu.cmd auto-detects VRAM and runs at 17-18 tok/s.
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File "build-cuda.ps1"

$ErrorActionPreference = "Stop"

$sourceDir = Join-Path $PSScriptRoot "llama.cpp"
$buildDir = Join-Path $sourceDir "build"

# --- Find Visual Studio ------------------------------------------------------
$vcvars = Get-ChildItem "C:\Program Files\Microsoft Visual Studio","C:\Program Files (x86)\Microsoft Visual Studio" `
    -Recurse -Filter "vcvarsall.bat" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $vcvars) {
    Write-Host "ERROR: Visual Studio not found. Install from:" -ForegroundColor Red
    Write-Host "  https://visualstudio.microsoft.com/downloads/" -ForegroundColor Yellow
    Write-Host "  (Desktop development with C++ workload)" -ForegroundColor Yellow
    exit 1
}
Write-Host "Found: $vcvars" -ForegroundColor Green

# --- Find CUDA ---------------------------------------------------------------
$cudaPath = $env:CUDA_PATH
if (-not $cudaPath) {
    $cuda = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($cuda) { $cudaPath = $cuda.FullName }
}
if ($cudaPath) { Write-Host "CUDA: $cudaPath" -ForegroundColor Green }

# --- Ensure cmake ------------------------------------------------------------
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    Write-Host "Installing CMake..." -ForegroundColor Yellow
    winget install Kitware.CMake --accept-source-agreements --accept-package-agreements --silent
}

# --- Clone llama.cpp if needed -----------------------------------------------
if (-not (Test-Path $sourceDir)) {
    Write-Host "Cloning llama.cpp..." -ForegroundColor Yellow
    git clone --depth 1 https://github.com/ggerganov/llama.cpp.git $sourceDir
}

# --- Configure + Build -------------------------------------------------------
Write-Host "=== Building llama.cpp with CUDA ===" -ForegroundColor Cyan

$cfgArgs = "call `"$vcvars`" x64 && cmake -B `"$buildDir`" -S `"$sourceDir`" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release"
Write-Host "Configuring..." -ForegroundColor Yellow
$p = Start-Process cmd.exe -ArgumentList '/c',$cfgArgs -Wait -NoNewWindow -PassThru -WorkingDirectory $sourceDir
if ($p.ExitCode -ne 0) { Write-Host "Configure FAILED" -ForegroundColor Red; exit 1 }

$buildArgs = "call `"$vcvars`" x64 && cmake --build `"$buildDir`" --config Release --target llama-server -j $env:NUMBER_OF_PROCESSORS"
Write-Host "Building (this takes 10-30 min on first run)..." -ForegroundColor Yellow
$p = Start-Process cmd.exe -ArgumentList '/c',$buildArgs -Wait -NoNewWindow -PassThru -WorkingDirectory $sourceDir
if ($p.ExitCode -ne 0) { Write-Host "Build FAILED" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Green
Write-Host "Binary: $(Join-Path $buildDir 'bin\llama-server.exe')" -ForegroundColor Green
Write-Host ""
Write-Host "Test: cd $PSScriptRoot; .\start-windows-gpu.cmd --chat" -ForegroundColor Green
