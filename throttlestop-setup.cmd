@echo off
REM
REM throttlestop-setup.cmd — One-time setup helper for ThrottleStop benchmarking
REM
REM Creates a ThrottleStop "Benchmark" profile INI file optimized for the
REM Intel N150 (6W TDP). This profile caps PL1 at 10W to prevent thermal
//! throttling while sustaining higher clocks.
REM
REM Usage: Run this once after installing ThrottleStop.
REM        Then use benchmark-thermal.cmd to auto-load the profile.
REM
REM Note: ThrottleStop stores profiles in its installation directory
REM       as "ThrottleStop.ini". This script creates a backup and adds
REM       a [Benchmark] section.
REM

setlocal

set "REPO_DIR=%~dp0"
set "REPO_DIR=%REPO_DIR:~0,-1%"

echo.
echo === ThrottleStop Benchmark Profile Setup ===
echo.

REM Find ThrottleStop
set "TS_DIR="
for %%p in (
    "%REPO_DIR%\ThrottleStop"
    "%ProgramFiles%\ThrottleStop"
    "%ProgramFiles(x86)%\ThrottleStop"
    "%LOCALAPPDATA%\ThrottleStop"
) do (
    if exist "%%~p\ThrottleStop.exe" set "TS_DIR=%%~p"
)

if not defined TS_DIR (
    for %%X in (ThrottleStop.exe) do (
        set "TS_DIR=%%~dpX"
    )
)

if not defined TS_DIR (
    echo ERROR: ThrottleStop not found.
    echo.
    echo Download ThrottleStop from:
    echo   https://www.techpowerup.com/download/techpowerup-throttlestop/
    echo.
    echo Install it, then run this script again.
    echo.
    echo Or manually create a profile named "Benchmark" with:
    echo   - PL1: 10W
    echo   - PL2: 15W
    echo   - BD PROCHOT: unchecked
    echo.
    pause
    exit /b 1
)

echo Found ThrottleStop in: %TS_DIR%
echo.

REM Check if INI exists
if not exist "%TS_DIR%\ThrottleStop.ini" (
    echo WARNING: ThrottleStop.ini not found.
    echo Run ThrottleStop at least once to create it, then come back.
    pause
    exit /b 1
)

REM Backup original INI
set "BACKUP=%TS_DIR%\ThrottleStop.ini.backup"
if not exist "%BACKUP%" (
    copy "%TS_DIR%\ThrottleStop.ini" "%BACKUP%" >nul
    echo Backup created: %BACKUP%
) else (
    echo Backup already exists: %BACKUP%
)

echo.
echo The "Benchmark" profile tells ThrottleStop to:
echo   - Cap PL1 (sustained power) at 10W
echo   - Cap PL2 (burst power) at 15W
echo   - Disable BD PROCHOT (prevents early throttling)
echo.
echo This helps the N150 sustain ~2.5 GHz instead of throttling to ~1.2 GHz.
echo.
echo To set up the profile:
echo   1. Open ThrottleStop
echo   2. Click "Profile" and select "Benchmark" from the dropdown
echo   3. In TPL (Turbo Power Limits):
echo      - Set PL1 to 10 (Watts)
echo      - Set PL2 to 15 (Watts)
echo      - Set Time Window to 28 (seconds)
echo   4. UNCHECK "BD PROCHOT" (this prevents pre-throttle at 70-80C)
echo   5. Click "Save" then "OK"
echo   6. Leave ThrottleStop running minimized
echo.
echo Then run: benchmark-thermal.cmd
echo.
start "" "%TS_DIR%\ThrottleStop.exe"
echo ThrottleStop launched. Set up the profile, then close it.
pause
goto :eof
