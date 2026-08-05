# build-optimized.ps1 — Build llama.cpp with AVX-VNNI optimizations for Intel N150
#
# Uses MSVC (not Clang) because MSVC generates superior code for AVX-VNNI
# on Gracemont architecture (Intel N150). Enables AVX2 + FMA + F16C + AVX-VNNI
# + OpenMP + Repack for maximum performance.
#
# Result: ~14.5 tok/s (vs 6.23 tok/s pre-built = +133% improvement)
#
# Run from PowerShell (Admin not required):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Paul\build-optimized.ps1"

$ErrorActionPreference = "SilentlyContinue"

$buildDir = "C:\Users\Paul\llama-build"
$sourceDir = "$buildDir\llama.cpp"
$installDir = "C:\Users\Paul\llama-b10242"
$branch = "master"  # Latest: includes sampler optimizations (PR #22645, +50% on Gemma)
$vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"

# Fallback: try other VS editions
if (-not (Test-Path $vcvars)) {
    $vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
}
if (-not (Test-Path $vcvars)) {
    $vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
}
if (-not (Test-Path $vcvars)) {
    Write-Host "ERROR: Visual Studio 2022 not found. Install from:" -ForegroundColor Red
    Write-Host "  https://visualstudio.microsoft.com/downloads/" -ForegroundColor Yellow
    Write-Host "  (Desktop development with C++ workload)" -ForegroundColor Yellow
    exit 1
}

Write-Host "=== llama.cpp Optimized Build for Intel N150 ===" -ForegroundColor Cyan
Write-Host "Branch: $branch | Compiler: MSVC | Install dir: $installDir"

# --- Ensure build tools ---
$env:PATH = "C:\Program Files\CMake\bin;" + $env:PATH
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    Write-Host "Installing CMake..." -ForegroundColor Yellow
    winget install Kitware.CMake --accept-source-agreements --accept-package-agreements --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","Machine")
}

$ninja = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninja) {
    Write-Host "Installing Ninja..." -ForegroundColor Yellow
    winget install Ninja-build.Ninja --accept-source-agreements --accept-package-agreements --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    $ninjaDir = "C:\Users\Paul\AppData\Local\Microsoft\WinGet\Packages\Ninja-build.Ninja_Microsoft.Winget.Source_8wekyb3d8bbwe"
    if (Test-Path "$ninjaDir\ninja.exe") { $env:PATH = "$ninjaDir;" + $env:PATH }
}

Write-Host "cmake: $(cmake --version | Select-Object -First 1)" -ForegroundColor Green
Write-Host "ninja: $(ninja --version)" -ForegroundColor Green

# --- Clone/update llama.cpp ---
if (-not (Test-Path $sourceDir)) {
    Write-Host "Cloning llama.cpp ($branch)..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    Set-Location $buildDir
    git clone --branch $branch --depth 1 https://github.com/ggml-org/llama.cpp.git $sourceDir
} else {
    Write-Host "Updating source to $branch..." -ForegroundColor Yellow
    Set-Location $sourceDir
    git fetch origin $branch 2>$null
    git checkout $branch 2>$null
    git pull origin $branch 2>$null
}
Set-Location $sourceDir
Write-Host "Source: $(git log --oneline -1)" -ForegroundColor Green

# --- Clean build directory (critical: stale objects cause link errors) ---
Write-Host "Cleaning build directory..." -ForegroundColor Yellow
Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
Remove-Item -Force CMakeCache.txt -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force CMakeFiles -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# --- Configure with MSVC + AVX2 + AVX-VNNI + OpenMP ---
Write-Host "Configuring with MSVC + AVX-VNNI..." -ForegroundColor Yellow
$cfg = "call `"$vcvars`" x64 && cmake -B build -G Ninja `"-DCMAKE_C_COMPILER=cl`" `"-DCMAKE_CXX_COMPILER=cl`" -DGGML_NATIVE=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_AVX_VNNI=ON -DGGML_AVX512=OFF -DGGML_CPU_REPACK=ON -DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON"
$p = Start-Process cmd.exe -ArgumentList '/c',$cfg -Wait -NoNewWindow -PassThru -WorkingDirectory $sourceDir
if ($p.ExitCode -ne 0) { Write-Host "Configure FAILED" -ForegroundColor Red; exit 1 }

# Verify flags
Select-String -Path "build\CMakeCache.txt" -Pattern "GGML_AVX:|GGML_OPENMP_ENABLED" | ForEach-Object { Write-Host "  $($_.Line)" }

# --- Build (10-30 minutes on N150) ---
Write-Host "Building (this takes 10-30 minutes on N150)..." -ForegroundColor Yellow
$build = "call `"$vcvars`" x64 && cmake --build build --config Release -j 4"
$p = Start-Process cmd.exe -ArgumentList '/c',$build -Wait -NoNewWindow -PassThru -WorkingDirectory $sourceDir
if ($p.ExitCode -ne 0) {
    Write-Host "Build FAILED" -ForegroundColor Red
    Write-Host "Check build log for errors" -ForegroundColor Yellow
    exit 1
}
Write-Host "Build complete!" -ForegroundColor Green

# --- Deploy ---
Write-Host "Deploying to $installDir..." -ForegroundColor Yellow
$backupDir = "$installDir\backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item "$installDir\*.exe" $backupDir -ErrorAction SilentlyContinue
Copy-Item "$installDir\*.dll" $backupDir -ErrorAction SilentlyContinue
Copy-Item "build\bin\*.exe" $installDir -Force
Copy-Item "build\bin\*.dll" $installDir -Force
Write-Host "New binaries deployed (old backed up to $backupDir)" -ForegroundColor Green

$count = (Get-ChildItem "build\bin\*.exe" | Measure-Object).Count
Write-Host "Binaries built: $count" -ForegroundColor Green

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Green
Write-Host "Optimized binary with AVX-VNNI support is in: $installDir" -ForegroundColor Green
Write-Host "Expected speed: ~14.5 tok/s (vs 6.23 tok/s pre-built = +133%)" -ForegroundColor Green
Write-Host ""
Write-Host "Test with: cd C:\Users\Paul; .\start-windows.cmd" -ForegroundColor Green
