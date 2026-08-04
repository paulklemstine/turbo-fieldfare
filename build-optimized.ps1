# build-optimized.ps1 — Build llama.cpp with AVX-VNNI optimizations for Intel N150
#
# This script:
# 1. Installs LLVM/Clang (best codegen for AVX-VNNI on Intel)
# 2. Installs Ninja build system
# 3. Clones llama.cpp (matching the b10219 base)
# 4. Builds with -DGGML_NATIVE=ON -DGGML_AVX_VNNI=ON -DGGML_BLAS=ON
# 5. Deploys the new binaries to llama-b10242\
#
# Run from PowerShell (Admin not required):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Paul\build-optimized.ps1"

$ErrorActionPreference = "Stop"

$buildDir = "C:\Users\Paul\llama-build"
$sourceDir = "$buildDir\llama.cpp"
$installDir = "C:\Users\Paul\llama-b10242"
$branch = "b10219"  # Match the version we were using

Write-Host "=== llama.cpp Optimized Build for Intel N150 ===" -ForegroundColor Cyan
Write-Host "Build dir: $buildDir"
Write-Host "Output dir: $installDir"
Write-Host ""

# --- Step 1: Install LLVM/Clang ---
Write-Host "Checking for LLVM/Clang..." -ForegroundColor Yellow
$clang = Get-Command clang -ErrorAction SilentlyContinue
if (-not $clang) {
    Write-Host "Installing LLVM via winget..." -ForegroundColor Yellow
    winget install LLVM.LLVM --accept-source-agreements --accept-package-agreements --silent
    # LLVM installs to Program Files\LLVM\bin
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $clang = Get-Command clang -ErrorAction SilentlyContinue
    if (-not $clang) {
        # Add LLVM to PATH manually
        if (Test-Path "C:\Program Files\LLVM\bin\clang.exe") {
            $env:PATH = "C:\Program Files\LLVM\bin;" + $env:PATH
            Write-Host "Added C:\Program Files\LLVM\bin to PATH" -ForegroundColor Green
        } else {
            Write-Host "ERROR: LLVM install completed but clang.exe not found." -ForegroundColor Red
            Write-Host "Please restart PowerShell and re-run this script." -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "clang found: $(clang --version | Select-Object -First 1)" -ForegroundColor Green

# --- Step 2: Install Ninja ---
Write-Host "Checking for Ninja..." -ForegroundColor Yellow
$ninja = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninja) {
    Write-Host "Installing Ninja via winget..." -ForegroundColor Yellow
    winget install Ninja-build.Ninja --accept-source-agreements --accept-package-agreements --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $ninja = Get-Command ninja -ErrorAction SilentlyContinue
    if (-not $ninja) {
        # Try chocolatey or direct download
        Write-Host "winget install may have failed. Trying direct download..." -ForegroundColor Yellow
        $ninjaUrl = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip"
        $ninjaZip = "$env:TEMP\ninja.zip"
        $ninjaDir = "$buildDir\ninja"
        Invoke-WebRequest -Uri $ninjaUrl -OutFile $ninjaZip
        Expand-Archive -Path $ninjaZip -DestinationPath $ninjaDir -Force
        $env:PATH = "$ninjaDir;" + $env:PATH
        Write-Host "Ninja installed to $ninjaDir" -ForegroundColor Green
    }
}
Write-Host "ninja found: $(ninja --version)" -ForegroundColor Green

# --- Step 3: Install CMake ---
Write-Host "Checking for CMake..." -ForegroundColor Yellow
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    Write-Host "Installing CMake via winget..." -ForegroundColor Yellow
    winget install Kitware.CMake --accept-source-agreements --accept-package-agreements --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        if (Test-Path "C:\Program Files\CMake\bin\cmake.exe") {
            $env:PATH = "C:\Program Files\CMake\bin;" + $env:PATH
            Write-Host "Added C:\Program Files\CMake\bin to PATH" -ForegroundColor Green
        } else {
            Write-Host "ERROR: CMake install failed. Restart PowerShell and re-run." -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "cmake found: $(cmake --version | Select-Object -First 1)" -ForegroundColor Green

# --- Step 4: Clone llama.cpp ---
Write-Host "Cloning llama.cpp ($branch)..." -ForegroundColor Yellow
if (-not (Test-Path $sourceDir)) {
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    Set-Location $buildDir
    git clone --branch $branch --depth 1 https://github.com/ggml-org/llama.cpp.git $sourceDir
    if (-not (Test-Path $sourceDir)) {
        Write-Host "ERROR: Failed to clone llama.cpp" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Source already exists at $sourceDir" -ForegroundColor Green
}
Write-Host "llama.cpp ready" -ForegroundColor Green

# --- Step 5: Configure with CMake ---
Write-Host "Configuring build with optimizations..." -ForegroundColor Yellow
Set-Location $sourceDir
$buildPath = "$sourceDir\build"
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

# Find clang with full paths (avoids PATH issues)
$clangPath = ""
$clangCppPath = ""
if (Test-Path "C:\Program Files\LLVM\bin\clang.exe") {
    $clangPath = "C:\Program Files\LLVM\bin\clang.exe"
    $clangCppPath = "C:\Program Files\LLVM\bin\clang++.exe"
} elseif (Test-Path "C:\Program Files (x86)\LLVM\bin\clang.exe") {
    $clangPath = "C:\Program Files (x86)\LLVM\bin\clang.exe"
    $clangCppPath = "C:\Program Files (x86)\LLVM\bin\clang++.exe"
}
if (-not $clangPath) {
    Write-Host "ERROR: clang.exe not found. LLVM may not be properly installed." -ForegroundColor Red
    exit 1
}
Write-Host "Using clang: $clangPath" -ForegroundColor Green

# Build with all optimizations for N150 (Gracemont / Alder Lake-N):
#   -DGGML_NATIVE=ON      : -march=native (enable all local CPU features)
#   -DGGML_AVX_VNNI=ON    : Explicitly enable AVX-VNNI (vpdpbusd for Q4_0 matmul)
#   -DGGML_BLAS=ON        : BLAS for prompt prefill acceleration
#   -DCMAKE_BUILD_TYPE=Release : Full optimization
#   Clang produces better AVX-VNNI codegen than MSVC for Intel Atom
$cmakeArgs = @(
    "-B", "build",
    "-G", "Ninja",
    "-DCMAKE_C_COMPILER=$clangPath",
    "-DCMAKE_CXX_COMPILER=$clangCppPath",
    "-DGGML_NATIVE=ON",
    "-DGGML_AVX_VNNI=ON",
    "-DGGML_BLAS=ON",
    "-DGGML_BLAS_VENDOR=OpenBLAS",
    "-DGGML_CPU_REPACK=ON",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON"
)

Write-Host "CMake arguments: $cmakeArgs" -ForegroundColor DarkGray
& cmake @cmakeArgs 2>&1 | Tee-Object -FilePath "$buildPath\cmake_config.log"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: CMake configuration failed. Check $buildPath\cmake_config.log" -ForegroundColor Red

    # Fallback without BLAS if OpenBLAS not found
    Write-Host "Retrying without BLAS..." -ForegroundColor Yellow
    $cmakeArgs = @(
        "-B", "build",
        "-G", "Ninja",
        "-DCMAKE_C_COMPILER=$clangPath",
        "-DCMAKE_CXX_COMPILER=$clangCppPath",
        "-DGGML_NATIVE=ON",
        "-DGGML_AVX_VNNI=ON",
        "-DGGML_CPU_REPACK=ON",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON",
        "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON"
    )
    & cmake @cmakeArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: CMake configuration failed again." -ForegroundColor Red
        exit 1
    }
}
Write-Host "CMake configuration complete" -ForegroundColor Green

# --- Step 6: Build ---
Write-Host "Building (this takes 10-30 minutes)..." -ForegroundColor Yellow
Set-Location $sourceDir
cmake --build build --config Release -j 4 2>&1 | Tee-Object -FilePath "$buildPath\build.log"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Build failed. Check $buildPath\build.log" -ForegroundColor Red
    exit 1
}
Write-Host "Build complete!" -ForegroundColor Green

# --- Step 7: Deploy ---
Write-Host "Deploying to $installDir..." -ForegroundColor Yellow
# Copy new binaries over the old ones
$binDir = "$sourceDir\build\bin"
if (Test-Path "$binDir\llama-server.exe") {
    # Backup old binaries
    $backupDir = "$installDir\backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item "$installDir\*.exe" $backupDir -ErrorAction SilentlyContinue
    Copy-Item "$installDir\*.dll" $backupDir -ErrorAction SilentlyContinue
    Write-Host "Old binaries backed up to $backupDir" -ForegroundColor DarkGray

    # Copy new binaries
    Copy-Item "$binDir\*.exe" $installDir -Force
    Copy-Item "$binDir\*.dll" $installDir -Force
    Write-Host "New binaries deployed to $installDir" -ForegroundColor Green
} else {
    Write-Host "ERROR: llama-server.exe not found in $binDir" -ForegroundColor Red
    Write-Host "Build output:" -ForegroundColor DarkGray
    Get-ChildItem "$binDir" -ErrorAction SilentlyContinue | Select-Object Name
    exit 1
}

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Green
Write-Host "New binaries with AVX-VNNI support are in: $installDir" -ForegroundColor Green
Write-Host "Run 'cd C:\Users\Paul; .\start-windows.cmd' to test." -ForegroundColor Green
Write-Host ""
Write-Host "Expected improvement: 10-30% from AVX-VNNI" -ForegroundColor Green
Write-Host "Current speed: 6.23 tok/s -> Expected: ~6.9-8.1 tok/s" -ForegroundColor Green
