@echo off
REM
REM start-windows.cmd — Run Gemma 4 26B-A4B on Windows natively via llama.cpp.
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
REM   - WITH repack (reorganizes weights for faster matmul): +45% speed
REM   - 3 threads on 4-core CPU (leaves 1 core for OS/disk): best throughput
REM   - q4_0 KV cache (less memory bandwidth than q8_0): +5% speed
REM   - ub 256 (micro-batch): lower peak memory than 512
REM   - cpu-strict 1 (pin threads to cores): more consistent latency
REM
REM First launch takes ~90s for repack to complete. Subsequent launches
REM reuse the repacked weights from disk (faster init).
REM
REM Usage (in cmd.exe or PowerShell):
REM   start-windows.cmd                                  REM Pi coding agent (tool use)
REM   start-windows.cmd --chat                           REM interactive chat
REM   start-windows.cmd --ask "What is the capital of France?"
REM
REM Environment overrides (set in PowerShell: $env:VAR = "value"):
REM   MODEL_PATH       GGUF model file
REM   LLAMA_DIR        llama.cpp directory
REM   CONTEXT_TOKENS   context window size   (default 512)
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

if not defined CONTEXT_TOKENS set "CONTEXT_TOKENS=512"
if not defined SERVER_PORT set "SERVER_PORT=8080"
if not defined GPU_LAYERS set "GPU_LAYERS=0"

set "LLAMA_SERVER=%LLAMA_DIR%\llama-server.exe"
set "SERVER_HOST=127.0.0.1"
set "MODE=pi"
set "ASK_PROMPT="
set "DEBUG=0"

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
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help

REM Unknown arg - collect for pass-through
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
REM Optimal config for CPU-only inference on HDD-based systems:
REM   - repack ON: reorganizes weights for 45% faster matmul (needs sufficient RAM)
REM   - auto threads: physical cores - 1 (leaves 1 core for OS/disk I/O)
REM   - q4_0 KV cache: less memory bandwidth than q8_0
REM   - ub 256: lower peak memory than 512
REM   - cpu-strict 1: pin threads to cores (consistent latency)
set "LLAMA_OPTS=-m "%MODEL_PATH%" -ngl %GPU_LAYERS% -c %CONTEXT_TOKENS% -t %THREADS% --cpu-strict 1 --host %SERVER_HOST% --port %SERVER_PORT%"

REM --- CPU optimization flags ---
if "%GPU_LAYERS%"=="0" (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ctk q4_0 -ctv q4_0 -ub 256"
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

REM --- Launch appropriate client ---
if "%MODE%"=="ask" (
    if "%ASK_PROMPT%"=="" (
        echo ERROR: --ask requires a prompt.
        exit /b 1
    )
    echo Asking Gemma 4: %ASK_PROMPT%
    if exist "%REPO_DIR%\Scripts\chat.py" (
        python "%REPO_DIR%\Scripts\chat.py" --ask "%ASK_PROMPT%"
    ) else (
        echo Chat script not found. Server is running at http://%SERVER_HOST%:%SERVER_PORT%
        echo Use curl or any OpenAI-compatible client to send requests.
    )
    goto :eof
)

if "%MODE%"=="chat" (
    echo Starting interactive chat with Gemma 4 ...
    if exist "%REPO_DIR%\Scripts\chat.py" (
        python "%REPO_DIR%\Scripts/chat.py" --chat %POSITIONAL_ARGS%
    ) else (
        echo Chat script not found. Server is running at http://%SERVER_HOST%:%SERVER_PORT%
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
    echo           "contextWindow": 4096,>> "%PI_MODELS_FILE%"
    echo           "maxTokens": 2048,>> "%PI_MODELS_FILE%"
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
) else (
    echo Pi agent not found in PATH. Server is running at http://%SERVER_HOST%:%SERVER_PORT%
    echo Install Pi agent or use any OpenAI-compatible client to send requests.
)
goto :eof

:show_help
echo Usage: %~nx0 [options]
echo.
echo Starts the llama.cpp Gemma 4 server/client on Windows.
echo.
echo   --ask "PROMPT"   Run a single prompt against the model and print the reply
echo   --chat           Start an interactive chat session directly with the model
echo   --cpu            Force CPU-only mode (default)
echo   --debug          Show llama-server log output in the console (default: off)
echo   --threads N      CPU threads to use (default: NUMBER_OF_PROCESSORS - 1)
echo   -h, --help       Show this help
echo.
echo Environment overrides:
echo   MODEL_PATH       GGUF model file
echo   LLAMA_DIR        llama.cpp directory with llama-server.exe
echo   CONTEXT_TOKENS   context window size   (default %CONTEXT_TOKENS%)
echo   SERVER_PORT      server listen port    (default %SERVER_PORT%)
echo   THREADS          CPU threads (default: NUMBER_OF_PROCESSORS - 1)
echo.
echo Examples:
echo   %~nx0 --ask "What is the capital of France?"
echo   %~nx0 --chat
echo   %~nx0 --threads 8
goto :eof
