#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] EIAgent setup (Ollama + agent-proxy)"

# --- prerequisites ---
command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker not found"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "[ERROR] docker compose v2 required"; exit 1; }

# --- environment setup ---
if [ ! -f .env ]; then
  echo "[INFO] Creating .env from example"
  cp .env.example .env
fi

if grep -q '^API_TOKEN=CHANGE_ME' .env; then
  TOKEN=$(openssl rand -hex 24 || echo "SET_A_SECRET_TOKEN")
  sed -i "s/^API_TOKEN=.*/API_TOKEN=$TOKEN/" .env
fi

grep -q '^MODEL_NAME='  .env || echo "MODEL_NAME=qwen2.5-coder:7b" >> .env
grep -q '^OLLAMA_BASE=' .env || echo "OLLAMA_BASE=http://ollama:11434" >> .env
grep -q '^BIND='        .env || echo "BIND=0.0.0.0" >> .env
grep -q '^PORT='        .env || echo "PORT=6969" >> .env
grep -q '^ALLOW_CMDS='  .env || echo "ALLOW_CMDS=composer,php,git,npm,pnpm,yarn,mkdir,cp,mv,ls,chmod,php-cs-fixer,phpstan" >> .env
grep -q '^BLOCK_TOKENS=' .env || echo "BLOCK_TOKENS= rm , sudo , curl , wget , chmod 777 , :(){ , mkfs , dd" >> .env

TOKEN=$(grep '^API_TOKEN=' .env | cut -d= -f2-)
MODEL=$(grep '^MODEL_NAME=' .env | cut -d= -f2-)

# --- build and up ---
echo "[INFO] Starting docker compose (agent-proxy + Ollama)"
docker compose up -d --build

# --- wait for ollama ---
echo "[INFO] Waiting for Ollama to become ready..."
TRIES=60
until curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1 || [ $TRIES -le 0 ]; do
  sleep 1; TRIES=$((TRIES-1))
done
if [ $TRIES -le 0 ]; then
  echo "[WARN] Ollama not reachable yet, continuing anyway."
fi

# --- pull model ---
echo "[INFO] Pulling model: $MODEL"
if ! docker compose exec -T ollama ollama pull "$MODEL"; then
  echo "[WARN] exec pull failed, trying HTTP pull..."
  curl -fsS -X POST http://127.0.0.1:11434/api/pull \
       -H "Content-Type: application/json" \
       -d "{\"name\":\"$MODEL\"}" || true
fi

# --- health check ---
sleep 3
echo "[INFO] Checking agent-proxy..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:6969/v1/agent/complete" \
  -H "Content-Type: application/json" -H "X-API-KEY: $TOKEN" \
  -d '{"prompt":"ping"}')

echo ""
echo "✅ [DONE] EIAgent is ready."
echo "---------------------------------------------"
echo " API Endpoint : http://<server-ip>:6969/v1/agent/complete"
echo " API Key      : $TOKEN"
echo " Health Check : HTTP $HTTP_CODE (200 = OK)"
echo "---------------------------------------------"
