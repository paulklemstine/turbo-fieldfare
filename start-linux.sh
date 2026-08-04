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
# Gemma 4 26B-A4B. Default: official Google checkpoint at Q4_0 (~14 GB).
#
# NOTE: Q2_K / Q3_K_S / IQ4_XS quantiles produce garbled output on CPU for
# this MoE architecture (the output layer gets destroyed by sub-4-bit
# quantization). Q4_0 is the minimum quality that produces coherent text.
#
# Q4_0 requires --no-repack on memory-constrained machines (see below):
# the repack step needs a contiguous allocation larger than this machine's
# RAM. --no-repack avoids that and works fine, just slightly slower.
#
# Override MODEL_PATH to use a different GGUF (e.g. abliterated, Q5_K_M,
# Q8_0) or to point at a copy on another drive.
if [ -f "$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf" ]; then
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf"
elif [ -f "$REPO_DIR/models/gemma-4-26B-A4B-it-abliterated.Q4_0.gguf" ]; then
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it-abliterated.Q4_0.gguf"
elif [ -f "/mnt/e/Models/gemma-4-26B-A4B-it.Q4_0.gguf" ]; then
    DEFAULT_MODEL_PATH="/mnt/e/Models/gemma-4-26B-A4B-it.Q4_0.gguf"
else
    DEFAULT_MODEL_PATH="$REPO_DIR/models/gemma-4-26B-A4B-it.Q4_0.gguf"
fi

MODEL_PATH="${MODEL_PATH:-$DEFAULT_MODEL_PATH}"
# Chat template: use the model's built-in template by default. The GGUF ships
# with a working gemma chat template. Our custom chat_template.jinja is kept
# as an override (set CHAT_TEMPLATE env to use it) but the built-in handles
# Gemma 4's <start_of_turn>/<end_of_turn> tokens correctly and also handles
# the "thinking" mode channel tags (<|channel|>thought) that our simple
# template did not strip, causing garbled output.
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"

# Transformer layers offloaded to GPU (0 = CPU mode, 18 = RTX 4050 GPU mode)
GPU_LAYERS="${GPU_LAYERS:-}"
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
  --cpu            Force CPU-only mode (equivalent to GPU_LAYERS=0)
  --gpu            Force GPU mode (honor GPU_LAYERS if set)
  --threads N      CPU threads to use (default: nproc on CPU-only, auto on GPU)
  (no options)     Launch the Pi coding agent (tool use); remaining args go to pi
  -h, --help       Show this help

Environment overrides:
  LLAMA_DIR        llama.cpp checkout (default $LLAMA_DIR)
  MODEL_PATH       GGUF model file (default $MODEL_PATH)
  GPU_LAYERS       layers offloaded to GPU (default: auto-detect)
  CONTEXT_TOKENS   context window size   (default $CONTEXT_TOKENS)
  SERVER_PORT      server listen port    (default $SERVER_PORT)
  USE_REPACK       set to 1 to enable weight repack (needs >14 GB RAM)

Performance notes (CPU-only):
  This custom llama.cpp build uses MADV_DONTNEED on expert weight pages
  after loading. The 14 GB Q4_0 model has 90 expert tensors (~12 GB) that
  are marked as "not needed" while the ~1.47 GB core (attention, shared MLP,
  norms, embeddings) stays resident in RAM. Expert weights are loaded
  on-demand during inference from the page cache (fast) or disk.

  WSL2 (default 5.7GB RAM limit):
    ~0.72 tok/s average (warm cache ~0.77 tok/s)
    First request ~0.66 tok/s (cold cache). RSS ~4.4 GB.

  Windows native (11.7GB RAM):
    ~4.61 tok/s warm (best 5.43 tok/s)
    6.4x faster than WSL2 due to more available RAM for page cache.
    Optimal config: repack ON + 3 threads + q4_0 KV + ub 256.

  When running under WSL2, ./start.sh automatically dispatches to
  start-windows.cmd for native Windows execution (much faster). Use the
  --wsl flag to force WSL2 native mode (uses MADV_DONTNEED patch).

  This mirrors the approach used by TurboFieldfare on Mac: keep the core
  resident, stream experts from disk. The GPU machine will be far faster.

Examples:
  $0 --ask "What is the capital of France?"
  $0 --chat
  $0 --chat --cpu --threads 4
  $GPU_LAYERS=15 $0 "List the files in this repository"
EOF
}

FORCE_CPU=0
FORCE_GPU=0
DEBUG=0
MODE="pi"
ASK_PROMPT=""
THREADS=""
POSITIONAL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --cpu)
            FORCE_CPU=1
            shift
            ;;
        --gpu)
            FORCE_GPU=1
            shift
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --threads)
            shift
            THREADS="${1:-}"
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

