#!/bin/bash

# Ensure Homebrew binaries are in PATH
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

TURBO_DIR="$HOME/turbo-fieldfare"
MODEL_PATH="scratch/gemma4.gturbo"
PI_MODEL="turbofieldfare/gemma-4-26b-a4b-it"
PI_CONFIG_DIR="$HOME/.pi/agent"
PI_MODELS_FILE="$PI_CONFIG_DIR/models.json"

echo "Starting Pi Agent + Gemma 4 Local Stack..."

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
    sleep 3
    if ! kill -0 $TURBO_PID 2>/dev/null; then
        echo "ERROR: TurboFieldfare crashed. Check $TURBO_DIR/turbo_server.log"
        exit 1
    fi
fi

# 3. Launch Pi Agent
echo "-> Launching Pi Agent..."

export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0

pi --model "$PI_MODEL" "$@"
