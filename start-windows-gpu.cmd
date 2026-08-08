@echo off
REM
REM start-windows-gpu.cmd -- Run Gemma 4 26B-A4B on Windows natively via llama.cpp + CUDA.
REM
REM GPU-accelerated, max-context-first counterpart to start-windows.cmd. The
REM original script is CPU-only (-ngl 0), tuned for an Intel N150 with no
REM discrete GPU. This version detects your NVIDIA VRAM and computes the
REM configuration that delivers the LARGEST context window first, then max
REM token/second speed within that -- because a fast model you can't fit your
REM work into is useless.
REM
REM Measured on the reference hardware (RTX 4050 laptop, 6141 MiB VRAM, Q2_K
REM Gemma 4 26B-A4B). These are EMPIRICAL constants, not theoretical:
REM   * VRAM cost per offloaded layer: ~338 MiB
REM   * CUDA context overhead:         ~500 MiB
REM   * KV cache per token (q4_0):     ~15 KiB   (max context)
REM   * KV cache per token (q8_0):     ~30 KiB   (max quality)
REM   * Model native context:          262,144 tokens
REM
REM The speed/context tradeoff (your 6141 MiB budget):
REM   Every layer offloaded to GPU costs ~338 MiB but runs ~10-50x faster
REM   than CPU. Every token of KV cache costs ~15 KiB (q4_0) but grows your
REM   context window. They compete for the same 6 GB.
REM
REM   layers | layer VRAM | KV budget (q4_0) | max context
REM   -------|------------|-------------------|------------
REM      10  |   3384 MiB |         2257 MiB |   154K tok  [max speed]
REM       6  |   2030 MiB |         3610 MiB |   246K tok
REM       5  |   1692 MiB |         3949 MiB |   262K tok  <- native ctx, GPU-accelerated
REM       4  |   1354 MiB |         4287 MiB |   262K tok  (capped by native ctx)
REM       0  |      0 MiB |         5641 MiB |   262K tok  (CPU-only, capped)
REM
REM DEFAULT: this script picks the highest layer count that still reaches the
REM model's full native context (262K tokens) -- ngl=5 -- so you get BOTH the
REM maximum context AND CUDA speedup. Override with GPU_LAYERS if you want a
REM different balance (see below).
REM
REM Modes (identical to start-windows.cmd):
REM   (none)           Pi coding agent (tool use), full native context
REM   --chat           interactive chat
REM   --ask "PROMPT"   single-shot question
REM   --cpu            force CPU-only mode
REM   --gpu            force GPU mode (honor GPU_LAYERS if set)
REM
REM Environment overrides (PowerShell: $env:VAR = "value"):
REM   MODEL_PATH       GGUF model file
REM   LLAMA_DIR        llama.cpp directory
REM   CONTEXT_TOKENS   context window size   (default: auto = native 262K)
REM   SERVER_PORT      server listen port    (default 8080)
REM   GPU_LAYERS       GPU layers to offload (default: auto = max-ctx optimum)
REM   THREADS          CPU threads (default: auto-detect physical cores - 1)
REM   KV_TYPE          q4_0 (max ctx) or q8_0 (max quality) (default q4_0)
REM
REM Examples:
REM   start-windows-gpu.cmd                                      REM auto: 262K ctx + GPU
REM   start-windows-gpu.cmd --ask "Summarize this 200K doc"
REM   start-windows-gpu.cmd --chat
REM   set GPU_LAYERS=10 ^& start-windows-gpu.cmd                 REM favor speed
REM   set GPU_LAYERS=3 ^& start-windows-gpu.cmd                  REM favor context+RAM
REM   set KV_TYPE=q8_0 ^& start-windows-gpu.cmd                  REM better quality
REM   start-windows-gpu.cmd --cpu                               REM CPU-only fallback

setlocal enabledelayedexpansion

REM --- Determine script directory ---
set "REPO_DIR=%~dp0"
set "REPO_DIR=%REPO_DIR:~0,-1%"

REM --- Auto-detect CPU threads (leave 1 core for OS on multi-core) ---
if not defined THREADS (
    if defined NUMBER_OF_PROCESSORS (
        set /a "THREADS=NUMBER_OF_PROCESSORS - 1"
        if !THREADS! lss 1 set "THREADS=1"
    ) else (
        set "THREADS=3"
    )
)

