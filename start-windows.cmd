@echo off
REM
REM start-windows.cmd — Run Gemma 4 26B-A4B on Windows natively via llama.cpp.
REM
REM This is the Windows counterpart to start-linux.sh / start-mac.sh. It mirrors
REM the same three modes and the same on-the-wire protocol (OpenAI-compatible
REM server on http://127.0.0.1:8080/v1) so Scripts/chat.py and the Pi agent config
REM work unchanged across platforms.
REM
REM Native Windows avoids WSL2's CPU throttling and memory limits. On our Intel
REM N150 test machine, Windows native runs 4-5x faster than WSL2:
REM   WSL2 (MADV_DONTNEED, 5.7GB RAM):  ~0.72 tok/s
REM   Windows native (11.7GB RAM):     ~3.41 tok/s
REM
REM The speedup comes from having twice as available RAM (11.7GB vs 5.7GB),
REM which lets the OS page cache hold most of the 14GB model. WSL2's 5.7GB
REM limit forces constant page eviction and expert re-reading from disk.
REM
REM Usage (in cmd.exe or PowerShell):
REM   start-windows.cmd                                  REM Pi coding agent (tool use)
REM   start-windows.cmd --chat                           REM interactive chat
REM   start-windows.cmd --ask "What is the capital of France?"
REM
REM Environment overrides (set in PowerShell: $env:VAR = "value"):
REM   MODEL_PATH       GGUF model file (default: C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf)
REM   LLAMA_DIR        llama.cpp directory (default: C:\Users\Paul\llama-b10242)
REM   CONTEXT_TOKENS   context window size   (default 512)
REM   SERVER_PORT      server listen port    (default 8080)
REM   GPU_LAYERS       GPU layers to offload (default 0 = CPU only)
REM

setlocal enabledelayedexpansion

REM --- Determine script directory ---
set "REPO_DIR=%~dp0"
set "REPO_DIR=%REPO_DIR:~0,-1%"

REM --- Default configuration ---
if not defined MODEL_PATH (
    if exist "%REPO_DIR%\models\gemma-4-26B-A4B-it.Q4_0.gguf" (
        set "MODEL_PATH=%REPO_DIR%\models\gemma-4-26B-A4B-it.Q4_0.gguf"
    ) else if exist "C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf" (
        set "MODEL_PATH=C:\Users\Paul\models\gemma-4-26B-A4B-it.Q4_0.gguf"
    ) else (
        set "MODEL_PATH=%REPO_DIR%\models\gemma-4-26B-A4B-it.Q4_0.gguf"
    )
)

if not defined LLAMA_DIR (
    if exist "C:\Users\Paul\llama-b10242\llama-server.exe" (
        set "LLAMA_DIR=C:\Users\Paul\llama-b10242"
    ) else (
        set "LLAMA_DIR=%REPO_DIR%\llama-b10242"
    )
)

if not defined CONTEXT_TOKENS set "CONTEXT_TOKENS=512"
if not defined SERVER_PORT set "SERVER_PORT=8080"
if not defined GPU_LAYERS set "GPU_LAYERS=0"
if not defined THREADS set "THREADS=4"

set "LLAMA_SERVER=%LLAMA_DIR%\llama-server.exe"
set "SERVER_HOST=127.0.0.1"
set "MODE=pi"
set "ASK_PROMPT="

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
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help

REM Unknown arg - collect for pass-through
set "POSITIONAL_ARGS=%POSITIONAL_ARGS% %1"
shift
goto :parse_args

:done_parse

REM --- Validate llama-server exists ---
if not exist "%LLAMA_SERVER%" (
    echo ERROR: llama-server.exe not found at %LLAMA_SERVER%
    echo   Download a pre-built Windows binary from:
    echo     https://github.com/ggml-org/llama.cpp/releases
    echo   Or set LLAMA_DIR to your llama.cpp directory.
    exit /b 1
)

REM --- Validate model exists ---
if not exist "%MODEL_PATH%" (
    echo ERROR: model not found at %MODEL_PATH%
    echo   Download the Q4_0 quant and set MODEL_PATH accordingly.
    exit /b 1
)

echo Starting llama.cpp + Gemma 4 ^(Windows Native^)...
echo   backend: %LLAMA_SERVER%
echo   model:   %MODEL_PATH%
echo   gpu layers: %GPU_LAYERS%  ^|  context: %CONTEXT_TOKENS%  ^|  port: %SERVER_PORT%

REM --- Build llama-server command line ---
set "LLAMA_OPTS=-m "%MODEL_PATH%" -ngl %GPU_LAYERS% -c %CONTEXT_TOKENS% -t %THREADS% --cpu-strict 1 --no-repack --host %SERVER_HOST% --port %SERVER_PORT%"

REM --- CPU optimization flags ---
if "%GPU_LAYERS%"=="0" (
    set "LLAMA_OPTS=!LLAMA_OPTS! -ctk q8_0 -ctv q8_0 -ub 256"
)

REM --- Start llama-server ---
echo Launching llama-server ...
start "llama-server" /B "%LLAMA_SERVER%" %LLAMA_OPTS% > "%REPO_DIR%\llama_server.log" 2>&1

REM --- Wait for server to be ready ---
echo Loading model weights ...
set /a ATTEMPTS=0
:wait_loop
curl -s -m 2 http://%SERVER_HOST%:%SERVER_PORT%/health 2>nul | findstr /i "ok" >nul
if not errorlevel 1 goto :server_ready

timeout /t 1 /nobreak >nul
set /a ATTEMPTS+=1
if %ATTEMPTS% lss 120 goto :wait_loop

echo ERROR: Timed out waiting for llama-server to be ready.
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

REM --- Default mode: just leave server running ---
echo.
echo Server is ready at http://%SERVER_HOST%:%SERVER_PORT%
echo Use Ctrl+C in the llama-server window to stop.
echo.
echo For Pi agent integration, configure models.json with:
echo   baseUrl: http://%SERVER_HOST%:%SERVER_PORT%/v1
goto :eof

:show_help
echo Usage: %~nx0 [options]
echo.
echo Starts the llama.cpp Gemma 4 server/client on Windows.
echo.
echo   --ask "PROMPT"   Run a single prompt against the model and print the reply
echo   --chat           Start an interactive chat session directly with the model
echo   --cpu            Force CPU-only mode (default)
echo   --threads N      CPU threads to use (default: 4)
echo   -h, --help       Show this help
echo.
echo Environment overrides:
echo   MODEL_PATH       GGUF model file
echo   LLAMA_DIR        llama.cpp directory with llama-server.exe
echo   CONTEXT_TOKENS   context window size   (default %CONTEXT_TOKENS%)
echo   SERVER_PORT      server listen port    (default %SERVER_PORT%)
echo.
echo Examples:
echo   %~nx0 --ask "What is the capital of France?"
echo   %~nx0 --chat
echo   %~nx0 --threads 8
goto :eof
