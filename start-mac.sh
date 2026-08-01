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

DEBUG=0
MODE="pi"
ASK_PROMPT=""
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)
            DEBUG=1
            shift
            ;;
        --ask)
            MODE="ask"
            shift
            if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                ASK_PROMPT="$1"
                shift
            fi
            ;;
        --chat)
            MODE="chat"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

log_info() {
    if [ "$DEBUG" = "1" ]; then
        echo "$@"
    fi
}

if [ "$MODE" = "ask" ]; then
    if [ -z "$ASK_PROMPT" ]; then
        if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
            ASK_PROMPT="${POSITIONAL_ARGS[*]}"
        fi
    fi
    if [ -z "$ASK_PROMPT" ]; then
        echo "ERROR: --ask requires a prompt." >&2
        usage
        exit 1
    fi
fi

log_info "Starting TurboFieldfare + Gemma 4 Local Stack..."

PIDS=()

cleanup() {
    code=$?
    if [ "$DEBUG" = "1" ]; then
        echo -e "\nShutting down background processes..."
    fi
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
    log_info "-> Wrote $PI_MODELS_FILE"
fi

# 2. Check/Start TurboFieldfare Server (Port 8080)
if curl -s "http://127.0.0.1:8080/health" | grep -q '"status":"ok"'; then
    log_info "-> TurboFieldfare Server is already running on port 8080."
else
    log_info "-> Launching TurboFieldfare Server on port 8080..."
    .build/release/TurboFieldfareServer --model "$MODEL_PATH" --port 8080 > turbo_server.log 2>&1 &
    TURBO_PID=$!
    PIDS+=("$TURBO_PID")
    log_info "-> Waiting for TurboFieldfare Server to be ready..."
    for i in $(seq 1 120); do
        if curl -s -m 2 "http://127.0.0.1:8080/health" | grep -q '"status":"ok"'; then
            log_info "-> TurboFieldfare Server ready."
            break
        fi
        if ! kill -0 $TURBO_PID 2>/dev/null; then
            echo "ERROR: TurboFieldfare crashed. Check $TURBO_DIR/turbo_server.log" >&2
            exit 1
        fi
        sleep 1
    done
fi

# 3. Launch the chosen client
case "$MODE" in
    ask)
        log_info "-> Asking TurboFieldfare: $ASK_PROMPT"
        exec python3 "$CHAT_SCRIPT" --ask "$ASK_PROMPT" --no-stream
        ;;
    chat)
        log_info "-> Starting interactive chat with TurboFieldfare..."
        exec python3 "$CHAT_SCRIPT" --chat "${POSITIONAL_ARGS[@]}"
        ;;
    *)
        log_info "-> Launching Pi Agent..."
        export PI_SKIP_VERSION_CHECK=1
        export PI_TELEMETRY=0
        exec pi --model "$PI_MODEL" "${POSITIONAL_ARGS[@]}"
        ;;
esac