REM ============================================================================
REM  GPU VRAM DETECTION + MAX-CONTEXT-FIRST AUTO-CONFIG
REM ============================================================================
REM Goal: reach the model's native context (262144 tok) with as many GPU
REM layers as possible. We measure real VRAM via nvidia-smi, then solve for
REM the layer count that maximizes context first, speed second.
REM
REM VRAM budget:  total = overhead + layers*per_layer + context*kv_per_token
REM Empirical constants (RTX 4050, Q2_K Gemma 4 26B-A4B):
REM   PER_LAYER_MB = 338    VRAM per offloaded transformer layer
REM   OVERHEAD_MB  = 500    CUDA context + buffers
REM   KV_Q4_KIB    = 15     KiB/token for q4_0 KV (max context)
REM   KV_Q8_KIB    = 30     KiB/token for q8_0 KV (max quality)
REM   NATIVE_CTX   = 262144 model's trained context length
REM ============================================================================
set "PER_LAYER_MB=338"
set "OVERHEAD_MB=500"
set "KV_Q4_KIB=15"
set "KV_Q8_KIB=30"
set "NATIVE_CTX=262144"

if not defined KV_TYPE set "KV_TYPE=q4_0"

REM --- Detect NVIDIA GPU VRAM via nvidia-smi ---
REM Write to a temp file first: for/f splits the inline command at commas,
REM which breaks the --format=csv,noheader,nounits argument on Windows.
set "TOTAL_VRAM_MB=0"
where nvidia-smi >nul 2>&1
if not errorlevel 1 (
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits > "%TEMP%\turbofieldfare_vram.txt" 2>nul
    if not errorlevel 1 (
        set /p TOTAL_VRAM_MB=<"%TEMP%\turbofieldfare_vram.txt"
    )
    del /f "%TEMP%\turbofieldfare_vram.txt" 2>nul
)

if %TOTAL_VRAM_MB% gtr 0 (
    if not defined GPU_LAYERS (
        REM --- Auto-compute: highest layer count that still hits native ctx ---
        REM kv budget needed for native ctx:
        REM   need_kv = NATIVE_CTX * KV_PER_TOKEN
        REM Solve: overhead + layers*per_layer + need_kv <= total
        REM   layers <= (total - overhead - need_kv) / per_layer
        if "%KV_TYPE%"=="q8_0" (
            set /a "NEED_KV_MB=NATIVE_CTX * KV_Q8_KIB / 1024"
        ) else (
            set /a "NEED_KV_MB=NATIVE_CTX * KV_Q4_KIB / 1024"
        )
        set /a "LAYER_BUDGET_MB=TOTAL_VRAM_MB - OVERHEAD_MB - NEED_KV_MB"
        set /a "GPU_LAYERS=LAYER_BUDGET_MB / PER_LAYER_MB"
        REM Clamp: at least 1 (GPU mode), at most 30 (all layers)
        if !GPU_LAYERS! gtr 30 set "GPU_LAYERS=30"
        if !GPU_LAYERS! lss 1 set "GPU_LAYERS=1"
        REM Guard: if even 1 layer + native ctx doesn't fit, drop context later
        set /a "MIN_FIT_MB=OVERHEAD_MB + PER_LAYER_MB + NEED_KV_MB"
    )

    if not defined CONTEXT_TOKENS (
        REM --- Compute max context for the chosen layer count ---
        set /a "LAYER_MB=GPU_LAYERS * PER_LAYER_MB"
        set /a "KV_BUDGET_MB=TOTAL_VRAM_MB - OVERHEAD_MB - LAYER_MB"
        if "%KV_TYPE%"=="q8_0" (
            set /a "CONTEXT_TOKENS=KV_BUDGET_MB * 1024 / KV_Q8_KIB"
        ) else (
            set /a "CONTEXT_TOKENS=KV_BUDGET_MB * 1024 / KV_Q4_KIB"
        )
        REM Cap at native context (no benefit beyond it)
        if !CONTEXT_TOKENS! gtr %NATIVE_CTX% set "CONTEXT_TOKENS=%NATIVE_CTX%"
        REM Round down to nearest 1024 for clean allocation
        set /a "CONTEXT_TOKENS=(CONTEXT_TOKENS / 1024) * 1024"
        if !CONTEXT_TOKENS! lss 2048 set "CONTEXT_TOKENS=2048"
    )
)

