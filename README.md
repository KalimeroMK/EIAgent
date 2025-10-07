# EIAgent

EIAgent is an opinionated “batteries included” stack that connects [Eigent](https://github.com/eigent-ai/eigent) to [Ollama](https://ollama.ai/) so you can run the **Qwen2.5-Coder:7B** model locally and expose it through a lightweight Flask proxy. The proxy adds authentication, hides the raw CLI invocation, and keeps your editors or automation workflows decoupled from the underlying containers.

## Features

- 🧠 **Pre-configured Ollama runtime** with persistent volume storage and health checks.
- 🤖 **Flask API proxy** that authenticates requests, ensures the desired model exists, and orchestrates Eigent CLI calls.
- ⚡ **One-click installer** that clones Eigent, builds the binary, pulls the Qwen2.5-Coder:7B (CPU) model, and boots the Docker Compose stack.
- 🛠️ **Makefile helpers** for common lifecycle commands.
- 🔒 **API key enforcement** and security best practices.

## Quick start

> The installer clones Eigent into `/opt/eigent`, so run it with elevated privileges the first time.

```bash
chmod +x install.sh
sudo ./install.sh
```

When the script completes you should have two containers (`eigent-ollama` and `eigent-agent-proxy`) running in the background. Test that the proxy is alive:

```bash
curl -X POST http://localhost:6969/v1/agent/complete \
  -H 'X-API-KEY: CHANGE_ME_SUPER_SECRET_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Write a PHP function that validates an email."}'
```

Expected response:

```json
{
  "ok": true,
  "output": "<?php\nfunction isValidEmail(string $email): bool {\n    return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;\n}"
}
```

You can now point any HTTP client (CLI, editor, CI/CD pipeline) to `http://localhost:6969/v1/agent/complete` and start generating completions.

## Configuration

All runtime configuration lives in the `.env` file (created automatically from `.env.example`).

| Variable     | Default                        | Description                                         |
| ------------ | ------------------------------ | --------------------------------------------------- |
| `API_TOKEN`  | `CHANGE_ME_SUPER_SECRET_TOKEN` | Shared secret required in the `X-API-KEY` header.   |
| `EIGENT_BIN` | `/opt/eigent/eigent`           | Absolute path to the Eigent binary on the host.     |
| `MODEL_NAME` | `qwen2.5-coder-7b-cpu`         | Ollama model identifier to auto-pull and execute.   |
| `AGENT_PORT` | `6969`                         | Port exposed by the Flask proxy.                    |

The proxy automatically resolves the Ollama container via Docker networking, so you typically do not need to change any URLs.

## Sublime Text integration

1. Install the [Sublime Text HTTP Requester](https://packagecontrol.io/packages/HTTP%20Requester) or any REST client plugin you prefer.
2. Create a new request file with the following snippet:

   ```http
   POST http://localhost:6969/v1/agent/complete
   X-API-KEY: CHANGE_ME_SUPER_SECRET_TOKEN
   Content-Type: application/json

   {
     "prompt": "Refactor this Python function to use type hints:\n" + $selection
   }
   ```

3. Highlight the request and run it (⌘+⌥+R / Ctrl+Alt+R). The response pane will show the Eigent output, making it easy to iterate without leaving the editor.

For richer integration you can wire the proxy into your favourite Sublime LSP or snippet runner—any plugin that can send HTTP POST requests will work.

## Makefile commands

```bash
make up       # docker compose up -d
make down     # docker compose down
make rebuild  # docker compose up -d --build
make logs     # docker compose logs -f
```

You can override the compose command with `COMPOSE="docker-compose" make up` if you are still on Compose v1.

## GPU acceleration (Tesla T4)

The stack is CPU-only out of the box. If you have access to an NVIDIA Tesla T4 (or similar) and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed, you can enable GPU passthrough by uncommenting the `deploy.resources` stanza in `docker-compose.yml`. After doing so, rebuild the stack:

```bash
make down
COMPOSE="docker compose" make up
```

The Ollama container will then discover the GPU and optimise runtime accordingly.

## Security best practices

- **Rotate the API key**: Edit `.env` and change `API_TOKEN` to a long random string. Restart the proxy (`make up`) to apply.
- **Use an HTTPS edge**: For remote access, put the proxy behind an HTTPS reverse proxy (Caddy, Traefik, or nginx) and terminate TLS there.
- **Limit network exposure**: Bind the public endpoint on a VPN interface or SSH tunnel rather than exposing it directly to the internet.
- **Monitor logs**: Run `make logs` to watch for suspicious access patterns or CLI errors.

## Manual operations

If you prefer to manage things yourself, here are the raw commands the installer automates:

```bash
# Clone and build Eigent
sudo git clone https://github.com/eigent-ai/eigent.git /opt/eigent
cd /opt/eigent
cargo build --release
sudo cp target/release/eigent /opt/eigent/eigent

# Back in this repository
cp .env.example .env
# (edit .env to customise API token and ports)

docker compose pull
docker compose up -d ollama
docker compose exec -T ollama ollama pull qwen2.5-coder-7b-cpu
docker compose up -d
```

## Troubleshooting

- **`eigent: not found`** – confirm `/opt/eigent/eigent` exists and is executable, then restart the proxy container.
- **Model download stalls** – ensure your host can reach `https://ollama.ai` endpoints, or manually run `docker compose exec -T ollama ollama pull qwen2.5-coder-7b-cpu`.
- **Permission errors in `/opt/eigent`** – rerun `sudo ./install.sh` or adjust permissions so Docker can mount the binary.

Happy building!
