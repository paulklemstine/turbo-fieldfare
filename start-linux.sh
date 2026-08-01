#!/bin/bash
#
# start-linux.sh — Run Gemma 4 26B-A4B on NVIDIA/Linux via llama.cpp + CUDA.
#
# This is the Linux counterpart to start-mac.sh. It mirrors the same three
# modes and the same on-the-wire protocol (OpenAI-compatible server on :8080)
# so the existing Scripts/chat.py client and the Pi agent config work unchanged.
# The only difference is the backend: llama.cpp with hybrid GPU-CPU offload
# replaces the Swift/Metal TurboFieldfareServer.
#
# Modes (identical to start-mac.sh):
#   --ask "PROMPT"   Run a single prompt against the model and print the reply
#   --chat           Start an interactive chat session directly with the model
#   (no options)     Launch the Pi coding agent (tool use) via the local server
#   -h, --help       Show this help

NVDRIVER_DIR=$(ls -d /usr/lib/wsl/drivers/nvhm.inf_amd64_* 2>/dev/null | head -n 1)
if [ -n "$NVDRIVER_DIR" ]; then
    export LD_LIBRARY_PATH="$NVDRIVER_DIR:/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"
fi
export PATH="/usr/local/cuda/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAT_SCRIPT="$REPO_DIR/Scripts/chat.py"

# --- Backend location ---------------------------------------------------------
# llama.cpp checkout. Override if yours lives elsewhere.
if [ -z "${LLAMA_DIR:-}" ]; then
    if [ -d "$REPO_DIR/llama.cpp" ]; then
        LLAMA_DIR="$REPO_DIR/llama.cpp"
    elif [ -d "$REPO_DIR/../llama.cpp" ]; then
        LLAMA_DIR="$REPO_DIR/../llama.cpp"
    else
        LLAMA_DIR="$HOME/gemmm4gpu/llama.cpp"
    fi
fi

# --- Model --------------------------------------------------------------------
# The abliterated Gemma 4 26B-A4B at 4-bit (Q2_K). ~10.7 GB on disk.
# Override to point at a different GGUF (e.g. a Q3_K_M or Q4_K_M quant).
if [ -f "/mnt/e/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf" ]; then
    DEFAULT_MODEL_PATH="/mnt/e/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
elif [ -f "e:/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf" ]; then
    DEFAULT_MODEL_PATH="e:/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
elif [ -f "E:/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf" ]; then
    DEFAULT_MODEL_PATH="E:/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
else
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
fi

MODEL_PATH="${MODEL_PATH:-$DEFAULT_MODEL_PATH}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-$REPO_DIR/models/chat_template.jinja}"

# --- Tunables for the 6 GB RTX 4050 laptop GPU -------------------------------
# Number of transformer layers offloaded to the GPU; the rest run on CPU.
# Q2_K (~10.7 GB) over 30 layers: -ngl 18 uses ~5.7 GB VRAM + KV headroom.
GPU_LAYERS="${GPU_LAYERS:-18}"
CONTEXT_TOKENS="${CONTEXT_TOKENS:-4096}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_HOST="127.0.0.1"

PI_MODEL="turbofieldfare/gemma-4-26b-a4b-it"
PI_CONFIG_DIR="$HOME/.pi/agent"
PI_MODELS_FILE="$PI_CONFIG_DIR/models.json"