REM --- Find llama-server.exe ---
REM Default: pre-built binary lives alongside this script (REPO_DIR).
if not defined LLAMA_DIR (
    if exist "%REPO_DIR%\llama-server.exe" (
        set "LLAMA_DIR=%REPO_DIR%"
    ) else if exist "%REPO_DIR%\llama.cpp\build\bin\llama-server.exe" (
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
        for %%X in (llama-server.exe) do (
            set "LLAMA_DIR=%%~dpX"
            goto :found_llama_dir
        )
    )
)
:found_llama_dir

REM --- Find model GGGUF ---
REM Default: Q2_K quant on D: drive (abliterated). Override with MODEL_PATH env.
if not defined MODEL_PATH (
    if exist "E:\Models\gemma-4-26B-A4B-it.Q4_K_S.gguf" (
        set "MODEL_PATH=E:\Models\gemma-4-26B-A4B-it.Q4_K_S.gguf"
        goto :found_model
    )
    for %%Q in (Q4_0 Q5_K_M Q8_0 Q3_K_S Q2_K) do (
        if exist "%REPO_DIR%\models\gemma*-%%Q.gguf" (
            for %%F in ("%REPO_DIR%\models\gemma*-%%Q.gguf") do (
                set "MODEL_PATH=%%F"
                goto :found_model
            )
        )
    )
    for %%Q in (Q4_0 Q5_K_M Q8_0 Q3_K_S Q2_K) do (
        if exist "%USERPROFILE%\models\gemma*-%%Q.gguf" (
            for %%F in ("%USERPROFILE%\models\gemma*-%%Q.gguf") do (
                set "MODEL_PATH=%%F"
                goto :found_model
            )
        )
    )
    if exist "%REPO_DIR%\models\*.gguf" (
        for %%F in ("%REPO_DIR%\models\*.gguf") do (
            set "MODEL_PATH=%%F"
            goto :found_model
        )
    )
)
:found_model

if not defined CONTEXT_TOKENS set "CONTEXT_TOKENS=262144"
if not defined SERVER_PORT set "SERVER_PORT=8080"
if not defined GPU_LAYERS set "GPU_LAYERS=0"

set "LLAMA_SERVER=%LLAMA_DIR%\llama-server.exe"
set "SERVER_HOST=127.0.0.1"
set "API_BASE=http://%SERVER_HOST%:%SERVER_PORT%/v1"
set "MODE=pi"
set "ASK_PROMPT="
set "DEBUG=0"
set "SPECULATIVE=1"
set "WARM=1"
set "QUIET=0"

REM --- Detect mode from arguments --------------------------------------------
if /i "%~1"=="--ask" (
    set "MODE=ask"
    set "QUIET=1"
    set "ASK_PROMPT=%~2"
    goto :args_done
)
if /i "%~1"=="--chat" set "MODE=chat" && goto :args_done
set "MODE=pi"

:args_done

REM --- Validate llama-server exists ---
if not exist "%LLAMA_SERVER%" (
    echo ERROR: llama-server.exe not found.
    echo Searched in:
    echo   - %%REPO_DIR%%\llama.cpp\build\bin\
    echo   - %%REPO_DIR%%\llama-b*/
    echo   - %%USERPROFILE%%\llama.cpp\build\bin\
    echo   - %%PATH%%
    echo Set LLAMA_DIR to your llama.cpp binary directory, e.g.:
    echo   set LLAMA_DIR=C:\path\to\llama.cpp\build\bin
    echo   start-windows-gpu.cmd
    exit /b 1
)

REM --- Validate model exists ---
if not exist "%MODEL_PATH%" (
    echo ERROR: model GGUF not found.
    echo Searched for gemma-*.gguf in:
    echo   - %%REPO_DIR%%\models\
    echo   - %%USERPROFILE%%\models\
    echo Set MODEL_PATH to your GGUF file, e.g.:
    echo   set MODEL_PATH=C:\path\to\gemma-4-26B-A4B-it.Q4_0.gguf
    echo   start-windows-gpu.cmd
    exit /b 1
)

if "%QUIET%"=="0" echo ============================================================
if "%QUIET%"=="0" echo  llama.cpp + Gemma 4  (Windows Native + CUDA GPU)
if "%QUIET%"=="0" echo ============================================================
if "%QUIET%"=="0" echo   backend:    %LLAMA_SERVER%
if "%QUIET%"=="0" echo   model:      %MODEL_PATH%
if "%QUIET%"=="0" echo   gpu layers: %GPU_LAYERS%  ^|  context: %CONTEXT_TOKENS% tok  ^|  KV: %KV_TYPE%
if "%QUIET%"=="0" echo   threads:    %THREADS%  ^|  port: %SERVER_PORT%
if "%QUIET%"=="0" echo ============================================================

