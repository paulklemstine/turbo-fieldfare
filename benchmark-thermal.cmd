@echo off
REM
REM benchmark-thermal.cmd — Benchmark wrapper with thermal management
REM
REM Sets optimal Windows power settings before running the benchmark,
REM then restores them after. This helps the Intel N150 (6W TDP) sustain
REM higher clocks by:
REM   1. Switching to High Performance power plan
REM   2. Disabling processor throttling (PROCTHROTTLEMAX=100)
REM   3. Optionally setting ThrottleStop power limits (PL1=10W)
REM
REM Without this, the N150 thermal-throttles from ~14 tok/s to ~2 tok/s
REM under sustained all-core load.
REM
REM Usage:
REM   benchmark-thermal.cmd                    Run with thermal management
REM   benchmark-thermal.cmd --no-throttlestop  Skip ThrottleStop (powercfg only)
REM   benchmark-thermal.cmd --ask              Pass --ask to benchmark.ps1
REM   benchmark-thermal.cmd --help             Show this help
REM
REM Requirements:
REM   - ThrottleStop (optional): https://www.techpowerup.com/download/techpowerup-throttlestop/
REM     Create a profile named "Benchmark" in ThrottleStop with:
REM       PL1=10W, PL2=15W, BD PROCHOT=unchecked
REM
REM Environment overrides:
REM   THERMAL_STOP_PATH   Path to ThrottleStop.exe
REM

setlocal enabledelayedexpansion

REM --- Determine script directory ---
REM %~dp0 may be a UNC path under WSL2 interop (e.g. \\wsl.localhost\...)
REM which cmd.exe can't use. In that case, cd to the script dir first.
pushd "%~dp0" 2>nul
if errorlevel 1 (
    REM UNC path — use the full path we already have
    set "REPO_DIR=%~dp0"
    set "REPO_DIR=%REPO_DIR:~0,-1%"
) else (
    for /f "delims=" %%D in ("%CD%") do set "REPO_DIR=%%D"
    popd
)
set "USE_THROTTLESTOP=1"
set "EXTRA_ARGS="

REM --- Parse arguments ---
:parse_args
if "%~1"=="" goto :done_parse
if /i "%~1"=="--no-throttlestop" (
    set "USE_THROTTLESTOP=0"
    shift
    goto :parse_args
)
if /i "%~1"=="--help" goto :show_help
REM Pass everything else to benchmark.ps1
set "EXTRA_ARGS=!EXTRA_ARGS! %1"
shift
goto :parse_args
:done_parse

echo.
echo === Benchmark with Thermal Management (Intel N150) ===
echo.

REM --- Save current power settings for restoration ---
echo Saving current power settings...
for /f "tokens=2 delims=:(" %%a in (
    'powercfg /getactivescheme'
) do set "OLD_SCHEME=%%a"
set "OLD_SCHEME=%OLD_SCHEME: =%"
echo   Active scheme: %OLD_SCHEME%

REM Parse the hex value from "Current AC Power Setting Index: 0x00000064"
REM The hex value is the last token on the line
for /f "tokens=*" %%a in (
    'powercfg /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 2^>nul ^| findstr /i "Current AC'
) do (
    for %%b in (%%a) do set "OLD_THROTTLE_MAX=%%b"
)
if not defined OLD_THROTTLE_MAX set "OLD_THROTTLE_MAX=0x00000064"
echo   Throttle max: %OLD_THROTTLE_MAX%

REM --- Step 1: Enable Ultimate Performance or High Performance ---
echo.
echo [1/3] Setting High Performance power plan...

REM Try Ultimate Performance first (best, but hidden by default)
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 2>nul
if errorlevel 1 (
    REM Ultimate Performance not available, use High Performance
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>nul
    if errorlevel 1 (
        echo   WARNING: Could not set High Performance plan.
        echo   Using current plan. Enable it manually in Power Options.
    ) else (
        echo   High Performance plan activated.
    )
) else (
    echo   Ultimate Performance plan activated.
)

REM --- Step 2: Disable processor throttling ---
echo.
echo [2/3] Disabling processor throttling...
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100
powercfg /setactive SCHEME_CURRENT
echo   Processor throttle set to 100%% (no throttling).

