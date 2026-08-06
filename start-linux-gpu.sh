#!/bin/bash
#
# start-linux-gpu.sh — Run Gemma 4 26B-A4B on NVIDIA/Linux via llama.cpp + CUDA.
#
# Max-context-first GPU variant of start-linux.sh. Auto-detects your NVIDIA
# VRAM and computes the configuration that delivers the LARGEST context
# window first, then max token/second within that.
#
# Measured on the reference box (RTX 4050 laptop, 6141 MiB VRAM, Q2_K Gemma 4
# 26B-A4B, AMD Ryzen 5 8645HS 5c/10t w/ AVX-512/VNNI/BF16). EMPIRICAL constants:
#   * VRAM cost per offloaded layer: ~338 MiB
#   * CUDA context overhead:         ~500 MiB
#   * KV cache per token (q4_0):     ~15 KiB   (max context)
#   * KV cache per token (q8_0):     ~30 KiB   (max quality)
#   * Model native context:          262,144 tokens
#
# The speed/context tradeoff (6141 MiB budget):
#   layers | layer VRAM | KV budget (q4_0) | max context
#   -------|------------|-------------------|------------
#     10   |   3384 MiB |         2257 MiB |   154K tok  [max speed]
#      6   |   2030 MiB |         3610 MiB |   246K tok
#      5   |   1692 MiB |         3949 MiB |   262K tok  <- native ctx + GPU
#      0   |      0 MiB |         5641 MiB |   262K tok  (CPU-only)
#
# DEFAULT: highest layer count reaching native 262K context (ngl=5) — you get
# BOTH max context AND CUDA speedup. Override with GPU_LAYERS / KV_TYPE.
#
# CPU specifics for the Ryzen 5 8645HS (Zen 4, AVX-512/VNNI/BF16):
#   - 5 cores / 10 threads. Non-offloaded layers run here, so CPU flags matter
#     whenever GPU_LAYERS < 30.
#   - AVX-512 VNNI accelerates the int8/int4 dot products in the CPU backend.
#     The custom build auto-detects it; we pin threads to keep L2 warm.
#   - --cpu-strict 1 + --cpu-range: pin to physical cores (the 8645HS has no
#     SMT asymmetry, but pinning still wins +5-15% per the repo's N150 data).
#   - --prio 2: raise inference priority so background tasks don't preempt the
#     worker during the ~50-100s prompt processing.
#
# Modes:
#   --ask "PROMPT"   single-shot question
#   --chat           interactive chat
#   (none)           Pi coding agent (tool use), full native context
#
# Environment overrides:
#   MODEL_PATH       GGUF model file
#   LLAMA_DIR        llama.cpp checkout
#   GPU_LAYERS       layers offloaded to GPU (default: auto = max-ctx optimum)
#   CONTEXT_TOKENS   context window size   (default: auto = native 262K)
#   KV_TYPE          q4_0 (max ctx) or q8_0 (max quality) (default q4_0)
#   THREADS          CPU threads (default: nproc-1 on CPU, auto on GPU)
#   SERVER_PORT      server listen port    (default 8080)
#
# Examples:
#   ./start-linux-gpu.sh --ask "Summarize this 200K-token document"
#   ./start-linux-gpu.sh --chat
#   GPU_LAYERS=10 ./start-linux-gpu.sh --chat     # favor speed
#   KV_TYPE=q8_0 ./start-linux-gpu.sh --chat       # favor quality

set -euo pipefail

NVDRIVER_DIR=$(ls -d /usr/lib/wsl/drivers/nvhm.inf_amd64_* 2>/dev/null | head -n 1)
if [ -n "$NVDRIVER_DIR" ]; then
    export LD_LIBRARY_PATH="$NVDRIVER_DIR:/usr/lib/wsl/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
else
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi
export PATH="/usr/local/cuda/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$REPO_DIR/Scripts/chat.py" ]; then
    CHAT_SCRIPT="$REPO_DIR/Scripts/chat.py"
elif [ -f "$REPO_DIR/turbo-fieldfare/Scripts/chat.py" ]; then
    CHAT_SCRIPT="$REPO_DIR/turbo-fieldfare/Scripts/chat.py"