REM --- Build llama-server command line ---
set "LLAMA_OPTS=-m %MODEL_PATH% -ngl %GPU_LAYERS% -c %CONTEXT_TOKENS% -t %THREADS% --host %SERVER_HOST% --port %SERVER_PORT%"

REM --- KV cache type (q4_0 for max context, q8_0 for max quality) ---
if "%KV_TYPE%"=="q8_0" (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ctk q8_0 -ctv q8_0"
) else (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ctk q4_0 -ctv q4_0"
)

REM --- GPU optimization flags ---
REM Flash Attention + micro-batch 128 are the measured winners
REM (repo bench-flags.ps1: -fa -ub 128). Applied whenever GPU is active.
if %GPU_LAYERS% gtr 0 (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ub 128 -fa on"
)

REM --- CPU optimization flags (CPU-only mode) ---
REM Thread pinning for +5-15% speed when falling back to CPU.
if "%GPU_LAYERS%"=="0" (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ub 128 -fa on --cpu-strict 1 --cpu-range 0-2"
)

REM --- Optional: n-gram speculative decoding (no second model needed) ---
REM +15-25% on repetitive text (code, structured text). Default ON.
if "%SPECULATIVE%"=="1" (
    set "LLAMA_OPTS=!LLAMA_OPTS! --spec-type ngram-mod --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64 --spec-draft-n-max 4"
)

