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
        # Default: delegate to Windows native launcher for best performance
        # Convert the Linux path to Windows format for cmd.exe
        WIN_PATH="$REPO_DIR/start-windows.cmd"
        if command -v wslpath >/dev/null 2>&1; then
            WIN_PATH="$(wslpath -w "$WIN_PATH")"
        fi
        # Filter out --wsl from args if present
        args=()
        for arg in "$@"; do
            [ "$arg" = "--wsl" ] || args+=("$arg")
        done
        exec cmd.exe /c "$WIN_PATH" "${args[@]}"
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