elif [ -f "$REPO_DIR/../Scripts/chat.py" ]; then
    CHAT_SCRIPT="$REPO_DIR/../Scripts/chat.py"
else
    CHAT_SCRIPT="$REPO_DIR/Scripts/chat.py"
fi

# --- Backend location ---------------------------------------------------------
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
if [ -f "/mnt/e/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf" ]; then
    DEFAULT_MODEL_PATH="/mnt/e/Models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
elif [ -f "$REPO_DIR/models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf" ]; then
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it-abliterated.Q2_K.gguf"
elif [ -f "$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf" ]; then
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf"
else
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf"
fi
MODEL_PATH="${MODEL_PATH:-$DEFAULT_MODEL_PATH}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"

# ============================================================================
#  GPU VRAM DETECTION + MAX-CONTEXT-FIRST AUTO-CONFIG
# ============================================================================
# Empirical constants (RTX 4050, Q2_K Gemma 4 26B-A4B):
PER_LAYER_MB=338     # VRAM per offloaded transformer layer
OVERHEAD_MB=500      # CUDA context + buffers
KV_Q4_KIB=15         # KiB/token for q4_0 KV (max context)
KV_Q8_KIB=30         # KiB/token for q8_0 KV (max quality)
NATIVE_CTX=262144    # model's trained context length

KV_TYPE="${KV_TYPE:-q4_0}"
GPU_LAYERS="${GPU_LAYERS:-}"
CONTEXT_TOKENS="${CONTEXT_TOKENS:-}"
THREADS="${THREADS:-}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_HOST="127.0.0.1"

# --- Detect NVIDIA GPU VRAM ---
TOTAL_VRAM_MB=0
if command -v nvidia-smi >/dev/null 2>&1; then
    TOTAL_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
fi

if [ "$TOTAL_VRAM_MB" -gt 0 ] 2>/dev/null; then
    if [ -z "$GPU_LAYERS" ]; then
        # Highest layer count that still reaches native context.
        # layers <= (total - overhead - need_kv) / per_layer
        if [ "$KV_TYPE" = "q8_0" ]; then
            NEED_KV_MB=$(( NATIVE_CTX * KV_Q8_KIB / 1024 ))
        else
            NEED_KV_MB=$(( NATIVE_CTX * KV_Q4_KIB / 1024 ))
        fi
        LAYER_BUDGET_MB=$(( TOTAL_VRAM_MB - OVERHEAD_MB - NEED_KV_MB ))
        GPU_LAYERS=$(( LAYER_BUDGET_MB / PER_LAYER_MB ))
        [ "$GPU_LAYERS" -gt 30 ] && GPU_LAYERS=30
        [ "$GPU_LAYERS" -lt 1 ] && GPU_LAYERS=1
    fi

    if [ -z "$CONTEXT_TOKENS" ]; then
        LAYER_MB=$(( GPU_LAYERS * PER_LAYER_MB ))
        KV_BUDGET_MB=$(( TOTAL_VRAM_MB - OVERHEAD_MB - LAYER_MB ))
        [ "$KV_BUDGET_MB" -lt 0 ] && KV_BUDGET_MB=0
        if [ "$KV_TYPE" = "q8_0" ]; then
            CONTEXT_TOKENS=$(( KV_BUDGET_MB * 1024 / KV_Q8_KIB ))
        else
            CONTEXT_TOKENS=$(( KV_BUDGET_MB * 1024 / KV_Q4_KIB ))
        fi
        # Cap at native context (no benefit beyond it)
        [ "$CONTEXT_TOKENS" -gt "$NATIVE_CTX" ] && CONTEXT_TOKENS=$NATIVE_CTX
        # Round down to nearest 1024
        CONTEXT_TOKENS=$(( (CONTEXT_TOKENS / 1024) * 1024 ))
        [ "$CONTEXT_TOKENS" -lt 2048 ] && CONTEXT_TOKENS=2048
    fi
fi

PI_MODEL="turbofieldfare/gemma-4-26b-a4b-it"
PI_CONFIG_DIR="$HOME/.pi/agent"
PI_MODELS_FILE="$PI_CONFIG_DIR/models.json"

