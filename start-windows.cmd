@echo off
REM
REM start-windows.cmd -- Run Gemma 4 26B-A4B on Windows natively via llama.cpp.
REM
REM This is the Windows counterpart to start-linux.sh / start-mac.sh. It mirrors
REM the same three modes and the same on-the-wire protocol (OpenAI-compatible
REM server on http://127.0.0.1:8080/v1) so Scripts/chat.py and the Pi agent config
REM work unchanged across platforms.
REM
REM Native Windows avoids WSL2's CPU throttling and memory limits. On an Intel
REM N150 test machine (800MHz, 11.7GB RAM), Windows native runs 6-7x faster
REM than WSL2:
REM   WSL2 (MADV_DONTNEED, 5.7GB RAM):  ~0.72 tok/s
REM   Windows native (11.7GB RAM):     ~4.61 tok/s
REM
REM The speedup comes from having twice as available RAM (11.7GB vs 5.7GB),
REM which lets the OS page cache hold most of the 14GB model. WSL2's 5.7GB
REM limit forces constant page eviction and expert re-reading from disk.
REM
REM Optimal configuration (discovered by benchmarking 15+ combinations):
REM   - Custom MSVC build with AVX-VNNI: +133% over pre-built (6.23 -> 14.56 tok/s)
REM   - WITH repack (reorganizes weights for faster matmul): +45% speed
REM   - 3 threads pinned to cores (cpu-strict 1 + cpu-range): +5-15% speed
REM   - q4_0 KV cache (less memory bandwidth than q8_0): +5% speed
REM   - ub 128 (micro-batch): optimal with Flash Attention
REM   - context 4096 for --ask/--chat: +40-50% tok/s vs 16384
REM   - n-gram speculative decoding (default ON): +15-25% on repetitive text
REM   - warm mode (default ON): keep server alive between sessions
REM
REM First launch takes ~90s for repack to complete. Subsequent launches
REM reuse the repacked weights from disk (faster init).
REM
REM Usage (in cmd.exe or PowerShell):
REM   start-windows.cmd                                  REM Pi coding agent (tool use)
REM   start-windows.cmd --chat                           REM interactive chat (ctx=4096)
REM   start-windows.cmd --ask "What is the capital of France?"
REM   start-windows.cmd --no-speculative                 REM disable speculation
REM   start-windows.cmd --no-warm                        REM don't keep server warm
REM   start-windows.cmd --chat --context 8192            REM explicit context size
REM
REM Environment overrides (set in PowerShell: $env:VAR = "value"):
REM   MODEL_PATH       GGUF model file
REM   LLAMA_DIR        llama.cpp directory
REM   CONTEXT_TOKENS   context window size   (default: 16384 for Pi, 4096 for ask/chat)
REM   SERVER_PORT      server listen port    (default 8080)
REM   GPU_LAYERS       GPU layers to offload (default 0 = CPU only)
REM   THREADS          CPU threads (default: auto-detect physical cores - 1)
REM

setlocal enabledelayedexpansion

REM --- Determine script directory ---
set "REPO_DIR=%~dp0"
set "REPO_DIR=%REPO_DIR:~0,-1%"

REM --- Auto-detect CPU threads (leave 1 core for OS on multi-core) ---
if not defined THREADS (
    REM Get logical processor count from environment (usually set by Windows)
    if defined NUMBER_OF_PROCESSORS (
        set /a "THREADS=NUMBER_OF_PROCESSORS - 1"
        if !THREADS! lss 1 set "THREADS=1"
    ) else (
        set "THREADS=3"
    )
)

REM --- Find llama-server.exe ---
if not defined LLAMA_DIR (
    REM Search common locations in priority order
    if exist "%REPO_DIR%\llama.cpp\build\bin\llama-server.exe" (
        set "LLAMA_DIR=%REPO_DIR%\llama.cpp\build\bin"
    ) else if exist "%REPO_DIR%\llama-b10242\llama-server.exe" (
        set "LLAMA_DIR=%REPO_DIR%\llama-b10242"
    ) else if exist "%REPO_DIR%\llama-b10219\llama-server.exe" (
        set "LLAMA_DIR=%REPO_DIR%\llama-b10219"
    ) else if exist "%REPO_DIR%\llama-*\llama-server.exe" (
        for /d %%D in ("%REPO_DIR%\llama-*") do (
            if exist "%%D\llama-server.exe" (
                set "LLAMA_DIR=%%D"
                goto :found_llama_dir
            )
        )
    ) else if exist "%USERPROFILE%\llama.cpp\build\bin\llama-server.exe" (
        set "LLAMA_DIR=%USERPROFILE%\llama.cpp\build\bin"
    ) else if exist "%USERPROFILE%\llama-b10242\llama-server.exe" (
        set "LLAMA_DIR=%USERPROFILE%\llama-b10242"
    ) else (
        REM Last resort: search in PATH
        for %%X in (llama-server.exe) do (
            set "LLAMA_DIR=%%~dpX"
            goto :found_llama_dir
        )
    )
)
:found_llama_dir

REM --- Find model GGUF ---
if not defined MODEL_PATH (
    REM Search for the Gemma 4 model in common locations
    for %%Q in (Q4_0 Q5_K_M Q8_0 Q3_K_S Q2_K) do (
        if exist "%REPO_DIR%\models\gemma*-%%Q.gguf" (
            for %%F in ("%REPO_DIR%\models\gemma*-%%Q.gguf") do (
                set "MODEL_PATH=%%F"
                goto :found_model
            )
        )
    )
    REM Also check user's home directory
    for %%Q in (Q4_0 Q5_K_M Q8_0 Q3_K_S Q2_K) do (
        if exist "%USERPROFILE%\models\gemma*-%%Q.gguf" (
            for %%F in ("%USERPROFILE%\models\gemma*-%%Q.gguf") do (
                set "MODEL_PATH=%%F"
                goto :found_model
            )
        )
    )
    REM Fallback: search any .gguf in models directory
    if exist "%REPO_DIR%\models\*.gguf" (
        for %%F in ("%REPO_DIR%\models\*.gguf") do (
            set "MODEL_PATH=%%F"
            goto :found_model
        )
    )
)
:found_model

if not defined CONTEXT_TOKENS set "CONTEXT_TOKENS=16384"
if not defined SERVER_PORT set "SERVER_PORT=8080"
if not defined GPU_LAYERS set "GPU_LAYERS=0"

set "LLAMA_SERVER=%LLAMA_DIR%\llama-server.exe"
set "SERVER_HOST=127.0.0.1"
set "API_BASE=http://%SERVER_HOST%:%SERVER_PORT%/v1"
set "MODE=pi"
set "ASK_PROMPT="
set "DEBUG=0"
set "SPECULATIVE=1"
set "CONTEXT_DEFAULT=1"
set "WARM=1"

REM --- Parse arguments ---
:parse_args
if "%~1"=="" goto :done_parse
if /i "%~1"=="--chat" (
    set "MODE=chat"
    shift
    goto :parse_args
)
if /i "%~1"=="--ask" (
    set "MODE=ask"
    shift
    if not "%~1"=="" (
        set "ASK_PROMPT=%~1"
        shift
    )
    goto :parse_args
)
if /i "%~1"=="--cpu" (
    set "GPU_LAYERS=0"
    shift
    goto :parse_args
)
if /i "%~1"=="--threads" (
    shift
    set "THREADS=%~1"
    shift
    goto :parse_args
)
if /i "%~1"=="--debug" (
    set "DEBUG=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--context" (
    shift
    set "CONTEXT_TOKENS=%~1"
    set "CONTEXT_DEFAULT=0"
    shift
    goto :parse_args
)
if /i "%~1"=="--speculative" (
    set "SPECULATIVE=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--no-speculative" (
    set "SPECULATIVE=0"
    shift
    goto :parse_args
)
if /i "%~1"=="--warm" (
    set "WARM=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--no-warm" (
    set "WARM=0"
    shift
    goto :parse_args
)
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help

REM Unknown arg - collect for pass-through
set "POSITIONAL_ARGS=%POSITIONAL_ARGS% %1"
shift
goto :parse_args

:done_parse

REM --- Apply mode-specific context defaults ---
REM --ask and --chat default to 4096 context for maximum speed (+40-50% tok/s).
REM Pi agent stays at 16384 for tool use. Users can override with --context N.
if "%CONTEXT_DEFAULT%"=="1" (
    if "%MODE%"=="ask" set "CONTEXT_TOKENS=4096"
    if "%MODE%"=="chat" set "CONTEXT_TOKENS=4096"
)

REM --- Validate llama-server exists ---
if not exist "%LLAMA_SERVER%" (
    echo ERROR: llama-server.exe not found.
    echo.
    echo Searched in:
    echo   - %%REPO_DIR%%\llama.cpp\build\bin\
    echo   - %%REPO_DIR%%\llama-b*/
    echo   - %%USERPROFILE%%\llama.cpp\build\bin\
    echo   - %%PATH%%
    echo.
    echo Set LLAMA_DIR to your llama.cpp binary directory, e.g.:
    echo   set LLAMA_DIR=C:\path\to\llama.cpp\build\bin
    echo   start-windows.cmd
    exit /b 1
)

REM --- Validate model exists ---
if not exist "%MODEL_PATH%" (
    echo ERROR: model GGUF not found.
    echo.
    echo Searched for gemma-*.gguf in:
    echo   - %%REPO_DIR%%\models\
    echo   - %%USERPROFILE%%\models\
    echo.
    echo Set MODEL_PATH to your GGUF file, e.g.:
    echo   set MODEL_PATH=C:\path\to\gemma-4-26B-A4B-it.Q4_0.gguf
    echo   start-windows.cmd
    exit /b 1
)

echo Starting llama.cpp + Gemma 4 ^(Windows Native^)...
echo   backend: %LLAMA_SERVER%
echo   model:   %MODEL_PATH%
echo   gpu layers: %GPU_LAYERS%  ^|  context: %CONTEXT_TOKENS%  ^|  threads: %THREADS%  ^|  port: %SERVER_PORT%

REM --- Build llama-server command line ---
REM Optimal config for CPU-only inference on Intel N150:
REM   - repack ON: reorganizes weights for 45% faster matmul (needs sufficient RAM)
REM   - auto threads: physical cores - 1 (leaves 1 core for OS/disk I/O)
REM   - q4_0 KV cache: less memory bandwidth than q8_0
REM   - ub 128: optimal micro-batch with Flash Attention
REM   - fa on: Flash Attention (2-2.5x at 16K context, b10242 syntax)
REM   - cpu-strict 1 + cpu-range 0-2: pin threads for ~5-15% speed gain
set "LLAMA_OPTS=-m "%MODEL_PATH%" -ngl %GPU_LAYERS% -c %CONTEXT_TOKENS% -t %THREADS% --host %SERVER_HOST% --port %SERVER_PORT%"

REM --- CPU optimization flags ---
REM cpu-strict 1 + cpu-range: pin threads to specific cores for +5-15% speed
REM (reduces cache misses vs letting OS scheduler migrate threads)
if "%GPU_LAYERS%"=="0" (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ctk q4_0 -ctv q4_0 -ub 128 -fa on --cpu-strict 1 --cpu-range 0-2"
)

REM --- Optional: n-gram speculative decoding (CPU-friendly, no second model) ---
REM Uses hash-based n-gram lookup to predict next tokens. On repetitive content
REM (code, structured text), achieves +15-25% throughput. Enable with --speculative.
if "%SPECULATIVE%"=="1" (
    set "LLAMA_OPTS=!LLAMA_OPTS! --spec-type ngram-mod --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64 --spec-draft-n-max 4"
)

REM --- Show active optimizations ---
echo.
echo Active optimizations:
if "%SPECULATIVE%"=="1" (
    echo   [ON] N-gram speculative decoding (ngram-mod)
) else (
    echo   [OFF] N-gram speculative decoding
)
if "%WARM%"=="1" (
    echo   [ON] Warm mode (server stays alive after client exits)
) else (
    echo   [OFF] Warm mode
)
echo   [ON] Thread pinning (cpu-strict 1, cpu-range 0-2)
echo   [ON] Flash Attention, q4_0 KV cache, ub 128
echo.

REM --- Expert cache: warm the OS file cache + warmup inference ---------------
# Measured on RTX 4050 + 11GB RAM + Q2_K Gemma 4 26B-A4B: the custom build
# MADV_DONTNEEDs expert pages after load, so the first inference is always cold
# (0.58 tok/s, ~480K page faults). The 2nd same-topic inference hits ~5 tok/s,
# and by the 3rd it is 17-18 tok/s with ZERO disk I/O. Two levers:
#   RAM_CACHE=1 (default): pre-read the model to warm the OS file cache.
#   WARMUP=1 (default): run a throwaway inference after load to heat the expert
#     cache before the user's first real query (turns 0.58 tok/s into 17-18 tok/s).
if not defined RAM_CACHE set "RAM_CACHE=1"
if "%RAM_CACHE%"=="1" (
    if exist "%MODEL_PATH%" (
        echo Preheating model into OS file cache ...
        powershell -NoProfile -Command "$s=New-Object System.IO.FileStream('%MODEL_PATH%','Open','Read','ReadWrite',67108864);$b=New-Object byte[] 67108864;while($s.Read($b,0,$b.Length)){};$s.Close()" >nul 2>&1
        if errorlevel 1 (
            echo   (preheat skipped -- could not read model file)
        )
    )
)

REM --- Start llama-server ---
echo Launching llama-server ...
echo Configuration: %LLAMA_OPTS%
REM Use START /B to launch the server in the background.
REM By default, redirect output to a log file to keep the console clean.
REM With --debug, output goes to the console window instead.
if "%DEBUG%"=="1" (
    echo Debug mode: server output is shown in the console.
    start "llama-server" /B "%LLAMA_SERVER%" %LLAMA_OPTS%
) else (
    start "llama-server" /B "%LLAMA_SERVER%" %LLAMA_OPTS% > "%REPO_DIR%\llama_server.log" 2>&1
)

REM --- Wait for server to be ready ---
echo Loading model weights ^(first launch takes ~90s for repack^)...
set "HEALTH_FILE=%TEMP%\llama_health.txt"
set /a ATTEMPTS=0
:wait_loop
REM Use temp file instead of pipe to avoid "Input redirection is not supported"
REM errors when running through WSL2 interop (cmd.exe interprets pipes before batch)
curl.exe -s -m 3 http://%SERVER_HOST%:%SERVER_PORT%/health -o "%HEALTH_FILE%" 2>nul
findstr /i "ok" "%HEALTH_FILE%" >nul 2>&1
if not errorlevel 1 goto :server_ready

timeout /t 2 /nobreak >nul
set /a ATTEMPTS+=1
if %ATTEMPTS%==10 echo   Still loading... (20s)
if %ATTEMPTS%==20 echo   Still loading... (40s)
if %ATTEMPTS%==30 echo   Still loading... (60s)
if %ATTEMPTS%==40 echo   Still loading... (80s)
if %ATTEMPTS%==50 echo   Still loading... (100s)
if %ATTEMPTS%==60 echo   Still loading... (120s)
if %ATTEMPTS% lss 90 goto :wait_loop

echo ERROR: Timed out waiting for llama-server to be ready.
echo Check the console window for error messages.
exit /b 1

:server_ready
echo Server ready on port %SERVER_PORT%.

REM --- Warmup inference: heat the expert cache --------------------------------
REM A throwaway inference after load heats the OS page cache with the active
REM experts, so the user's first REAL query runs at 17-18 tok/s instead of the
REM 0.58 tok/s cold-start. Disable with WARMUP=0.
if not defined WARMUP set "WARMUP=1"
if "%WARMUP%"=="1" (
    echo Warming up expert cache ^(throwaway inference^)...
    curl.exe -s -m 120 -X POST http://%SERVER_HOST%:%SERVER_PORT%/completion -H "Content-Type: application/json" -d "{\"prompt\":\"The\",\"n_predict\":1,\"temperature\":0}" >nul 2>&1
    echo Warmup done.
)

REM --- Launch appropriate client ---
REM --ask and --chat bypass the Pi agent entirely, connecting directly to
REM llama-server. This avoids the large Pi system prompt overhead (~2-3KB)
REM and gives faster responses for simple queries.
if "%MODE%"=="ask" (
    if "%ASK_PROMPT%"=="" (
        echo ERROR: --ask requires a prompt.
        exit /b 1
    )
    echo Asking Gemma 4: %ASK_PROMPT%
    echo.
    if exist "%REPO_DIR%\Scripts\chat.py" (
        python "%REPO_DIR%\Scripts\chat.py" --ask "%ASK_PROMPT%" --base-url "%API_BASE%"
    ) else (
        echo chat.py not found. Server is running at %API_BASE%
        echo Use curl or any OpenAI-compatible client to send requests.
    )
    goto :eof
)

if "%MODE%"=="chat" (
    echo Starting interactive chat with Gemma 4 ...
    echo.
    if exist "%REPO_DIR%\Scripts\chat.py" (
        python "%REPO_DIR%\Scripts\chat.py" --chat --base-url "%API_BASE%" %POSITIONAL_ARGS%
    ) else (
        echo chat.py not found. Server is running at %API_BASE%
        echo Use curl or any OpenAI-compatible client to send requests.
    )
    goto :eof
)

REM --- Default mode: start server, then launch Pi agent ---
echo.
echo Server is ready at http://%SERVER_HOST%:%SERVER_PORT%

REM --- Ensure pi models.json points at this server ---
set "PI_CONFIG_DIR=%USERPROFILE%\.pi\agent"
set "PI_MODELS_FILE=%PI_CONFIG_DIR%\models.json"
if not exist "%PI_CONFIG_DIR%" mkdir "%PI_CONFIG_DIR%"
if not exist "%PI_MODELS_FILE%" (
    echo Writing Pi agent config to %PI_MODELS_FILE%...
    echo {> "%PI_MODELS_FILE%"
    echo   "providers": {>> "%PI_MODELS_FILE%"
    echo     "turbofieldfare": {>> "%PI_MODELS_FILE%"
    echo       "name": "llama.cpp (Local Gemma 4)",>> "%PI_MODELS_FILE%"
    echo       "baseUrl": "http://%SERVER_HOST%:%SERVER_PORT%/v1",>> "%PI_MODELS_FILE%"
    echo       "api": "openai-completions",>> "%PI_MODELS_FILE%"
    echo       "apiKey": "local",>> "%PI_MODELS_FILE%"
    echo       "compat": {>> "%PI_MODELS_FILE%"
    echo         "supportsDeveloperRole": false,>> "%PI_MODELS_FILE%"
    echo         "supportsReasoningEffort": false>> "%PI_MODELS_FILE%"
    echo       },>> "%PI_MODELS_FILE%"
    echo       "models": [>> "%PI_MODELS_FILE%"
    echo         {>> "%PI_MODELS_FILE%"
    echo           "id": "gemma-4-26b-a4b-it",>> "%PI_MODELS_FILE%"
    echo           "name": "Gemma 4 26B-A4B IT (Local)",>> "%PI_MODELS_FILE%"
    echo           "reasoning": false,>> "%PI_MODELS_FILE%"
    echo           "input": ["text"],>> "%PI_MODELS_FILE%"
    echo           "contextWindow": 16384,>> "%PI_MODELS_FILE%"
    echo           "maxTokens": 8192,>> "%PI_MODELS_FILE%"
    echo           "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }>> "%PI_MODELS_FILE%"
    echo         }>> "%PI_MODELS_FILE%"
    echo       ]>> "%PI_MODELS_FILE%"
    echo     }>> "%PI_MODELS_FILE%"
    echo   }>> "%PI_MODELS_FILE%"
    echo }>> "%PI_MODELS_FILE%"
)

REM --- Launch Pi agent ---
echo Launching Pi agent...
echo.
set PI_SKIP_VERSION_CHECK=1
set PI_TELEMETRY=0
where pi >nul 2>&1
if not errorlevel 1 (
    pi --model turbofieldfare/gemma-4-26b-a4b-it
    if "%WARM%"=="1" (
        echo.
        echo Pi agent exited. Server is still running (warm mode).
        echo Press any key to stop the server and exit...
        pause >nul
        echo Stopping server...
        taskkill /F /IM llama-server.exe >nul 2>&1
        echo Server stopped.
    )
    goto :eof
)

REM --- Pi not found: auto-install ---
echo Pi agent is not installed. Installing automatically...

REM --- Check for npm (needed to install Pi) ---
where npm >nul 2>&1
if errorlevel 1 (
    echo npm not found. Installing Node.js via winget...
    REM --force reinstalls even if already present (fixes broken installs)
    call winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent --force
    if errorlevel 1 (
        echo.
        echo ERROR: winget install failed. Install Node.js manually:
        echo   https://nodejs.org/
        echo   Then re-run this script.
        echo.
        echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
        goto :eof
    )
)

REM --- Find node.exe and add its directory to PATH ---
REM Check common install locations
set "NODE_DIR="
if exist "%ProgramFiles%\nodejs\node.exe" (
    set "NODE_DIR=%ProgramFiles%\nodejs"
) else if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" (
    set "NODE_DIR=%LOCALAPPDATA%\Programs\nodejs"
)

if defined NODE_DIR (
    set "PATH=%PATH%;!NODE_DIR!"
) else (
    echo.
    echo ERROR: Node.js installed but node.exe not found.
    echo   Close and reopen PowerShell, then re-run this script.
    echo.
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
    goto :eof
)

echo Installing Pi agent via npm...
call npm install -g --ignore-scripts @earendil-works/pi-coding-agent >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: npm install failed. Try installing manually:
    echo   npm install -g --ignore-scripts @earendil-works/pi-coding-agent
    echo.
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
    goto :eof
)

REM --- Launch Pi using the full path to node + pi script ---
REM npm -g installs to %APPDATA%\npm on Windows
set "PI_SCRIPT="
if exist "%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\bin\pi" (
    set "PI_SCRIPT=%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\bin\pi"
) else if exist "%APPDATA%\npm\pi.cmd" (
    REM Find the actual JS entry point
    for /f "tokens=*" %%a in ('dir /s /b "%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\*.js" 2^>nul ^| findstr /i "bin\\pi"') do (
        set "PI_SCRIPT=%%a"
    )
)

REM --- Launch Pi ---
REM npm installs pi as a PowerShell script (pi.ps1). If execution policy
REM blocks it, set RemoteSigned for the current user and retry.
echo Pi agent installed. Launching...
where pi >nul 2>&1
if not errorlevel 1 (
    pi --model turbofieldfare/gemma-4-26b-a4b-it
    if errorlevel 1 (
        echo.
        echo PowerShell execution policy may be blocking pi.
        echo Attempting to fix and retry...
        echo.
        powershell -Command "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force"
        pi --model turbofieldfare/gemma-4-26b-a4b-it
    )
) else (
    echo.
    echo ERROR: Pi agent installed but not found in PATH.
    echo   Try closing and reopening PowerShell, then run:
    echo   pi --model turbofieldfare/gemma-4-26b-a4b-it
    echo.
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
)
goto :eof

:show_help
echo Usage: %~nx0 [options]
echo.
echo Starts the llama.cpp Gemma 4 server/client on Windows.
echo.
echo Modes:
echo   (none)           Start server, then launch Pi coding agent (tool use)
echo   --ask "PROMPT"   Single-shot: ask a question, print the reply, exit
echo   --chat           Interactive chat REPL with conversation memory
echo.
echo Options:
echo   --context N      Context window size (default: 4096 for --ask/--chat, 16384 for Pi)
echo   --cpu            Force CPU-only mode (default)
echo   --debug          Show llama-server log output in the console (default: off)
echo   --speculative    Enable n-gram speculative decoding (default: on)
echo   --no-speculative Disable n-gram speculative decoding
echo   --threads N      CPU threads to use (default: NUMBER_OF_PROCESSORS - 1)
echo   --warm           Keep server running after client exits (default: on)
echo   --no-warm        Don't keep server running after client exits
echo   -h, --help       Show this help
echo.
echo --ask and --chat connect directly to llama-server, bypassing the Pi agent
echo entirely. This avoids the large Pi system prompt overhead (~2-3KB) and gives
echo faster responses for simple queries.
echo.
echo Speed tips:
echo   - Default context is 4096 for --ask/--chat (+40-50% tok/s vs 16384)
echo   - Thread pinning (--cpu-strict 1 + --cpu-range) adds +5-15%
echo   - Speculative decoding is ON by default (+15-25% on repetitive text)
echo   - Warm mode is ON by default (skip 10-90s model reload between sessions)
echo   - Use --context 16384 only when you genuinely need long context
echo   - Use --no-warm or --no-speculative to compare without optimizations
echo.
echo Environment overrides:
echo   MODEL_PATH       GGUF model file
echo   LLAMA_DIR        llama.cpp directory with llama-server.exe
echo   CONTEXT_TOKENS   context window size
echo   SERVER_PORT      server listen port    (default %SERVER_PORT%)
echo   THREADS          CPU threads (default: NUMBER_OF_PROCESSORS - 1)
echo.
echo Examples:
echo   %~nx0 --ask "What is the capital of France?"
echo   %~nx0 --chat
echo   %~nx0 --chat --no-speculative
echo   %~nx0 --ask "Explain quantum computing" --context 8192
echo   %~nx0 --no-warm
echo   %~nx0 --threads 8
echo   %~nx0 --chat --debug
goto :eof