usage() {
    cat << EOF
Usage: $0 [options] [pi args...]

Starts the llama.cpp Gemma 4 server/client, then launches the chosen client.

  --ask "PROMPT"   Run a single prompt against the model and print the reply
  --chat           Start an interactive chat session directly with the model
  (no options)     Launch the Pi coding agent (tool use); remaining args go to pi
  -h, --help       Show this help

Environment overrides:
  LLAMA_DIR        llama.cpp checkout (default $LLAMA_DIR)
  MODEL_PATH       GGUF model file (default $MODEL_PATH)
  GPU_LAYERS       layers offloaded to GPU (default $GPU_LAYERS)
  CONTEXT_TOKENS   context window size   (default $CONTEXT_TOKENS)
  SERVER_PORT      server listen port    (default $SERVER_PORT)

Examples:
  $0 --ask "What is the capital of France?"
  $0 --chat
  \$GPU_LAYERS=15 $0 "List the files in this repository"
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

# --- Locate llama.cpp binaries -----------------------------------------------
if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
elif [ -x "$LLAMA_DIR/bin/llama-server" ]; then
    LLAMA_SERVER="$LLAMA_DIR/bin/llama-server"
else
    echo "ERROR: llama-server not found in $LLAMA_DIR." >&2
    echo "  Build it once with:" >&2
    echo "    cd $LLAMA_DIR && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \\" >&2
    echo "      && cmake --build build -j\$(nproc) --target llama-server" >&2
    exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: model not found at $MODEL_PATH" >&2
    echo "  Download the Q2_K quant (mradermacher/gemma-4-26B-A4B-it-abliterated-GGUF)" >&2
    echo "  or set MODEL_PATH to your GGUF." >&2
    exit 1
fi

echo "Starting llama.cpp + Gemma 4 (NVIDIA/Linux) Local Stack..."
echo "  backend: $LLAMA_SERVER"
echo "  model:   $MODEL_PATH"
echo "  gpu layers: $GPU_LAYERS  |  context: $CONTEXT_TOKENS  |  port: $SERVER_PORT"

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

# --- Common llama.cpp flags ----------------------------------------------
LLAMA_COMMON=(
    -m "$MODEL_PATH"
    -ngl "$GPU_LAYERS"
    -c "$CONTEXT_TOKENS"
    --temp 0.7
    --repeat-penalty 1.1
)
# Only pass the chat template if we have one; llama.cpp ships its own Gemma
# template as a fallback.
if [ -f "$CHAT_TEMPLATE" ]; then
    LLAMA_COMMON+=(--chat-template "$CHAT_TEMPLATE")
fi

# --- Modes that talk directly to the server via the existing chat client ---
# Scripts/chat.py speaks the OpenAI Chat Completions API, so it works against
# llama-server exactly as it does against TurboFieldfareServer.
if [ "$MODE" = "ask" ] || [ "$MODE" = "chat" ]; then
    # Make sure the server is up for the chat client.
    if ! curl -s "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q "ok"; then
        echo "-> Launching llama.cpp Server on port $SERVER_PORT..."
        "$LLAMA_SERVER" "${LLAMA_COMMON[@]}" --host "$SERVER_HOST" --port "$SERVER_PORT" \
            > "$REPO_DIR/llama_server.log" 2>&1 &
        SERVER_PID=$!
        PIDS+=("$SERVER_PID")
        for i in $(seq 1 120); do
            if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q "ok"; then
                echo "-> llama.cpp Server ready."
                break
            fi
            if ! kill -0 $SERVER_PID 2>/dev/null; then
                echo "ERROR: llama.cpp Server crashed. Check $REPO_DIR/llama_server.log"
                exit 1
            fi
            sleep 1
        done
    fi

    if [ "$MODE" = "ask" ]; then
        echo "-> Asking Gemma 4: $ASK_PROMPT"
        exec python3 "$CHAT_SCRIPT" --ask "$ASK_PROMPT" --no-stream
    fi

    echo "-> Starting interactive chat with Gemma 4..."
    exec python3 "$CHAT_SCRIPT" --chat
fi

# --- Default mode: Pi agent via OpenAI-compatible server -------------------

# 1. Ensure pi points at the local llama.cpp server via models.json
mkdir -p "$PI_CONFIG_DIR"
if [ ! -f "$PI_MODELS_FILE" ] || ! grep -q "turbofieldfare" "$PI_MODELS_FILE"; then
    cat << 'EOF' > "$PI_MODELS_FILE"
{
  "providers": {
    "turbofieldfare": {
      "name": "llama.cpp (Local Gemma 4)",
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
          "contextWindow": 4096,
          "maxTokens": 2048,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
EOF
    echo "-> Wrote $PI_MODELS_FILE"
fi

# 2. Check/Start llama.cpp Server
if curl -s "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q "ok"; then
    echo "-> llama.cpp Server is already running on port $SERVER_PORT."
else
    echo "-> Launching llama.cpp Server on port $SERVER_PORT..."
    "$LLAMA_SERVER" "${LLAMA_COMMON[@]}" --host "$SERVER_HOST" --port "$SERVER_PORT" \
        > "$REPO_DIR/llama_server.log" 2>&1 &
    SERVER_PID=$!
    PIDS+=("$SERVER_PID")
    echo "-> Waiting for llama.cpp Server to be ready..."
    for i in $(seq 1 120); do
        if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q "ok"; then
            echo "-> llama.cpp Server ready."
            break
        fi
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            echo "ERROR: llama.cpp Server crashed. Check $REPO_DIR/llama_server.log"
            exit 1
        fi
        sleep 1
    done
fi

# 3. Launch Pi Agent
echo "-> Launching Pi Agent..."
export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0
exec pi --model "$PI_MODEL" "$@"