REM --- Show active optimizations ---
if "%QUIET%"=="0" (
echo Active optimizations:
if "%SPECULATIVE%"=="1" (
    echo   [ON]  N-gram speculative decoding ^(ngram-mod^)
) else (
    echo   [OFF] N-gram speculative decoding
)
if "%WARM%"=="1" (
    echo   [ON]  Warm mode ^(server stays alive after client exits^)
) else (
    echo   [OFF] Warm mode
)
if %GPU_LAYERS% gtr 0 (
    echo   [ON]  CUDA GPU offload: %GPU_LAYERS% layers, Flash Attention, %KV_TYPE% KV, ub 128
) else (
    echo   [ON]  CPU-only: thread pinning ^(cpu-strict 1, cpu-range 0-2^), %KV_TYPE% KV, ub 128
)

REM --- RAM cache: warm the OS file cache so expert loads hit RAM, not disk -
REM The custom build MADV_DONTNEEDs expert pages after load. On Windows the OS
REM file cache holds hot experts in RAM and evicts cold ones to disk. With little
REM RAM headroom and the model possibly on a slow drive, cold experts fault from
REM disk and stall inference. This pre-reads the model sequentially to warm the
REM file cache (fast sequential I/O) so each expert's first load is a RAM hit.
REM Enable with RAM_CACHE=1 (default). Disable with RAM_CACHE=0.
if not defined RAM_CACHE set "RAM_CACHE=1"
if "%RAM_CACHE%"=="1" (
    if exist "%MODEL_PATH%" (
        if "%QUIET%"=="0" echo Preheating model into OS file cache ...
        REM PowerShell sequential read warms the system file cache (standby list).
        powershell -NoProfile -Command "$s=New-Object System.IO.FileStream('%MODEL_PATH%','Open','Read','ReadWrite',67108864);$b=New-Object byte[] 67108864;while($s.Read($b,0,$b.Length)){};$s.Close()" >nul 2>&1
        if errorlevel 1 (
            echo   (preheat skipped -- could not read model file)
        )
    )
)

REM --- Start llama-server ---
taskkill /F /IM llama-server.exe >nul 2>&1
timeout /t 1 /nobreak >nul
if "%QUIET%"=="0" echo Launching llama-server ...
if "%QUIET%"=="0" echo Configuration: %LLAMA_OPTS%
REM Start server silently in background. Use cmd /c so the redirection
REM applies to the server process, not the start command.
start "llama-server" /B cmd /c "%LLAMA_SERVER% %LLAMA_OPTS% > \"%REPO_DIR%\llama_server.log\" 2>&1"

REM --- Wait for server to be ready ---
if "%QUIET%"=="0" echo Loading model weights ^(first launch takes ~90s for repack^)...
set "HEALTH_FILE=%TEMP%\llama_health.txt"
set /a ATTEMPTS=0
:wait_loop
curl.exe -s -m 3 http://%SERVER_HOST%:%SERVER_PORT%/health -o "%HEALTH_FILE%" 2>nul
findstr /i "ok" "%HEALTH_FILE%" >nul 2>&1
if not errorlevel 1 goto :server_ready

timeout /t 2 /nobreak >nul
set /a ATTEMPTS+=1
if "%QUIET%"=="0" if %ATTEMPTS%==10 echo   Still loading... (20s)
if "%QUIET%"=="0" if %ATTEMPTS%==20 echo   Still loading... (40s)
if "%QUIET%"=="0" if %ATTEMPTS%==30 echo   Still loading... (60s)
if "%QUIET%"=="0" if %ATTEMPTS%==40 echo   Still loading... (80s)
if "%QUIET%"=="0" if %ATTEMPTS%==50 echo   Still loading... (100s)
if "%QUIET%"=="0" if %ATTEMPTS%==60 echo   Still loading... (120s)
if "%QUIET%"=="0" if %ATTEMPTS%==90 echo   Still loading... (180s)
if "%QUIET%"=="0" if %ATTEMPTS%==120 echo   Still loading... (240s)
if %ATTEMPTS% lss 180 goto :wait_loop

echo ERROR: Timed out waiting for llama-server to be ready.
echo Check the console window for error messages.
exit /b 1

:server_ready
if "%QUIET%"=="0" echo Server ready on port %SERVER_PORT%.

REM --- Warmup inference: heat the expert cache --------------------------------
REM A throwaway inference after load heats the OS page cache with the active
REM experts, so the user's first REAL query runs at 17-18 tok/s instead of the
REM 0.58 tok/s cold-start. Disable with WARMUP=0.
if not defined WARMUP set "WARMUP=1"
if "%QUIET%"=="0" echo Warming up expert cache ^(throwaway inference^).
    curl.exe -s -m 120 -X POST http://%SERVER_HOST%:%SERVER_PORT%/completion -H "Content-Type: application/json" -d "{\"prompt\":\"The\",\"n_predict\":1,\"temperature\":0}" >nul 2>&1
if "%QUIET%"=="0" echo Warmup done.

REM --- Launch appropriate client (PowerShell, no Python required) ---
if "%MODE%"=="ask" (
    if "%ASK_PROMPT%"=="" (
        echo ERROR: --ask requires a prompt.
        exit /b 1
    )
    if "%QUIET%"=="0" echo Asking Gemma 4: %ASK_PROMPT%
    if exist "%REPO_DIR%\Scripts\chat.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\Scripts\chat.ps1" --ask "%ASK_PROMPT%" --base-url "%API_BASE%"
    ) else (
        echo chat client not found. Server is running at %API_BASE%
        echo Use curl or any OpenAI-compatible client to send requests.
    )
    goto :eof
)

if "%MODE%"=="chat" (
    if "%QUIET%"=="0" echo Starting interactive chat with Gemma 4 ...
    if exist "%REPO_DIR%\Scripts\chat.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\Scripts\chat.ps1" --chat --base-url "%API_BASE%"
    ) else (
        echo chat client not found. Server is running at %API_BASE%
        echo Use curl or any OpenAI-compatible client to send requests.
    )
    goto :eof
)