usage() {
    cat << EOF
Usage: $0 [options] [pi args...]

GPU-accelerated, max-context-first Gemma 4 server/client.
Auto-detects NVIDIA VRAM; maximizes context window first, then speed.

  --ask "PROMPT"   Run a single prompt against the model and print the reply
  --chat           Start an interactive chat session directly with the model
  --cpu            Force CPU-only mode (equivalent to GPU_LAYERS=0)
  --gpu            Force GPU mode (honor GPU_LAYERS if set)
  --threads N      CPU threads to use (default: nproc-1 on CPU, auto on GPU)
  (no options)     Launch the Pi coding agent (tool use); remaining args go to pi
  -h, --help       Show this help

Environment overrides:
  LLAMA_DIR        llama.cpp checkout (default $LLAMA_DIR)
  MODEL_PATH       GGUF model file (default $MODEL_PATH)
  GPU_LAYERS       layers offloaded to GPU (default: auto = max-ctx optimum)
  CONTEXT_TOKENS   context window size   (default: auto = native 262K)
  KV_TYPE          q4_0 (max ctx) or q8_0 (max quality) (default q4_0)
  RAM_CACHE        1=warm page cache + tune VM (default), 0=disable
  RAM_MLOCK        1=pin model in RAM via mlock (needs ulimit -l raised)
  SERVER_PORT      server listen port    (default $SERVER_PORT)

Examples:
  \$0 --ask "What is the capital of France?"
  \$0 --chat
  GPU_LAYERS=10 \$0 --chat
  KV_TYPE=q8_0 \$0 --chat
EOF
}

FORCE_CPU=0
FORCE_GPU=0
DEBUG=0
MODE="pi"
ASK_PROMPT=""
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --cpu)      FORCE_CPU=1; shift ;;
        --gpu)      FORCE_GPU=1; shift ;;
        --debug)    DEBUG=1; shift ;;
        --threads)  shift; THREADS="${1:-}"; shift ;;
        --ask)      MODE="ask"; shift
                    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                        ASK_PROMPT="$1"; shift
                    fi ;;
        --chat)     MODE="chat"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

if [ "$FORCE_CPU" = "1" ]; then
    GPU_LAYERS=0
elif [ "$FORCE_GPU" = "1" ] && [ "${GPU_LAYERS:-0}" = "0" ]; then
    GPU_LAYERS=5
fi

log_info() { [ "$DEBUG" = "1" ] && echo "$@" || true; }

if [ "$MODE" = "ask" ] && [ -z "$ASK_PROMPT" ] && [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
    ASK_PROMPT="${POSITIONAL_ARGS[*]}"
fi
if [ "$MODE" = "ask" ] && [ -z "$ASK_PROMPT" ]; then
    echo "ERROR: --ask requires a prompt." >&2; usage; exit 1
fi

# --- Locate llama.cpp binaries -----------------------------------------------
LLAMA_SERVER=""
for candidate in \
    "$REPO_DIR/llama-b10219-custom/bin/llama-server" \
    "$LLAMA_DIR/build/bin/llama-server" \
    "$LLAMA_DIR/bin/llama-server" \
    "$LLAMA_DIR/llama-b10219/llama-server" \
    "$LLAMA_DIR/llama-*/llama-server"; do
    case "$candidate" in
        *\**) continue ;;
    esac
    if [ -x "$candidate" ]; then LLAMA_SERVER="$candidate"; break; fi
done
if [ -z "$LLAMA_SERVER" ]; then
    for dir in "$LLAMA_DIR"/llama-*/; do
        [ -x "$dir/llama-server" ] && { LLAMA_SERVER="$dir/llama-server"; break; }
    done
fi
if [ -z "$LLAMA_SERVER" ] || [ ! -x "$LLAMA_SERVER" ]; then
    echo "ERROR: llama-server not found in $LLAMA_DIR." >&2
    echo "  Build it once with:" >&2
    echo "    cd $LLAMA_DIR && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \\" >&2
    echo "      && cmake --build build -j\$(nproc) --target llama-server" >&2
    exit 1
