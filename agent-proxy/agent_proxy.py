import json
import logging
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

import requests
from flask import Flask, jsonify, request

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s in %(module)s: %(message)s",
)

app = Flask(__name__)

API_TOKEN = os.environ.get("API_TOKEN", "")
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen2.5-coder:7b")
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
AGENT_PORT = int(os.environ.get("AGENT_PORT", "6969"))

ALLOWED_COMMANDS = {
    "composer",
    "php",
    "git",
    "npm",
    "yarn",
    "mkdir",
    "mv",
    "cp",
    "ls",
    "chmod",
    "phpstan",
    "php-cs-fixer",
}

BLOCKED_TOKENS = {
    "rm",
    "sudo",
    "curl",
    "wget",
    "chmod 777",
    "mkfs",
    "dd",
    ":(){",
}


class AgentProxyError(Exception):
    """Raised when the agent proxy cannot satisfy the request."""


class ShellExecutionError(AgentProxyError):
    """Raised when an allowed shell command fails."""


def call_ollama(prompt: str) -> str:
    """Call the Ollama REST API and return the model response."""

    payload = {"model": MODEL_NAME, "prompt": prompt, "stream": False}
    try:
        response = requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json=payload,
            timeout=600,
        )
        response.raise_for_status()
    except requests.RequestException as exc:  # pragma: no cover - runtime safety
        logging.error("Failed to reach Ollama: %s", exc)
        raise AgentProxyError(f"Failed to reach Ollama: {exc}") from exc

    try:
        data = response.json()
    except json.JSONDecodeError as exc:  # pragma: no cover - runtime safety
        logging.error("Invalid JSON from Ollama: %s", exc)
        raise AgentProxyError("Invalid JSON response from Ollama") from exc

    output = data.get("response", "")
    if not isinstance(output, str):
        raise AgentProxyError("Unexpected Ollama response format")

    return output


def ensure_directory(path: Path) -> None:
    if not path.exists():
        path.mkdir(parents=True, exist_ok=True)


def write_files(entries: Iterable[Dict[str, Any]]) -> List[str]:
    results: List[str] = []
    for entry in entries or []:
        path_value = entry.get("path")
        content = entry.get("content", "")
        if not path_value:
            raise AgentProxyError("File entry missing 'path'")

        file_path = Path(path_value).expanduser()
        if file_path.suffix == "":
            logging.debug("Writing file without extension: %s", file_path)

        if file_path.parent != Path(""):
            ensure_directory(file_path.parent)

        try:
            file_path.write_text(content, encoding="utf-8")
        except OSError as exc:
            logging.error("Failed to write file %s: %s", file_path, exc)
            raise AgentProxyError(f"Failed to write file {file_path}: {exc}") from exc

        results.append(f"wrote:{file_path}")
        logging.info("Wrote file %s", file_path)
    return results


def validate_command(command: str) -> List[str]:
    if any(token in command for token in BLOCKED_TOKENS):
        raise AgentProxyError("Command contains blocked token")

    try:
        parts = shlex.split(command)
    except ValueError as exc:
        raise AgentProxyError(f"Invalid command syntax: {command}") from exc

    if not parts:
        raise AgentProxyError("Empty command provided")

    if parts[0] not in ALLOWED_COMMANDS:
        raise AgentProxyError(f"Command '{parts[0]}' is not allowed")

    return parts


def execute_commands(spec: Optional[Dict[str, Any]]) -> str:
    if not spec:
        return ""

    workdir = spec.get("workdir") or os.getcwd()
    commands = spec.get("commands") or []

    if not isinstance(commands, list):
        raise AgentProxyError("'commands' must be a list")

    workdir_path = Path(workdir).expanduser()
    if not workdir_path.exists():
        raise AgentProxyError(f"Working directory does not exist: {workdir_path}")

    logs: List[str] = []
    for raw_command in commands:
        if not isinstance(raw_command, str):
            raise AgentProxyError("Commands must be strings")

        parts = validate_command(raw_command)
        logging.info("Executing command: %s", " ".join(parts))

        try:
            result = subprocess.run(  # noqa: S603 - controlled allowlist
                parts,
                cwd=str(workdir_path),
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            logging.error("Failed to execute command %s: %s", raw_command, exc)
            raise ShellExecutionError(f"Failed to execute command {raw_command}: {exc}") from exc

        command_log = f"$ {' '.join(parts)}\n{result.stdout}{result.stderr}"
        logs.append(command_log.strip())

        if result.returncode != 0:
            logging.error(
                "Command failed with exit code %s: %s", result.returncode, raw_command
            )
            raise ShellExecutionError(
                f"Command '{raw_command}' failed with exit code {result.returncode}"
            )

    return "\n\n".join(logs)


@app.route("/v1/agent/complete", methods=["POST"])
def complete() -> Any:
    if API_TOKEN and request.headers.get("X-API-KEY") != API_TOKEN:
        return jsonify({"ok": False, "error": "Unauthorized"}), 401

    try:
        data = request.get_json(force=True)
    except Exception:  # pylint: disable=broad-exception-caught
        return jsonify({"ok": False, "error": "Invalid JSON payload"}), 400

    if not isinstance(data, dict):
        return jsonify({"ok": False, "error": "Invalid request format"}), 400

    prompt = data.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return jsonify({"ok": False, "error": "Missing 'prompt' field"}), 400

    files_result: List[str] = []
    shell_logs = ""

    try:
        files_result = write_files(data.get("write_files", []))
        shell_logs = execute_commands(data.get("run_shell"))
        output = call_ollama(prompt)
    except AgentProxyError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    return jsonify({"ok": True, "output": output, "files": files_result, "shell": shell_logs})


def main() -> None:
    app.run(host="0.0.0.0", port=AGENT_PORT)


if __name__ == "__main__":
    main()
