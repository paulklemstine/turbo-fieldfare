#!/bin/bash
#
# start.sh — Gemma 4 26B-A4B local inference launcher.
#
# Dispatches to the right backend for the current platform:
#   * Apple Silicon Mac  -> start-mac.sh  (Swift + Metal, the original TurboFieldfare)
#   * Linux + NVIDIA GPU  -> start-linux.sh (llama.cpp + CUDA)
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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
        echo "  This script runs on macOS (Apple Silicon) and Linux (NVIDIA GPU)." >&2
        exit 1
        ;;
esac