fi

LLAMA_BIN_DIR="$(dirname "$LLAMA_SERVER")"
if ls "$LLAMA_BIN_DIR"/libllama*.so* "$LLAMA_BIN_DIR"/libggml*.so* >/dev/null 2>&1; then
    LLAMA_LIB_DIR="$LLAMA_BIN_DIR"
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: model not found at $MODEL_PATH" >&2
    echo "  Set MODEL_PATH to your GGUF." >&2
    exit 1
fi

log_info "Starting llama.cpp + Gemma 4 (NVIDIA/Linux, max-context-first)..."
log_info "  backend: $LLAMA_SERVER"
log_info "  model:   $MODEL_PATH"
log_info "  gpu layers: $GPU_LAYERS  |  context: $CONTEXT_TOKENS  |  KV: $KV_TYPE  |  port: $SERVER_PORT"

PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup SIGINT SIGTERM EXIT

# --- CPU optimization flags --------------------------------------------------
# Applied whenever ANY layer runs on CPU (GPU_LAYERS < 30). Tuned for the
# Ryzen 5 8645HS (5c/10t, AVX-512/VNNI/BF16): thread pinning keeps L2 warm
# across the non-offloaded layers, prio prevents preemption during long prompts.
CPU_OPTS=()
if [ "${GPU_LAYERS:-0}" -lt 30 ]; then
    CPU_OPTS+=(
        -ub 128
        --cpu-strict 1
        --prio 2
    )
    # Pin to physical cores (0..n-1). On the 8645HS all 5 cores are equal,
    # but pinning still wins +5-15% by stopping scheduler migration.
    NPROC_N1=$(( $(nproc) - 1 ))
    [ "$NPROC_N1" -lt 1 ] && NPROC_N1=0
    CPU_OPTS+=(--cpu-range 0-$NPROC_N1)
fi

# --- KV cache type (q4_0 for max context, q8_0 for max quality) ---------------
if [ "$KV_TYPE" = "q8_0" ]; then
    KV_OPTS=(-ctk q8_0 -ctv q8_0)
else
    KV_OPTS=(-ctk q4_0 -ctv q4_0)
fi

# --- Flash Attention + micro-batch (measured winners) -------------------------
GPU_OPTS=(-ub 128 -fa on)

# --- Common llama.cpp flags --------------------------------------------------
LLAMA_COMMON=(
    -m "$MODEL_PATH"
    -ngl "$GPU_LAYERS"
    -c "$CONTEXT_TOKENS"
    -np 1
    --temp 0.6
    --repeat-penalty 1.18
)
if [ -n "$CHAT_TEMPLATE" ]; then
    LLAMA_COMMON+=(--chat-template-file "$CHAT_TEMPLATE")
fi
if [ -n "${THREADS}" ]; then
    LLAMA_COMMON+=(-t "$THREADS")
