#!/bin/bash

# Ensure Homebrew binaries are in PATH
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

TURBO_DIR="$HOME/turbo-fieldfare"
MODEL_PATH="scratch/gemma4.gturbo"
PI_MODEL="turbofieldfare/gemma-4-26b-a4b-it"
PI_CONFIG_DIR="$HOME/.pi/agent"
PI_MODELS_FILE="$PI_CONFIG_DIR/models.json"
CHAT_SCRIPT="$TURBO_DIR/Scripts/chat.py"

usage() {
    cat << EOF
Usage: $0 [options] [pi args...]

Starts the TurboFieldfare Gemma 4 server, then launches the chosen client.

  --ask "PROMPT"   Run a single prompt against the model and print the reply
  --chat           Start an interactive chat session directly with the model
  (no options)     Launch the Pi coding agent (tool use); remaining args go to pi
  -h, --help       Show this help

Examples:
  $0 --ask "What is the capital of France?"
  $0 --chat
  $0 "List the files in this repository"
EOF
}

MODE="pi"
case "${1:-}" in
    --ask)
        MODE="ask"
        shift
        ;;
    --chat)
        MODE="chat"
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
esac

if [ "$MODE" = "ask" ]; then
    ASK_PROMPT="$*"
    if [ -z "$ASK_PROMPT" ]; then
        echo "ERROR: --ask requires a prompt." >&2
        usage
        exit 1
    fi
fi

echo "Starting TurboFieldfare + Gemma 4 Local Stack..."

PIDS=()

cleanup() {
    code=$?
    echo -e "\nShutting down background processes..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    exit "$code"
}
trap cleanup SIGINT SIGTERM EXIT

cd "$TURBO_DIR" || exit 1

# 1. Ensure pi points at the TurboFieldfare server via models.json
mkdir -p "$PI_CONFIG_DIR"
if [ ! -f "$PI_MODELS_FILE" ] || ! grep -q "turbofieldfare" "$PI_MODELS_FILE"; then
    cat << 'EOF' > "$PI_MODELS_FILE"
{
  "providers": {
    "turbofieldfare": {
      "name": "TurboFieldfare (Local Gemma 4)",
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "gemma-4-26b-a4b-it",
          "name": "Gemma 4 26B-A4B IT (Local)",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 16384,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
EOF
    echo "-> Wrote $PI_MODELS_FILE"
fi

# 2. Check/Start TurboFieldfare Server (Port 8080)
if curl -s "http://127.0.0.1:8080/health" | grep -q "ok"; then
    echo "-> TurboFieldfare Server is already running on port 8080."
else
    echo "-> Launching TurboFieldfare Server on port 8080..."
    .build/release/TurboFieldfareServer --model "$MODEL_PATH" --port 8080 > turbo_server.log 2>&1 &
    TURBO_PID=$!
    PIDS+=("$TURBO_PID")
    echo "-> Waiting for TurboFieldfare Server to be ready..."
    for i in $(seq 1 120); do
        if curl -s -m 2 "http://127.0.0.1:8080/health" | grep -q "ok"; then
            echo "-> TurboFieldfare Server ready."
            break
        fi
        if ! kill -0 $TURBO_PID 2>/dev/null; then
            echo "ERROR: TurboFieldfare crashed. Check $TURBO_DIR/turbo_server.log"
            exit 1
        fi
        sleep 1
    done
fi

# 3. Launch the chosen client
case "$MODE" in
    ask)
        echo "-> Asking TurboFieldfare: $ASK_PROMPT"
        python3 "$CHAT_SCRIPT" --ask "$ASK_PROMPT"
        ;;
    chat)
        echo "-> Starting interactive chat with TurboFieldfare..."
        python3 "$CHAT_SCRIPT" --chat "$@"
        ;;
    *)
        echo "-> Launching Pi Agent..."
        export PI_SKIP_VERSION_CHECK=1
        export PI_TELEMETRY=0
        pi --model "$PI_MODEL" "$@"
        ;;
esac