REM --- Step 3: Configure ThrottleStop (optional) ---
if "%USE_THROTTLESTOP%"=="1" (
    echo.
    echo [3/3] Configuring ThrottleStop power limits...

    REM Find ThrottleStop
    set "TS_PATH="
    if defined THERMAL_STOP_PATH (
        if exist "%THERMAL_STOP_PATH%" set "TS_PATH=%THERMAL_STOP_PATH%"
    )
    if not defined TS_PATH (
        REM Search common locations
        for %%p in (
            "%REPO_DIR%\ThrottleStop\ThrottleStop.exe"
            "%ProgramFiles%\ThrottleStop\ThrottleStop.exe"
            "%ProgramFiles(x86)%\ThrottleStop\ThrottleStop.exe"
            "%LOCALAPPDATA%\ThrottleStop\ThrottleStop.exe"
        ) do (
            if exist "%%~p" set "TS_PATH=%%~p"
        )
    )
    if not defined TS_PATH (
        REM Search PATH
        for %%X in (ThrottleStop.exe) do (
            set "TS_PATH=%%~dpX\ThrottleStop.exe"
        )
    )

    if defined TS_PATH (
        echo   Found: !TS_PATH!
        REM Kill any existing ThrottleStop instance
        taskkill /F /IM ThrottleStop.exe >nul 2>&1
        timeout /t 1 /nobreak >nul
        REM Launch ThrottleStop with "Benchmark" profile (must be pre-configured)
        start "" "!TS_PATH!" -L Benchmark
        timeout /t 2 /nobreak >nul
        echo   ThrottleStop launched with "Benchmark" profile.
        echo   ^(Make sure you created a "Benchmark" profile with PL1=10W^)
    ) else (
        echo   ThrottleStop not found ^(skipping^).
        echo   Download from: https://www.techpowerup.com/download/techpowerup-throttlestop/
        echo   Create a "Benchmark" profile: PL1=10W, PL2=15W, BD PROCHOT=off
    )
) else (
    echo.
    echo [3/3] Skipping ThrottleStop ^(--no-throttlestop^).
)

REM --- Run the benchmark ---
echo.
echo ============================================================
echo  Running benchmark with thermal optimizations active...
echo ============================================================
echo.

call "%REPO_DIR%\run-benchmark.cmd" %EXTRA_ARGS%
set "BENCH_EXIT=%ERRORLEVEL%"

REM --- Restore original settings ---
echo.
echo Restoring original power settings...
powercfg /setactive %OLD_SCHEME%
if defined OLD_THROTTLE_MAX (
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX %OLD_THROTTLE_MAX%
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX %OLD_THROTTLE_MAX%
)
powercfg /setactive SCHEME_CURRENT
echo   Power plan restored to original.
echo   Throttle max restored to %OLD_THROTTLE_MAX%.

REM Kill ThrottleStop if we started it
if "%USE_THROTTLESTOP%"=="1" (
    if defined TS_PATH (
        taskkill /F /IM ThrottleStop.exe >nul 2>&1
        echo   ThrottleStop closed.
    )
)

echo.
echo Done. Original settings restored.
pause
exit /b %BENCH_EXIT%

:show_help
echo Usage: %~nx0 [options]
echo.
echo Runs the llama-server benchmark with thermal management to help
echo the Intel N150 sustain higher clocks under sustained load.
echo.
echo Options:
echo   --no-throttlestop    Skip ThrottleStop (use powercfg only)
echo   --ask                Pass --ask to benchmark.ps1
echo   --help               Show this help
echo.
echo Any other arguments are passed through to benchmark.ps1.
echo.
echo What it does:
echo   1. Switches to High Performance (or Ultimate Performance) power plan
echo   2. Sets processor throttle to 100%% (no OS-level throttling)
echo   3. Optionally launches ThrottleStop with a "Benchmark" profile
echo   4. Runs the benchmark
echo   5. Restores original power settings on exit
echo.
echo ThrottleStop setup (one-time):
echo   1. Download from https://www.techpowerup.com/throttlestop/
echo   2. Create a profile named "Benchmark"
echo   3. Set PL1=10W, PL2=15W, uncheck BD PROCHOT
echo   4. This wrapper will auto-launch it during benchmarks
echo.
echo Environment:
echo   THERMAL_STOP_PATH    Path to ThrottleStop.exe ^(if not in standard locations^)
goto :eof
