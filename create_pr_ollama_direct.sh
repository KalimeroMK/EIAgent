# === EIAgent • Create PR: Ollama-direct agent + write_files + safe run_shell ===
set -euo pipefail

BR="feat/ollama-direct-agent"
FILE="agent-proxy/agent_proxy.py"

# 0) Ensure git is clean enough
git fetch origin
git checkout main
git pull --rebase origin main
git checkout -b "$BR" || git checkout "$BR"

# 1) Backup and replace agent_proxy.py
mkdir -p agent-proxy
cp -f "$FILE" "${FILE}.bak.$(date +%s)" 2>/dev/null || true

cat > "$FILE" << 'PY'
from flask import Flask, request, jsonify
import os, requests, subprocess, shlex

app = Flask(__name__)

API_TOKEN   = os.environ.get("API_TOKEN", "")
MODEL_NAME  = os.environ.get("MODEL_NAME", "qwen2.5-coder:7b")
OLLAMA_BASE = os.environ.get("OLLAMA_BASE", "http://ollama:11434")
BIND        = os.environ.get("BIND", "0.0.0.0")
PORT        = int(os.environ.get("PORT", "6969"))

# Allow/Block lists for shell (safety)
ALLOW_CMDS   = [c.strip() for c in os.environ.get(
    "ALLOW_CMDS",
    "composer,php,git,npm,pnpm,yarn,mkdir,cp,mv,ls,chmod,php-cs-fixer,phpstan"
).split(",")]

BLOCK_TOKENS = [t.strip() for t in os.environ.get(
    "BLOCK_TOKENS",
    " rm , sudo , curl , wget , chmod 777 , :(){ , mkfs , dd "
).split(",")]

DEFAULT_SYSTEM = (
    "You are a senior Laravel/PHP and full-stack coding assistant. "
    "Write clean, modern code with brief English comments. Keep responses concise."
)

def ensure_model():
    """Ensure the model exists in Ollama; pull 7B base if missing."""
    try:
        r = requests.get(f"{OLLAMA_BASE}/api/tags", timeout=15)
        r.raise_for_status()
        names = {m.get("name") for m in r.json().get("models", [])}
        if MODEL_NAME in names:
            return
    except Exception:
        pass
    try:
        requests.post(f"{OLLAMA_BASE}/api/pull", json={"name": "qwen2.5-coder:7b"}, timeout=600)
    except Exception:
        pass

def call_ollama(prompt, system):
    """Sync call to Ollama /api/generate (no stream)."""
    payload = {"model": MODEL_NAME, "prompt": f"{system}\n\n{prompt}", "stream": False}
    r = requests.post(f"{OLLAMA_BASE}/api/generate", json=payload, timeout=900)
    r.raise_for_status()
    data = r.json()
    return (data.get("response") or "").strip()

def sanitize_cmd(line: str):
    """Allowlist + blocklist for shell commands."""
    low = f" {line.lower()} "
    for bad in BLOCK_TOKENS:
        if bad and bad in low:
            raise RuntimeError(f"Blocked token: {bad.strip()}")
    parts = shlex.split(line)
    if not parts:
        raise RuntimeError("Empty command")
    root = os.path.basename(parts[0])
    if root not in ALLOW_CMDS:
        raise RuntimeError(f"Command not allowed: {root}")
    return parts

def run_shell(commands, workdir):
    logs = []
    for line in commands:
        line = line.strip()
        if not line:
            continue
        parts = sanitize_cmd(line)
        logs.append(f"$ {' '.join(parts)}")
        proc = subprocess.Popen(parts, cwd=workdir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out = proc.communicate()[0]
        logs.append(out)
        logs.append(f"[exit {proc.returncode}]")
        if proc.returncode != 0:
            break
    return "\n".join(logs)

@app.before_request
def auth():
    if request.headers.get("X-API-KEY", "") != API_TOKEN:
        return jsonify({"ok": False, "error": "unauthorized"}), 401

@app.post("/v1/agent/complete")
def complete():
    data = request.get_json(force=True)
    prompt      = data.get("prompt", "")
    system      = data.get("system") or DEFAULT_SYSTEM
    write_files = data.get("write_files") or []  # [{ "path":"/abs/path/file.php", "content":"..." }]
    run_req     = data.get("run_shell")  or {}   # { "workdir":"/abs/path", "commands":[...] }

    ensure_model()

    # 1) Model output
    try:
        output = call_ollama(prompt, system)
    except Exception as e:
        return jsonify({"ok": False, "error": f"ollama: {e}"}), 500

    # 2) Write files (optional)
    file_report = []
    for f in write_files:
        try:
            p = f.get("path"); c = f.get("content", "")
            if not p or not isinstance(c, str):
                raise RuntimeError("bad file spec")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(c)
            file_report.append(f"wrote: {p} ({len(c)} bytes)")
        except Exception as e:
            file_report.append(f"error: {p}: {e}")

    # 3) Run shell (optional)
    shell_log = ""
    if run_req:
        try:
            workdir  = run_req.get("workdir") or os.getcwd()
            commands = [l for l in (run_req.get("commands") or []) if l.strip()]
            shell_log = run_shell(commands, workdir)
        except Exception as e:
            shell_log = f"shell error: {e}"

    return jsonify({"ok": True, "output": output, "files": file_report, "shell": shell_log})

if __name__ == "__main__":
    app.run(host=BIND, port=PORT)
PY

# 2) Ensure .env.example has required keys
touch .env.example
grep -q '^OLLAMA_BASE=' .env.example || echo 'OLLAMA_BASE=http://ollama:11434' >> .env.example
grep -q '^ALLOW_CMDS='  .env.example || echo 'ALLOW_CMDS=composer,php,git,npm,pnpm,yarn,mkdir,cp,mv,ls,chmod,php-cs-fixer,phpstan' >> .env.example
grep -q '^BLOCK_TOKENS=' .env.example || echo 'BLOCK_TOKENS= rm , sudo , curl , wget , chmod 777 , :(){ , mkfs , dd' >> .env.example

# 3) Commit
git add "$FILE" .env.example
git commit -m "feat(agent): Ollama-direct proxy + write_files & safe run_shell (no eigent CLI)"

# 4) Push and create PR (auto if gh exists)
