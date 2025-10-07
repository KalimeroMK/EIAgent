#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] EIAgent setup (Ollama + agent-proxy)"

# 1) checks
for c in docker; do
  command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] $c not found"; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "[ERROR] docker compose v2 required"; exit 1; }

# 2) env
[ -f .env ] || { echo "[INFO] creating .env from example"; cp .env.example .env; }
grep -q '^API_TOKEN=' .env || echo "API_TOKEN=$(openssl rand -hex 24)" >> .env
grep -q '^MODEL_NAME=' .env || echo "MODEL_NAME=qwen2.5-coder:7b" >> .env
grep -q '^OLLAMA_BASE=' .env || echo "OLLAMA_BASE=http://ollama:11434" >> .env
grep -q '^BIND=' .env || echo "BIND=0.0.0.0" >> .env
grep -q '^PORT=' .env || echo "PORT=6969" >> .env
grep -q '^ALLOW_CMDS=' .env || echo "ALLOW_CMDS=composer,php,git,npm,pnpm,yarn,mkdir,cp,mv,ls,chmod,php-cs-fixer,phpstan" >> .env
grep -q '^BLOCK_TOKENS=' .env || echo "BLOCK_TOKENS= rm , sudo , curl , wget , chmod 777 , :(){ , mkfs , dd" >> .env

# 3) start services
echo "[INFO] docker compose up -d"
docker compose up -d --build

# 4) pull model
echo "[INFO] pulling model qwen2.5-coder:7b (first time can take a while)"
docker compose run --rm ollama ollama pull qwen2.5-coder:7b || true

# 5) health check
echo "[INFO] checking agent-proxy"
sleep 2
curl -s -X POST "http://127.0.0.1:6969/v1/agent/complete" \
  -H "Content-Type: application/json" \
  -H "X-API-KEY: $(grep '^API_TOKEN=' .env | cut -d= -f2-)" \
  -d '{"prompt":"ping"}' || true

echo "[DONE] EIAgent is up.
- API: http://<server-ip>:6969/v1/agent/complete
- Header: X-API-KEY: $(grep '^API_TOKEN=' .env | cut -d= -f2-)
"
SH

chmod +x install.sh
