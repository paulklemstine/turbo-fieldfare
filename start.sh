#!/bin/bash

# Ensure Python 3.14 (with LiteLLM 1.94+), local binaries, and Homebrew binaries are in PATH
export PATH="$HOME/Library/Python/3.14/bin:$HOME/Library/Python/3.9/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"

TURBO_DIR="$HOME/turbo-fieldfare"
MODEL_PATH="scratch/gemma4.gturbo"
ENTRY_PORT=4000

echo "Starting Claude Code + Gemma 4 Local Stack..."

PIDS=()

cleanup() {
    echo -e "\nShutting down background processes..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

cd "$TURBO_DIR" || exit 1

# 1. Check/Start TurboFieldfare Server (Port 8080)
if curl -s "http://127.0.0.1:8080/health" | grep -q "ok"; then
    echo "-> TurboFieldfare Server is already running on port 8080."
else
    echo "-> Launching TurboFieldfare Server on port 8080..."
    .build/release/TurboFieldfareServer --model "$MODEL_PATH" --port 8080 > turbo_server.log 2>&1 &
    TURBO_PID=$!
    PIDS+=("$TURBO_PID")
    sleep 3
    if ! kill -0 $TURBO_PID 2>/dev/null; then
        echo "ERROR: TurboFieldfare crashed. Check $TURBO_DIR/turbo_server.log"
        exit 1
    fi
fi

# 2. Check/Start Sanitizer Gateway (Port 8085)
if lsof -i :8085 >/dev/null 2>&1; then
    echo "-> Sanitizer Gateway is already running on port 8085."
else
    echo "-> Launching Sanitizer Gateway on port 8085..."
    python3 scratch/sanitizer_gateway.py > scratch/sanitizer.log 2>&1 &
    SAN_PID=$!
    PIDS+=("$SAN_PID")
    sleep 1
fi

# 3. Create LiteLLM Config and Check/Start LiteLLM Proxy (Port 4001)
cat << 'EOF' > litellm_config.yaml
model_list:
  - model_name: "*"
    litellm_params:
      model: "custom_openai/gemma-4-26b-a4b-it"
      api_base: "http://127.0.0.1:8085/v1"
      api_key: "dummy"
general_settings:
  master_key: "sk-local-dev-key"
EOF

if lsof -i :4001 >/dev/null 2>&1; then
    echo "-> LiteLLM Proxy is already running on port 4001."
else
    echo "-> Launching LiteLLM Proxy on port 4001..."
    litellm --config litellm_config.yaml --port 4001 > litellm_proxy.log 2>&1 &
    LITE_PID=$!
    PIDS+=("$LITE_PID")
    sleep 3
fi

# 4. Check/Start Proxy Bridge (Port 4000)
if lsof -i :4000 >/dev/null 2>&1; then
    echo "-> Proxy Bridge is already running on port 4000."
else
    echo "-> Launching Proxy Bridge on port 4000..."
    python3 scratch/proxy_bridge.py > scratch/bridge.log 2>&1 &
    BRIDGE_PID=$!
    PIDS+=("$BRIDGE_PID")
    sleep 1
fi

# 5. Launch Claude Code cleanly with local proxy environment
echo "-> Launching Claude Code..."

unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_API_KEY

export ANTHROPIC_BASE_URL="http://127.0.0.1:$ENTRY_PORT"
export ANTHROPIC_API_KEY="sk-local-dev-key"

export ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-3-5-sonnet-20241022"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-3-5-sonnet-20241022"

export DISABLE_PROMPT_CACHING=1

if [ $# -gt 0 ]; then
    claude --dangerously-skip-permissions "$@"
else
    claude --dangerously-skip-permissions
fi