detect_gpu_layers() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo 0
        return
    fi
    # 10 layers uses ~3.2 GB VRAM, fitting safely in physical GPU VRAM without thrashing
    echo 10
}

if [ "$FORCE_CPU" = "1" ]; then
    GPU_LAYERS=0
elif [ -n "${GPU_LAYERS:-}" ]; then
    # Respect explicit user environment override
    :
else
    # Enable GPU assist by default on machines with NVIDIA GPU
    GPU_LAYERS=$(detect_gpu_layers)
fi

# Default CPU thread count to nproc for CPU-only machines
if [ -z "$THREADS" ] && [ "$GPU_LAYERS" = "0" ]; then
    THREADS="$(nproc)"
fi

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

# --- Locate llama.cpp binaries -----------------------------------------------
# Search for llama-server in common locations: CMake build dirs, bare checkout,
# and pre-built release bundles (llama-BIN-linux-x64/llama-server).
LLAMA_SERVER=""
LLAMA_LIB_DIR=""
for candidate in \
    "$REPO_DIR/llama-b10219-custom/bin/llama-server" \
    "$LLAMA_DIR/build/bin/llama-server" \
    "$LLAMA_DIR/bin/llama-server" \
    "$LLAMA_DIR/llama-b10219/llama-server" \
    "$LLAMA_DIR/llama-*/llama-server"; do
    # Skip the glob literal if no match
    case "$candidate" in
        *\**)
            continue
            ;;
    esac
    if [ -x "$candidate" ]; then
        LLAMA_SERVER="$candidate"
        break
    fi
done

# Fallback: glob match for pre-built release bundles
if [ -z "$LLAMA_SERVER" ]; then
    for dir in "$LLAMA_DIR"/llama-*/; do
        if [ -x "$dir/llama-server" ]; then
            LLAMA_SERVER="$dir/llama-server"
            break
        fi
    done
fi

if [ -z "$LLAMA_SERVER" ] || [ ! -x "$LLAMA_SERVER" ]; then
    echo "ERROR: llama-server not found in $LLAMA_DIR." >&2
    echo "  Build it once with:" >&2
    echo "    cd $LLAMA_DIR && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \\" >&2
    echo "      && cmake --build build -j\$(nproc) --target llama-server" >&2
    echo "  Or download a pre-built release bundle for your platform." >&2
    exit 1
fi

# If the binary lives next to its shared libs (pre-built bundle), ensure the OS
# can find them without requiring system-wide installs (e.g. libgomp).
LLAMA_BIN_DIR="$(dirname "$LLAMA_SERVER")"
if ls "$LLAMA_BIN_DIR"/libllama*.so* "$LLAMA_BIN_DIR"/libggml*.so* >/dev/null 2>&1; then
    LLAMA_LIB_DIR="$LLAMA_BIN_DIR"
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: model not found at $MODEL_PATH" >&2
    echo "  Download the Q2_K quant (mradermacher/gemma-4-26B-A4B-it-abliterated-GGUF)" >&2
    echo "  or set MODEL_PATH to your GGUF." >&2
    exit 1
fi

log_info "Starting llama.cpp + Gemma 4 (NVIDIA/Linux) Local Stack..."
log_info "  backend: $LLAMA_SERVER"
log_info "  model:   $MODEL_PATH"
log_info "  gpu layers: $GPU_LAYERS  |  context: $CONTEXT_TOKENS  |  port: $SERVER_PORT"

PIDS=()

