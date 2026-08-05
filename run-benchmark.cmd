@echo off
REM run-benchmark.cmd — Quick benchmark for llama-server on Windows
REM Runs benchmark.ps1 with ExecutionPolicy bypass
echo.
echo === llama.cpp Benchmark (Intel N150) ===
echo.

REM Check if PowerShell script exists
if not exist "%~dp0benchmark.ps1" (
    echo ERROR: benchmark.ps1 not found in %~dp0
    exit /b 1
)

REM Run benchmark with bypass execution policy
powershell -ExecutionPolicy Bypass -File "%~dp0benchmark.ps1" %*

echo.
pause