fi
LLAMA_COMMON+=("${KV_OPTS[@]}")
LLAMA_COMMON+=("${GPU_OPTS[@]}")
if [ ${#CPU_OPTS[@]} -gt 0 ]; then
    LLAMA_COMMON+=("${CPU_OPTS[@]}")
fi
if [ "${USE_REPACK:-0}" != "1" ]; then
    LLAMA_COMMON+=(--no-repack)
fi

echo "============================================================"
echo " llama.cpp + Gemma 4  (NVIDIA/Linux + CUDA)"
echo " Max-context-first auto-configuration"
echo "============================================================"
echo "   backend:    $LLAMA_SERVER"
echo "   model:      $MODEL_PATH"
if [ "${TOTAL_VRAM_MB:-0}" -gt 0 ]; then
    L_MB=$(( GPU_LAYERS * PER_LAYER_MB ))
    KV_MB=$(( TOTAL_VRAM_MB - OVERHEAD_MB - L_MB ))
    echo "   GPU VRAM:   $TOTAL_VRAM_MB MiB"
    echo "   gpu layers: $GPU_LAYERS  |  context: $CONTEXT_TOKENS tok  |  KV: $KV_TYPE"
    echo "   port:       $SERVER_PORT"
    echo
    echo "   VRAM budget (measured, Q2_K Gemma 4 26B-A4B):"
    echo "     $GPU_LAYERS model layers    ~ $L_MB MiB  (CUDA speed)"
    echo "     KV cache ($KV_TYPE)   ~ $KV_MB MiB  (context)"
    echo "     CUDA overhead         ~ $OVERHEAD_MB MiB"
    echo
    if [ "$GPU_LAYERS" -gt 0 ]; then
        echo "   [MAX-CONTEXT MODE] Highest layer count reaching native context."
    else
        echo "   [CPU-ONLY MODE]"
    fi
    echo "   Adjust: GPU_LAYERS=N ./start-linux-gpu.sh"
else
    echo "   gpu layers: $GPU_LAYERS  |  context: $CONTEXT_TOKENS tok  |  port: $SERVER_PORT"
    echo "   (No NVIDIA GPU detected — CPU-only)"
fi
echo "============================================================"

ensure_server_running() {
    if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q '"status":"ok"'; then
        log_info "-> llama.cpp Server is ready on port $SERVER_PORT."
        return 0
    fi
    if ! curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" >/dev/null 2>&1; then
        log_info "-> Launching llama.cpp Server (GPU layers: $GPU_LAYERS)..."
        _llama_lib_path="${LLAMA_LIB_DIR:-}"
        [ -n "${LD_LIBRARY_PATH:-}" ] && _llama_lib_path="${_llama_lib_path:+$_llama_lib_path:}$LD_LIBRARY_PATH"
        [ -n "$_llama_lib_path" ] && LLAMA_ENV_PREFIX="LD_LIBRARY_PATH=$_llama_lib_path" || LLAMA_ENV_PREFIX=""
        stdbuf -oL -eL env $LLAMA_ENV_PREFIX "$LLAMA_SERVER" "${LLAMA_COMMON[@]}" \
            --host "$SERVER_HOST" --port "$SERVER_PORT" > "$REPO_DIR/llama_server.log" 2>&1 &
        SERVER_PID=$!
        PIDS+=("$SERVER_PID")
    fi
    log_info "-> Loading model weights into memory (please wait)..."
    local ready=0
    for i in $(seq 1 600); do
        if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q '"status":"ok"'; then
            log_info "-> Model ready."; ready=1; break
        fi
        [ -n "${SERVER_PID:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null && {
            echo "ERROR: Server crashed during startup. Check $REPO_DIR/llama_server.log" >&2; exit 1
        }
        [ "$DEBUG" = "1" ] && [ $((i % 10)) -eq 0 ] && log_info "-> Still loading... (${i}s)"
        sleep 1
    done
    [ "$ready" = "0" ] && {
        echo "ERROR: Timed out waiting for Server on port $SERVER_PORT." >&2; exit 1
    }
}

# Warm the OS page cache / pin experts in RAM before serving requests so that
# expert loads hit RAM instead of faulting from the slow /mnt/e disk.
ram_cache_preheat

if [ "$MODE" = "ask" ] || [ "$MODE" = "chat" ]; then
    ensure_server_running
    if [ "$MODE" = "ask" ]; then
        log_info "-> Asking Gemma 4: $ASK_PROMPT"
        exec python3 "$CHAT_SCRIPT" --ask "$ASK_PROMPT"
    fi
    log_info "-> Starting interactive chat with Gemma 4..."
    exec python3 "$CHAT_SCRIPT" --chat "${POSITIONAL_ARGS[@]}"
fi

# --- Default mode: Pi agent via OpenAI-compatible server -------------------
mkdir -p "$PI_CONFIG_DIR"
if [ ! -f "$PI_MODELS_FILE" ] || ! grep -q "turbofieldfare" "$PI_MODELS_FILE" ]; then
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
          "contextWindow": 262144,
          "maxTokens": 8192,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
EOF
    log_info "-> Wrote $PI_MODELS_FILE"
fi

ensure_server_running
log_info "-> Launching Pi Agent..."
export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0
exec pi --model "$PI_MODEL" "${POSITIONAL_ARGS[@]}"
