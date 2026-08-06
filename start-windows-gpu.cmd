@echo off
REM
REM start-windows-gpu.cmd — Run Gemma 4 26B-A4B on Windows natively via llama.cpp + CUDA.
REM
REM GPU-accelerated, max-context-first counterpart to start-windows.cmd. The
REM original script is CPU-only (-ngl 0), tuned for an Intel N150 with no
REM discrete GPU. This version detects your NVIDIA VRAM and computes the
REM configuration that delivers the LARGEST context window first, then max
REM token/second speed within that — because a fast model you can't fit your
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
REM model's full native context (262K tokens) — ngl=5 — so you get BOTH the
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
set "TOTAL_VRAM_MB=0"
where nvidia-smi >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%a in ('nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2^>nul') do (
        set "TOTAL_VRAM_MB=%%a"
    )
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
if not defined LLAMA_DIR (
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
        for %%X in (llama-server.exe) do (
            set "LLAMA_DIR=%%~dpX"
            goto :found_llama_dir
        )
    )
)
:found_llama_dir

REM --- Find model GGUF ---
if not defined MODEL_PATH (
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
if /i "%~1"=="--gpu" (
    if "%GPU_LAYERS%"=="0" set "GPU_LAYERS=5"
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
set "POSITIONAL_ARGS=%POSITIONAL_ARGS% %1"
shift
goto :parse_args

:done_parse

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
    echo   start-windows-gpu.cmd
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
    echo   start-windows-gpu.cmd
    exit /b 1
)

echo ============================================================
echo  llama.cpp + Gemma 4  (Windows Native + CUDA GPU)
echo  Max-context-first auto-configuration
echo ============================================================
echo   backend:    %LLAMA_SERVER%
echo   model:      %MODEL_PATH%
echo.
if %TOTAL_VRAM_MB% gtr 0 (
    echo   GPU VRAM:   %TOTAL_VRAM_MB% MiB
    echo   gpu layers: %GPU_LAYERS%  ^|  context: %CONTEXT_TOKENS% tok  ^|  KV: %KV_TYPE%
    echo   threads:    %THREADS%  ^|  port: %SERVER_PORT%
    echo.
    echo   VRAM budget ^(measured, Q2_K Gemma 4 26B-A4B^):
    set /a "L_MB=%GPU_LAYERS% * %PER_LAYER_MB%"
    set /a "KV_MB=%TOTAL_VRAM_MB% - %OVERHEAD_MB% - L_MB%"
    echo     %GPU_LAYERS% model layers    ~ %L_MB% MiB  ^(CUDA speed^)
    echo     KV cache (%KV_TYPE%)   ~ %KV_MB% MiB  ^(context^)
    echo     CUDA overhead         ~ %OVERHEAD_MB% MiB
    echo.
    if %GPU_LAYERS% gtr 0 (
        echo   [MAX-CONTEXT MODE] Highest layer count that reaches native context.
    ) else (
        echo   [CPU-ONLY MODE]
    )
    echo   Adjust the balance: set GPU_LAYERS=N ^& start-windows-gpu.cmd
    echo     more layers = faster, fewer layers = more context headroom
) else (
    echo   gpu layers: %GPU_LAYERS%  ^|  context: %CONTEXT_TOKENS% tok  ^|  threads: %THREADS%
    echo.
    echo   No NVIDIA GPU detected - running CPU-only.
    echo   (Install NVIDIA drivers or set GPU_LAYERS to force GPU mode)
)
echo ============================================================

REM --- Build llama-server command line ---
set "LLAMA_OPTS=-m "%MODEL_PATH%" -ngl %GPU_LAYERS% -c %CONTEXT_TOKENS% -t %THREADS% --host %SERVER_HOST% --port %SERVER_PORT%"

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
echo.
echo Active optimizations:
if "%SPECULATIVE%"=="1" (
    echo   [ON]  N-gram speculative decoding (ngram-mod)
) else (
    echo   [OFF] N-gram speculative decoding
)
if "%WARM%"=="1" (
    echo   [ON]  Warm mode (server stays alive after client exits)
) else (
    echo   [OFF] Warm mode
)
if %GPU_LAYERS% gtr 0 (
    echo   [ON]  CUDA GPU offload: %GPU_LAYERS% layers, Flash Attention, %KV_TYPE% KV, ub 128
) else (
    echo   [ON]  CPU-only: thread pinning (cpu-strict 1, cpu-range 0-2), %KV_TYPE% KV, ub 128
)
echo.

REM --- RAM cache: warm the OS file cache so expert loads hit RAM, not disk -
# The custom build MADV_DONTNEEDs expert pages after load. On Windows the OS
# file cache holds hot experts in RAM and evicts cold ones to disk. With little
# RAM headroom and the model possibly on a slow drive, cold experts fault from
# disk and stall inference. This pre-reads the model sequentially to warm the
# file cache (fast sequential I/O) so each expert's first load is a RAM hit.
# Enable with RAM_CACHE=1 (default). Disable with RAM_CACHE=0.
if not defined RAM_CACHE set "RAM_CACHE=1"
if "%RAM_CACHE%"=="1" (
    if exist "%MODEL_PATH%" (
        echo Preheating model into OS file cache ...
        REM PowerShell sequential read warms the system file cache (standby list).
        powershell -NoProfile -Command "$s=New-Object System.IO.FileStream('%MODEL_PATH%','Open','Read','ReadWrite',67108864);$b=New-Object byte[] 67108864;while($s.Read($b,0,$b.Length)){};$s.Close()" >nul 2>&1
        if errorlevel 1 (
            echo   (preheat skipped — could not read model file)
        )
    )
)

REM --- Start llama-server ---
echo Launching llama-server ...
echo Configuration: %LLAMA_OPTS%
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
where npm >nul 2>&1
if errorlevel 1 (
    echo npm not found. Installing Node.js via winget...
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
echo GPU-accelerated llama.cpp Gemma 4 server/client on Windows.
echo Auto-detects NVIDIA VRAM and maximizes context window first, then speed.
echo.
echo Modes:
echo   (none)           Start server, then launch Pi coding agent (tool use)
echo   --ask "PROMPT"   Single-shot: ask a question, print the reply, exit
echo   --chat           Interactive chat REPL with conversation memory
echo.
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
echo.
echo Max-context-first logic:
echo   Default reaches the model's native 262K context with the highest GPU
echo   layer count that fits (measured: ngl=5 on RTX 4050 / Q2_K). This gives
echo   you the largest context AND CUDA speedup. Override to shift the balance:
echo.
echo   set GPU_LAYERS=10 ^& %~nx0     max speed (154K ctx)
echo   set GPU_LAYERS=5  ^& %~nx0     native 262K ctx + GPU  [default]
echo   set GPU_LAYERS=3  ^& %~nx0     min GPU, max RAM headroom
echo   set KV_TYPE=q8_0 ^& %~nx0      better quality, ~half context
echo.
echo Environment overrides:
echo   MODEL_PATH       GGUF model file
echo   LLAMA_DIR        llama.cpp directory with llama-server.exe
echo   GPU_LAYERS       layers to offload to GPU (default: auto)
echo   CONTEXT_TOKENS   context window size   (default: auto)
echo   KV_TYPE          q4_0 (max ctx) or q8_0 (quality) (default q4_0)
echo   SERVER_PORT      server listen port    (default 8080)
echo   THREADS          CPU threads (default: NUMBER_OF_PROCESSORS - 1)
echo.
echo Examples:
echo   %~nx0 --ask "Summarize the key points of this 200K-token document"
echo   %~nx0 --chat
echo   set GPU_LAYERS=10 ^& %~nx0 --chat
echo   %~nx0 --no-warm
echo   %~nx0 --chat --debug
goto :eof
