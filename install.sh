#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EIGENT_DIR="/opt/eigent"
EIGENT_REPO="https://github.com/eigent-ai/eigent.git"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  if ! command_exists "$1"; then
    echo "[ERROR] Required command '$1' is not installed." >&2
    exit 1
  fi
}

require_command git
require_command docker
require_command curl

if command_exists docker compose; then
  COMPOSE_CMD="docker compose"
elif command_exists docker-compose; then
  COMPOSE_CMD="docker-compose"
else
  echo "[ERROR] Docker Compose v2 or v1 is required." >&2
  exit 1
fi

if [ ! -d "$EIGENT_DIR" ]; then
  echo "[INFO] Cloning Eigent into $EIGENT_DIR"
  git clone "$EIGENT_REPO" "$EIGENT_DIR"
fi

if [ ! -x "$EIGENT_DIR/eigent" ]; then
  echo "[INFO] Building Eigent CLI"
  if command_exists cargo; then
    (cd "$EIGENT_DIR" && cargo build --release)
    cp "$EIGENT_DIR/target/release/eigent" "$EIGENT_DIR/eigent"
  elif [ -f "$EIGENT_DIR/Makefile" ]; then
    (cd "$EIGENT_DIR" && make build)
    if [ ! -x "$EIGENT_DIR/eigent" ]; then
      echo "[ERROR] Eigent binary not found after make build." >&2
      exit 1
    fi
  else
    echo "[ERROR] Unable to build Eigent CLI. Install Rust (cargo) or follow Eigent build instructions." >&2
    exit 1
  fi
fi

cd "$REPO_DIR"

if [ ! -f .env ]; then
  echo "[INFO] Creating .env from template"
  cp .env.example .env
fi

set -a
source .env
set +a

MODEL_NAME=${MODEL_NAME:-qwen2.5-coder-7b-cpu}
AGENT_PORT=${AGENT_PORT:-6969}
API_TOKEN=${API_TOKEN:-}
OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://localhost:11434}

export EIGENT_BIN

$COMPOSE_CMD pull

$COMPOSE_CMD up -d ollama

echo "[INFO] Waiting for Ollama to become available..."
READY=false
for _ in {1..30}; do
  if curl -fsS "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 2
done

if [ "$READY" != true ]; then
  echo "[ERROR] Ollama did not become ready in time." >&2
  exit 1
fi

$COMPOSE_CMD exec -T ollama ollama pull "$MODEL_NAME"

$COMPOSE_CMD up -d

echo "[INFO] EIAgent stack is up and running."
echo "[INFO] Try the proxy with:"
echo "curl -X POST http://localhost:${AGENT_PORT}/v1/agent/complete \\"
echo "  -H 'X-API-KEY: ${API_TOKEN}' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"prompt\": \"Write a PHP function that validates an email.\"}'"
