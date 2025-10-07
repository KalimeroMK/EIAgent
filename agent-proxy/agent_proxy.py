import json
import logging
import os
import subprocess
from typing import Any, Dict

import requests
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s in %(module)s: %(message)s")

app = Flask(__name__)

API_TOKEN = os.environ.get("API_TOKEN", "")
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen2.5-coder-7b-cpu")
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
AGENT_PORT = int(os.environ.get("AGENT_PORT", "6969"))
EIGENT_BIN = os.environ.get("EIGENT_BIN", "eigent")


class AgentProxyError(Exception):
    """Raised when the agent proxy cannot satisfy the request."""


def ensure_model(model: str) -> None:
    """Verify that the Ollama model exists and pull it if missing."""
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=10)
        resp.raise_for_status()
        models = resp.json().get("models", [])
        if any(entry.get("name") == model for entry in models):
            return
    except requests.RequestException as exc:
        logging.warning("Failed to list Ollama models: %s", exc)

    logging.info("Pulling Ollama model '%s'...", model)
    try:
        pull_resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/pull",
            json={"name": model},
            timeout=(10, 600),
        )
        pull_resp.raise_for_status()
    except requests.RequestException as exc:
        raise AgentProxyError(f"Unable to pull model {model}: {exc}") from exc


def run_eigent(payload: Dict[str, Any]) -> str:
    """Execute the Eigent CLI with the provided payload."""
    try:
        process = subprocess.run(
            [EIGENT_BIN, "run", "--stdin-json"],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        logging.error("Eigent binary not found at %s", EIGENT_BIN)
        raise AgentProxyError(f"Eigent binary not found at {EIGENT_BIN}") from exc

    if process.returncode != 0:
        logging.error("Eigent run failed: %s", process.stderr.strip())
        raise AgentProxyError(process.stderr.strip() or "Eigent run failed")

    return process.stdout.strip()


@app.route("/v1/agent/complete", methods=["POST"])
def complete() -> Any:
    if API_TOKEN and request.headers.get("X-API-KEY") != API_TOKEN:
        return jsonify({"ok": False, "error": "Unauthorized"}), 401

    try:
        data = request.get_json(force=True)
    except Exception:  # pylint: disable=broad-exception-caught
        return jsonify({"ok": False, "error": "Invalid JSON payload"}), 400

    prompt = data.get("prompt")
    if not prompt:
        return jsonify({"ok": False, "error": "Missing 'prompt' field"}), 400

    ensure_model(MODEL_NAME)

    payload = {
        "provider": "ollama",
        "model": MODEL_NAME,
        "base_url": OLLAMA_BASE_URL,
        "input": prompt,
    }

    try:
        output = run_eigent(payload)
    except AgentProxyError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500

    return jsonify({"ok": True, "output": output})


def main() -> None:
    app.run(host="0.0.0.0", port=AGENT_PORT)


if __name__ == "__main__":
    main()