cleanup() {
    if [ "$DEBUG" = "1" ]; then
        echo -e "\nShutting down background processes..."
    fi
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup SIGINT SIGTERM EXIT

# --- CPU optimization flags (applied only in CPU-only mode) ----------------
# Discovered by benchmarking on Intel N150 (4c/4t, AVX2/AVX_VNNI, 5.7GB RAM):
#
# 1. KV cache quantization (q8_0): halves KV cache memory. At f16 the 30-layer
#    model with 4096 context needs ~1.6 GB for KV alone; q8_0 drops it to ~0.8 GB.
#    This is what prevents OOM kills past ~388 tokens during long replies.
#
# 2. Physical ubatch 256: the default 512 can spike memory during prompt
#    processing of multi-token prompts. 256 trades a few % peak throughput
#    for lower peak RSS.
#
# 3. --cpu-strict 1: pins worker threads to their physical cores. On the
#    N150 (all E-cores, no SMT) this prevents the scheduler from migrating
#    threads and losing L2 cache warmth between layers.
#
# 4. --prio 2: raises the server thread priority so background tasks don't
#    preempt the inference worker for the ~50-100 s it takes to process a
#    prompt on this box.
#
# On GPU machines these are skipped; the GPU batch path dominates and the
# CPU-side buffers are small.
CPU_OPTS=()
if [ "$GPU_LAYERS" = "0" ]; then
    CPU_OPTS=(
        -ctk q8_0 -ctv q8_0
        -ub 256
        --cpu-strict 1
        --prio 2
    )
fi

# --- Common llama.cpp flags ----------------------------------------------
LLAMA_COMMON=(
    -m "$MODEL_PATH"
    -ngl "$GPU_LAYERS"
    -c "$CONTEXT_TOKENS"
    -np 1
    --temp 0.6
    --repeat-penalty 1.18
)
# Chat template: pass through the custom template only if CHAT_TEMPLATE is set.
# When unset (default), llama-server uses the template embedded in the GGUF.
if [ -n "$CHAT_TEMPLATE" ]; then
    LLAMA_COMMON+=(--chat-template-file "$CHAT_TEMPLATE")
fi
# Stop words: the --stop/-r flags were removed in newer llama.cpp builds.
# Stop sequences are now passed per-request via the API "stop" field, which
# Scripts/chat.py already does (see the send() function).

# Tune CPU thread count (auto-detect on CPU-only, skip on GPU)
if [ -n "${THREADS}" ]; then
    LLAMA_COMMON+=(-t "$THREADS")
fi

# Append CPU-only optimizations
if [ ${#CPU_OPTS[@]} -gt 0 ]; then
    LLAMA_COMMON+=("${CPU_OPTS[@]}")
fi

# --no-repack: the repack step needs a contiguous allocation larger than
# this machine's RAM (Q4_0 tries for ~13.8 GB). Disabling repack avoids
# that allocation; it is slightly slower but works on memory-limited
# machines. On a machine with more RAM or a GPU, you can drop this by
# setting USE_REPACK=1.
if [ "${USE_REPACK:-0}" != "1" ]; then
    LLAMA_COMMON+=(--no-repack)
fi

ensure_server_running() {
    if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q '"status":"ok"'; then
        log_info "-> llama.cpp Server is ready on port $SERVER_PORT."
        return 0
    fi

    if ! curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" >/dev/null 2>&1; then
        log_info "-> Launching llama.cpp Server (GPU layers: $GPU_LAYERS)..."
        # Build a library path that covers both pre-bundled .so files and any
        # system CUDA installation.
        _llama_lib_path="${LLAMA_LIB_DIR:-}"
        if [ -n "${LD_LIBRARY_PATH:-}" ]; then
            _llama_lib_path="${_llama_lib_path:+$_llama_lib_path:}$LD_LIBRARY_PATH"
        fi
        if [ -n "$_llama_lib_path" ]; then
            LLAMA_ENV_PREFIX="LD_LIBRARY_PATH=$_llama_lib_path"
        else
            LLAMA_ENV_PREFIX=""
        fi
        stdbuf -oL -eL env $LLAMA_ENV_PREFIX "$LLAMA_SERVER" "${LLAMA_COMMON[@]}" \
            --host "$SERVER_HOST" --port "$SERVER_PORT" \
            > "$REPO_DIR/llama_server.log" 2>&1 &
        SERVER_PID=$!
        PIDS+=("$SERVER_PID")
    fi

    log_info "-> Loading model weights into memory (please wait)..."
    local ready=0
    for i in $(seq 1 600); do
        if curl -s -m 2 "http://${SERVER_HOST}:${SERVER_PORT}/health" | grep -q '"status":"ok"'; then
            log_info "-> Model ready."
            ready=1
            break
        fi
        if [ -n "${SERVER_PID:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "ERROR: llama.cpp Server crashed during startup. Check $REPO_DIR/llama_server.log" >&2
            exit 1
        fi
        if [ "$DEBUG" = "1" ] && [ $((i % 10)) -eq 0 ]; then
            log_info "-> Still loading model... (${i}s)"
        fi
        sleep 1
    done

    if [ "$ready" = "0" ]; then
        echo "ERROR: Timed out waiting for llama.cpp Server to be ready on port $SERVER_PORT." >&2
        exit 1
    fi
}

# --- Modes that talk directly to the server via the existing chat client ---
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
    log_info "-> Wrote $PI_MODELS_FILE"
fi

# 2. Check/Start llama.cpp Server
ensure_server_running

# 3. Launch Pi Agent
log_info "-> Launching Pi Agent..."
export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0
exec pi --model "$PI_MODEL" "${POSITIONAL_ARGS[@]}"
