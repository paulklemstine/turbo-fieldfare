#!/bin/bash
#
# start.sh — Gemma 4 26B-A4B local inference launcher.
#
# Dispatches to the right backend for the current platform:
#   * Apple Silicon Mac  -> start-mac.sh  (Swift + Metal, the original TurboFieldfare)
#   * Linux + NVIDIA GPU  -> start-linux.sh (llama.cpp + CUDA)
#   * WSL2 (Windows)      -> start-windows.cmd (native Windows llama.cpp)
#
# All backends expose the same three modes and the same on-the-wire protocol
# (an OpenAI-compatible server on http://127.0.0.1:8080/v1), so Scripts/chat.py
# and the Pi agent config work unchanged across platforms:
#
#   ./start.sh                                  # Pi coding agent (tool use)
#   ./start.sh --chat                           # interactive chat directly with the model
#   ./start.sh --ask "What is the capital of France?"   # single prompt, print reply, exit
#
# Pass-through: every argument is forwarded to the platform script, including
# extra args for the Pi agent in default mode.
#
# Windows native (WSL2):
#   When running under WSL2, ./start.sh dispatches to start-windows.cmd which
#   launches llama-server.exe natively on Windows. This avoids WSL2's CPU
#   throttling and memory limits, giving 4-5x better performance:
#     WSL2 (MADV_DONTNEED, 5.7GB RAM):  ~0.72 tok/s
#     Windows native (11.7GB RAM):     ~3.41 tok/s

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect WSL2 (Windows Subsystem for Linux)
is_wsl=0
if grep -qiE "(microsoft|WSL)" /proc/version 2>/dev/null && command -v cmd.exe >/dev/null 2>&1; then
    is_wsl=1
fi

# Allow --wsl flag to force WSL2 native mode (uses our MADV_DONTNEED patch)
# Default under WSL2 is Windows native (much faster); --wsl overrides this.
use_wsl_native=0
if [ "$is_wsl" = "1" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--wsl" ]; then
            use_wsl_native=1
            break
        fi
    done
    if [ "$use_wsl_native" = "0" ]; then
        # Default: delegate to Windows native launcher for best performance.
        # We invoke cmd.exe from a Windows-accessible directory with a simple
        # command. This avoids WSL interop issues with Linux paths.
        #
        # Optimal config discovered by benchmarking 15+ combinations on N150:
        #   repack ON + 3 threads + q4_0 KV + ub 256 = ~4.8 tok/s warm
        #   (6.7x faster than WSL2's ~0.72 tok/s)

        # Copy the Windows launcher to C: drive
        WIN_CMD_DIR="/mnt/c/Users/Paul"
        cp -f "$REPO_DIR/start-windows.cmd" "$WIN_CMD_DIR/start-windows.cmd" 2>/dev/null

        # Filter out --wsl from args if present
        args=()
        for arg in "$@"; do
            [ "$arg" = "--wsl" ] || args+=("$arg")
        done

        # cd to Windows path then exec cmd.exe (cmd.exe fails on Linux paths)
        cd "$WIN_CMD_DIR"
        exec cmd.exe /c "C:\Users\Paul\start-windows.cmd" "${args[@]}"
    fi
fi

os="$(uname -s)"
case "$os" in
    Darwin)
        exec "$REPO_DIR/start-mac.sh" "$@"
        ;;
    Linux)
        exec "$REPO_DIR/start-linux.sh" "$@"
        ;;
    *)
        echo "ERROR: unsupported platform '$os'." >&2
        echo "  This script runs on macOS (Apple Silicon), Linux (NVIDIA GPU), and WSL2/Windows." >&2
        exit 1
        ;;
esac