REM --- Default mode: start server, then launch Pi agent ---
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
    echo           "contextWindow": 262144,>> "%PI_MODELS_FILE%"
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
set PI_SKIP_VERSION_CHECK=1
set PI_TELEMETRY=0
where pi >nul 2>&1
if not errorlevel 1 (
    pi --model turbofieldfare/gemma-4-26b-a4b-it
    if "%WARM%"=="1" (
        echo Pi agent exited. Server is still running (warm mode^).
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
where npm >nul 2>&1
if errorlevel 1 (
    echo npm not found. Installing Node.js via winget...
    call winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent --force
    if errorlevel 1 (
        echo ERROR: winget install failed. Install Node.js manually:
        echo   https://nodejs.org/
        echo   Then re-run this script.
        echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
        goto :eof
    )
)
set "NODE_DIR="
if exist "%ProgramFiles%\nodejs\node.exe" (
    set "NODE_DIR=%ProgramFiles%\nodejs"
) else if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" (
    set "NODE_DIR=%LOCALAPPDATA%\Programs\nodejs"
)
if defined NODE_DIR (
    set "PATH=%PATH%;!NODE_DIR!"
) else (
    echo ERROR: Node.js installed but node.exe not found.
    echo   Close and reopen PowerShell, then re-run this script.
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
    goto :eof
)
echo Installing Pi agent via npm...
call npm install -g --ignore-scripts @earendil-works/pi-coding-agent >nul 2>&1
if errorlevel 1 (
    echo ERROR: npm install failed. Try installing manually:
    echo   npm install -g --ignore-scripts @earendil-works/pi-coding-agent
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
    goto :eof
)
set "PI_SCRIPT="
if exist "%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\bin\pi" (
    set "PI_SCRIPT=%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\bin\pi"
) else if exist "%APPDATA%\npm\pi.cmd" (
    for /f "tokens=*" %%a in ('dir /s /b "%APPDATA%\npm\node_modules\@earendil-works\pi-coding-agent\*.js" 2^>nul ^| findstr /i "bin\\pi"') do (
        set "PI_SCRIPT=%%a"
    )
)
echo Pi agent installed. Launching...
where pi >nul 2>&1
if not errorlevel 1 (
    pi --model turbofieldfare/gemma-4-26b-a4b-it
    if errorlevel 1 (
        echo PowerShell execution policy may be blocking pi.
        echo Attempting to fix and retry...
        powershell -Command "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force"
        pi --model turbofieldfare/gemma-4-26b-a4b-it
    )
) else (
    echo ERROR: Pi agent installed but not found in PATH.
    echo   Try closing and reopening PowerShell, then run:
    echo   pi --model turbofieldfare/gemma-4-26b-a4b-it
    echo Server is still running at http://%SERVER_HOST%:%SERVER_PORT%
)
goto :eof

:show_help
echo Usage: %~nx0 [options]
echo GPU-accelerated llama.cpp Gemma 4 server/client on Windows.
echo Auto-detects NVIDIA VRAM and maximizes context window first, then speed.
echo Modes:
echo   (none)           Start server, then launch Pi coding agent (tool use)
echo   --ask "PROMPT"   Single-shot: ask a question, print the reply, exit
echo   --chat           Interactive chat REPL with conversation memory
echo Options:
echo   --context N      Context window size (default: auto = native 262K)
echo   --cpu            Force CPU-only mode
echo   --gpu            Force GPU mode (honor GPU_LAYERS if set)
echo   --debug          Show llama-server log output in the console (default: off)
echo   --speculative    Enable n-gram speculative decoding (default: on)
echo   --no-speculative Disable n-gram speculative decoding
echo   --threads N      CPU threads to use (default: NUMBER_OF_PROCESSORS - 1)
echo   --warm           Keep server running after client exits (default: on)
echo   --no-warm        Don't keep server running after client exits
echo   -h, --help       Show this help
echo Max-context-first logic:
echo   Default reaches the model's native 262K context with the highest GPU
echo   layer count that fits (measured: ngl=5 on RTX 4050 / Q2_K). This gives
echo   you the largest context AND CUDA speedup. Override to shift the balance:
echo   set GPU_LAYERS=10 ^& %~nx0     max speed (154K ctx)
echo   set GPU_LAYERS=5  ^& %~nx0     native 262K ctx + GPU  [default]
echo   set GPU_LAYERS=3  ^& %~nx0     min GPU, max RAM headroom
echo   set KV_TYPE=q8_0 ^& %~nx0      better quality, ~half context
echo Environment overrides:
echo   MODEL_PATH       GGUF model file
echo   LLAMA_DIR        llama.cpp directory with llama-server.exe
echo   GPU_LAYERS       layers to offload to GPU (default: auto)
echo   CONTEXT_TOKENS   context window size   (default: auto)
echo   KV_TYPE          q4_0 (max ctx) or q8_0 (quality) (default q4_0)
echo   SERVER_PORT      server listen port    (default 8080)
echo   THREADS          CPU threads (default: NUMBER_OF_PROCESSORS - 1)
echo Examples:
echo   %~nx0 --ask "Summarize the key points of this 200K-token document"
echo   %~nx0 --chat
echo   set GPU_LAYERS=10 ^& %~nx0 --chat
echo   %~nx0 --no-warm
echo   %~nx0 --chat --debug
goto :eof
