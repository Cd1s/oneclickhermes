# OneClickHermes

One-click installer for a fresh Hermes Agent server with optional Telegram gateway
and the community Hermes WebUI:

- Hermes Agent from official `NousResearch/hermes-agent` main installer
- Custom model provider written to `~/.hermes/config.yaml`
- Secrets written only to `~/.hermes/.env` with mode `600`
- Optional Telegram bot gateway
- `https://github.com/nesquena/hermes-webui` as a service
- Alpine OpenRC and Debian/Ubuntu/Proxmox systemd support
- Hermes API Server disabled by default

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Cd1s/oneclickhermes/main/install.sh -o install.sh
chmod +x install.sh

NONINTERACTIVE=1 \
DEPLOY_TG=0 \
WEBUI_HOST='0.0.0.0' \
WEBUI_PORT='8080' \
WEBUI_PASSWORD='' \
MODEL_PROVIDER='localopenai' \
MODEL_BASE_URL='https://ai.example.com/v1' \
MODEL_API_MODE='codex_responses' \
MODEL_KEY_ENV='OPENAI_API_KEY' \
MODEL_API_KEY='sk-replace-me' \
MODEL_DEFAULT='gpt-5.5' \
MODEL_SPECS='gpt-5.5:400000:32000' \
bash install.sh
```

If `WEBUI_PASSWORD` is empty, a random password is generated and printed once at
the end of the install.

## Telegram

```bash
NONINTERACTIVE=1 \
DEPLOY_TG=1 \
TELEGRAM_BOT_TOKEN='123456:replace-me' \
TELEGRAM_ALLOWED_USERS='8699304813' \
WEBUI_HOST='0.0.0.0' \
WEBUI_PORT='8080' \
MODEL_PROVIDER='localopenai' \
MODEL_BASE_URL='https://ai.example.com/v1' \
MODEL_API_MODE='codex_responses' \
MODEL_KEY_ENV='OPENAI_API_KEY' \
MODEL_API_KEY='sk-replace-me' \
MODEL_DEFAULT='gpt-5.5' \
MODEL_SPECS='gpt-5.5:400000:32000' \
bash install.sh
```

## Main Variables

| Variable | Default | Meaning |
|---|---:|---|
| `DEPLOY_TG` | `0` | Enable Telegram gateway service |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token |
| `TELEGRAM_ALLOWED_USERS` | empty | Comma-separated Telegram user IDs |
| `WEBUI_REPO` | `https://github.com/nesquena/hermes-webui.git` | WebUI repository |
| `WEBUI_REF` | `main` | WebUI branch/ref |
| `WEBUI_HOST` | `127.0.0.1` | WebUI bind address |
| `WEBUI_PORT` | `8787` | WebUI bind port |
| `WEBUI_PASSWORD` | generated | WebUI password |
| `MODEL_PROVIDER` | `localopenai` | Hermes custom provider name |
| `MODEL_BASE_URL` | required | OpenAI-compatible base URL, usually ending in `/v1` |
| `MODEL_API_MODE` | `codex_responses` | `chat_completions`, `codex_responses`, or `anthropic_messages` |
| `MODEL_KEY_ENV` | `OPENAI_API_KEY` | Env var name stored in `.env` |
| `MODEL_API_KEY` | required unless `MODEL_NO_AUTH=1` | Model API key |
| `MODEL_DEFAULT` | required | Default model ID |
| `MODEL_SPECS` | required | `model:context_length:max_output_tokens`, comma-separated |
| `HERMES_FULL_PERMISSIONS` | `1` | Disable approval prompts and enable broad tool access |
| `ENABLE_API_SERVER` | `0` | Optional, loopback-only if enabled |
| `RUN_CHAT_TEST` | `0` | Run `hermes chat -q` smoke test after install |

## Notes

`nesquena/hermes-webui` runs through its own in-process Hermes runtime by default,
so this installer does not enable Hermes API Server. If you opt into
`ENABLE_API_SERVER=1`, the script refuses non-loopback API server bind addresses.

The installer backs up existing `~/.hermes/.env` and `~/.hermes/config.yaml`
before modifying them.
