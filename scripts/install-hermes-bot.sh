#!/usr/bin/env bash
set -Eeuo pipefail

IFS=$'\n\t'

log() {
  printf '[hermes-bot-install] %s\n' "$*"
}

die() {
  printf '[hermes-bot-install] ERROR: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run this installer as root"
  fi
}

detect_platform() {
  if [ -f /etc/alpine-release ]; then
    OS_FAMILY="alpine"
    SERVICE_MANAGER="openrc"
  elif command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
    SERVICE_MANAGER="systemd"
  else
    die "unsupported OS. This script supports Debian/Ubuntu/PVE and Alpine."
  fi
}

ensure_expected_host() {
  if [ -n "${EXPECTED_HOSTNAME:-}" ]; then
    local actual
    actual="$(hostname)"
    if [ "$actual" != "$EXPECTED_HOSTNAME" ]; then
      die "hostname is $actual, expected $EXPECTED_HOSTNAME"
    fi
  fi
}

ensure_basic_dns() {
  if [ ! -s /etc/resolv.conf ] || ! grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
    log "Writing fallback DNS resolvers to /etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  fi
}

install_packages() {
  log "Installing OS packages for $OS_FAMILY"
  if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update
    apt-get install -y \
      bash ca-certificates curl git iproute2 jq openssl procps python3 python3-pip \
      python3-venv build-essential pkg-config libffi-dev
  else
    apk add --no-cache \
      bash build-base ca-certificates cargo curl ffmpeg git iproute2 jq libffi-dev \
      linux-headers nodejs npm openssl openssl-dev procps py3-pip \
      py3-virtualenv python3 ripgrep rust
  fi
}

prompt_var() {
  local name="$1"
  local label="$2"
  local secret="${3:-0}"
  local value="${!name:-}"

  if [ -n "$value" ]; then
    return 0
  fi
  if is_true "${NONINTERACTIVE:-0}"; then
    die "$name is required in NONINTERACTIVE mode"
  fi
  if [ ! -t 0 ]; then
    die "$name is required; set it as an environment variable"
  fi

  if is_true "$secret"; then
    printf '%s: ' "$label" >/dev/tty
    IFS= read -r -s value </dev/tty || true
    printf '\n' >/dev/tty
  else
    printf '%s: ' "$label" >/dev/tty
    IFS= read -r value </dev/tty || true
  fi
  if [ -z "$value" ]; then
    die "$name cannot be empty"
  fi
  printf -v "$name" '%s' "$value"
  export "$name"
}

random_secret() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(36), end="")
PY
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n'
  else
    local password
    set +o pipefail
    password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
    set -o pipefail
    printf '%s' "$password"
  fi
}

read_env_value() {
  local file="$1"
  local wanted="$2"
  local line key value

  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    key="${key#export }"
    key="${key//[[:space:]]/}"
    [ "$key" = "$wanted" ] || continue
    value="${line#*=}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
    return 0
  done < "$file"
  return 1
}

normalize_inputs() {
  HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
  HERMES_AGENT_REF="${HERMES_AGENT_REF:-main}"
  HERMES_INSTALLER_URL="${HERMES_INSTALLER_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
  INSTALL_BROWSER="${INSTALL_BROWSER:-0}"
  HERMES_FULL_PERMISSIONS="${HERMES_FULL_PERMISSIONS:-1}"
  TERMINAL_CWD="${TERMINAL_CWD:-/root/workspace}"

  DEPLOY_TG="${DEPLOY_TG:-0}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_ALLOWED_USER_ID:-${TG_ACCOUNT_ID:-${TG_USER_ID:-}}}}"

  WEBUI_REPO="${WEBUI_REPO:-https://github.com/nesquena/hermes-webui.git}"
  WEBUI_REF="${WEBUI_REF:-master}"
  WEBUI_DIR="${WEBUI_DIR:-/opt/hermes-webui}"
  WEBUI_HOST="${WEBUI_HOST:-127.0.0.1}"
  WEBUI_PORT="${WEBUI_PORT:-8787}"
  WEBUI_SERVICE_NAME="${WEBUI_SERVICE_NAME:-hermes-webui}"
  WEBUI_AUTH="${WEBUI_AUTH:-1}"
  WEBUI_PASSWORD_WAS_SET=0
  if [ "${WEBUI_PASSWORD+x}" = x ]; then
    WEBUI_PASSWORD_WAS_SET=1
  fi
  WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
  GENERATED_WEBUI_PASSWORD=0
  REUSED_WEBUI_PASSWORD=0

  MODEL_PROVIDER="${MODEL_PROVIDER:-localopenai}"
  MODEL_BASE_URL="${MODEL_BASE_URL:-}"
  MODEL_API_MODE="${MODEL_API_MODE:-codex_responses}"
  MODEL_DEFAULT="${MODEL_DEFAULT:-}"
  MODEL_SPECS="${MODEL_SPECS:-}"
  MODEL_KEY_ENV="${MODEL_KEY_ENV:-OPENAI_API_KEY}"
  MODEL_API_KEY="${MODEL_API_KEY:-${OPENAI_API_KEY:-}}"
  MODEL_NO_AUTH="${MODEL_NO_AUTH:-0}"

  ENABLE_API_SERVER="${ENABLE_API_SERVER:-0}"
  API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
  API_SERVER_PORT="${API_SERVER_PORT:-8642}"
  API_SERVER_KEY="${API_SERVER_KEY:-}"

  RUN_DOCTOR="${RUN_DOCTOR:-1}"
  RUN_CHAT_TEST="${RUN_CHAT_TEST:-0}"

  mkdir -p "$HERMES_HOME" "$TERMINAL_CWD"
  chmod 700 "$HERMES_HOME"

  prompt_var MODEL_BASE_URL "Model base URL, for example https://api.example.com/v1"
  prompt_var MODEL_DEFAULT "Default model id, for example gpt-5.5"

  if [ -z "$MODEL_SPECS" ]; then
    MODEL_SPECS="${MODEL_DEFAULT}:131072:8192"
  fi

  if ! is_true "$MODEL_NO_AUTH"; then
    prompt_var MODEL_API_KEY "Model API key for $MODEL_KEY_ENV" 1
  fi

  if is_true "$DEPLOY_TG"; then
    prompt_var TELEGRAM_BOT_TOKEN "Telegram bot token" 1
    prompt_var TELEGRAM_ALLOWED_USERS "Telegram allowed user ids, comma-separated"
  fi

  if is_true "$WEBUI_AUTH" && [ -z "$WEBUI_PASSWORD" ] && [ "$WEBUI_PASSWORD_WAS_SET" -eq 0 ]; then
    WEBUI_PASSWORD="$(read_env_value "$HERMES_HOME/.env" HERMES_WEBUI_PASSWORD || true)"
    if [ -n "$WEBUI_PASSWORD" ]; then
      REUSED_WEBUI_PASSWORD=1
    fi
  fi

  if is_true "$WEBUI_AUTH" && [ -z "$WEBUI_PASSWORD" ]; then
    WEBUI_PASSWORD="$(random_secret)"
    GENERATED_WEBUI_PASSWORD=1
  fi

  if is_true "$ENABLE_API_SERVER"; then
    if [ "$API_SERVER_HOST" != "127.0.0.1" ] && [ "$API_SERVER_HOST" != "localhost" ]; then
      die "API server is only allowed on loopback by this installer; use API_SERVER_HOST=127.0.0.1"
    fi
  else
    unset API_SERVER_HOST API_SERVER_PORT API_SERVER_KEY
  fi

  export HERMES_HOME HERMES_AGENT_REF HERMES_FULL_PERMISSIONS TERMINAL_CWD
  export DEPLOY_TG TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS
  export WEBUI_REPO WEBUI_REF WEBUI_DIR WEBUI_HOST WEBUI_PORT WEBUI_SERVICE_NAME WEBUI_AUTH WEBUI_PASSWORD
  export MODEL_PROVIDER MODEL_BASE_URL MODEL_API_MODE MODEL_DEFAULT MODEL_SPECS MODEL_KEY_ENV MODEL_API_KEY MODEL_NO_AUTH
  export ENABLE_API_SERVER
  if is_true "$ENABLE_API_SERVER"; then
    export API_SERVER_HOST API_SERVER_PORT API_SERVER_KEY
  fi
}

install_hermes_agent() {
  log "Installing Hermes Agent from official main installer"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$HERMES_INSTALLER_URL" -o "$tmp"

  local args=(--skip-setup --branch "$HERMES_AGENT_REF")
  if ! is_true "$INSTALL_BROWSER"; then
    args+=(--skip-browser)
  fi

  HERMES_HOME="$HERMES_HOME" bash "$tmp" "${args[@]}"
  rm -f "$tmp"

  HERMES_BIN="$(command -v hermes || true)"
  if [ -z "$HERMES_BIN" ]; then
    for candidate in /usr/local/bin/hermes /root/.local/bin/hermes "$HERMES_HOME/hermes-agent/venv/bin/hermes"; do
      if [ -x "$candidate" ]; then
        HERMES_BIN="$candidate"
        break
      fi
    done
  fi
  [ -n "$HERMES_BIN" ] || die "hermes command not found after install"

  HERMES_AGENT_DIR=""
  for candidate in "${HERMES_INSTALL_DIR:-}" /usr/local/lib/hermes-agent "$HERMES_HOME/hermes-agent"; do
    if [ -n "$candidate" ] && [ -f "$candidate/run_agent.py" ]; then
      HERMES_AGENT_DIR="$candidate"
      break
    fi
  done
  [ -n "$HERMES_AGENT_DIR" ] || die "could not locate hermes-agent checkout"

  local remote head branch
  remote="$(git -C "$HERMES_AGENT_DIR" remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    *NousResearch/hermes-agent.git|*NousResearch/hermes-agent)
      ;;
    *)
      die "Hermes checkout at $HERMES_AGENT_DIR is not from NousResearch/hermes-agent (origin: ${remote:-missing})"
      ;;
  esac
  head="$(git -C "$HERMES_AGENT_DIR" rev-parse HEAD)"
  branch="$(git -C "$HERMES_AGENT_DIR" branch --show-current 2>/dev/null || true)"

  HERMES_PYTHON=""
  for candidate in "$HERMES_AGENT_DIR/venv/bin/python" "$HERMES_AGENT_DIR/.venv/bin/python" "$(command -v python3)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      HERMES_PYTHON="$candidate"
      break
    fi
  done
  [ -n "$HERMES_PYTHON" ] || die "could not locate Python for Hermes config"

  export HERMES_BIN HERMES_AGENT_DIR HERMES_PYTHON
  log "Hermes binary: $HERMES_BIN"
  log "Hermes source: $HERMES_AGENT_DIR"
  log "Hermes git origin: $remote"
  log "Hermes git ref: ${branch:-detached} @ $head"
}

write_hermes_env() {
  log "Writing Hermes secrets/env to $HERMES_HOME/.env"
  "$HERMES_PYTHON" - <<'PY'
import os
import time
from pathlib import Path

def truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on", "y"}

home = Path(os.environ["HERMES_HOME"])
path = home / ".env"
home.mkdir(parents=True, exist_ok=True)

updates: dict[str, str] = {}
removals: set[str] = set()

if not truthy(os.environ.get("MODEL_NO_AUTH")):
    updates[os.environ["MODEL_KEY_ENV"]] = os.environ["MODEL_API_KEY"]

if truthy(os.environ.get("DEPLOY_TG")):
    updates["TELEGRAM_BOT_TOKEN"] = os.environ["TELEGRAM_BOT_TOKEN"]
    updates["TELEGRAM_ALLOWED_USERS"] = os.environ["TELEGRAM_ALLOWED_USERS"]

if truthy(os.environ.get("WEBUI_AUTH")):
    updates["HERMES_WEBUI_PASSWORD"] = os.environ["WEBUI_PASSWORD"]
else:
    removals.add("HERMES_WEBUI_PASSWORD")

if truthy(os.environ.get("HERMES_FULL_PERMISSIONS")):
    updates["HERMES_YOLO_MODE"] = "1"
    updates["HERMES_ACCEPT_HOOKS"] = "1"

if truthy(os.environ.get("ENABLE_API_SERVER")):
    updates["API_SERVER_ENABLED"] = "true"
    updates["API_SERVER_HOST"] = os.environ.get("API_SERVER_HOST", "127.0.0.1")
    updates["API_SERVER_PORT"] = os.environ.get("API_SERVER_PORT", "8642")
    if os.environ.get("API_SERVER_KEY"):
        updates["API_SERVER_KEY"] = os.environ["API_SERVER_KEY"]
else:
    removals.update({
        "API_SERVER_ENABLED",
        "API_SERVER_HOST",
        "API_SERVER_PORT",
        "API_SERVER_KEY",
        "API_SERVER_MODEL_NAME",
        "GATEWAY_PROXY_URL",
        "GATEWAY_PROXY_KEY",
    })

for key, value in updates.items():
    if "\n" in value or "\r" in value:
        raise SystemExit(f"{key} contains a newline; refusing to write .env")

existing = []
if path.exists():
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak.oneclick.{stamp}")
    backup.write_bytes(path.read_bytes())
    existing = path.read_text(encoding="utf-8", errors="replace").splitlines()

seen = set()
out = []
for line in existing:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        out.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in removals:
        seen.add(key)
        continue
    if key in updates:
        out.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        out.append(line)

for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")

path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}

write_hermes_config() {
  log "Merging Hermes model, permissions, and Telegram config"
  "$HERMES_PYTHON" - <<'PY'
import os
import time
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required in the Hermes Python environment: {exc}")

VALID_API_MODES = {"chat_completions", "codex_responses", "anthropic_messages"}

def truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on", "y"}

def parse_model_specs(raw: str) -> dict[str, dict[str, int]]:
    models: dict[str, dict[str, int]] = {}
    normalized = raw.replace(";", "\n").replace(",", "\n")
    for item in normalized.splitlines():
        item = item.strip()
        if not item:
            continue
        try:
            model_id, ctx, out = item.rsplit(":", 2)
        except ValueError as exc:
            raise SystemExit(
                "MODEL_SPECS entries must be model_id:context_length:max_output_tokens"
            ) from exc
        model_id = model_id.strip()
        if not model_id:
            raise SystemExit("MODEL_SPECS contains an empty model id")
        try:
            ctx_i = int(ctx)
            out_i = int(out)
        except ValueError as exc:
            raise SystemExit(f"MODEL_SPECS has non-integer limits for {model_id}") from exc
        if ctx_i <= 0 or out_i <= 0:
            raise SystemExit(f"MODEL_SPECS limits must be positive for {model_id}")
        models[model_id] = {
            "context_length": ctx_i,
            "max_output_tokens": out_i,
        }
    return models

home = Path(os.environ["HERMES_HOME"])
config_path = home / "config.yaml"
home.mkdir(parents=True, exist_ok=True)

if config_path.exists() and config_path.read_text(encoding="utf-8", errors="replace").strip():
    cfg = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
    if not isinstance(cfg, dict):
        raise SystemExit(f"{config_path} is not a YAML mapping")
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = config_path.with_name(config_path.name + f".bak.oneclick.{stamp}")
    backup.write_bytes(config_path.read_bytes())
else:
    cfg = {}

provider = os.environ["MODEL_PROVIDER"].strip()
base_url = os.environ["MODEL_BASE_URL"].strip()
api_mode = os.environ["MODEL_API_MODE"].strip().lower()
default_model = os.environ["MODEL_DEFAULT"].strip()
if api_mode not in VALID_API_MODES:
    raise SystemExit(f"MODEL_API_MODE must be one of {sorted(VALID_API_MODES)}")

models = parse_model_specs(os.environ["MODEL_SPECS"])
if default_model not in models:
    first = next(iter(models.values()), {"context_length": 131072, "max_output_tokens": 8192})
    models[default_model] = dict(first)

entry = {
    "name": provider,
    "base_url": base_url,
    "api_mode": api_mode,
    "model": default_model,
    "models": models,
}
if truthy(os.environ.get("MODEL_NO_AUTH")):
    entry["api_key"] = ""
else:
    entry["key_env"] = os.environ["MODEL_KEY_ENV"].strip()

custom = cfg.get("custom_providers")
if custom is None:
    custom = []
elif not isinstance(custom, list):
    raise SystemExit("config custom_providers must be a list")

for index, item in enumerate(custom):
    if isinstance(item, dict) and str(item.get("name", "")).strip().lower() == provider.lower():
        custom[index] = entry
        break
else:
    custom.append(entry)
cfg["custom_providers"] = custom

model_cfg = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
model_cfg["provider"] = provider
model_cfg["default"] = default_model
model_cfg["base_url"] = base_url
model_cfg["api_mode"] = api_mode
model_cfg["max_tokens"] = int(models[default_model]["max_output_tokens"])
model_cfg["context_length"] = int(models[default_model]["context_length"])
if truthy(os.environ.get("MODEL_NO_AUTH")):
    model_cfg["api_key"] = ""
    model_cfg.pop("key_env", None)
else:
    model_cfg["key_env"] = os.environ["MODEL_KEY_ENV"].strip()
    model_cfg.pop("api_key", None)
cfg["model"] = model_cfg

terminal_cfg = cfg.get("terminal") if isinstance(cfg.get("terminal"), dict) else {}
terminal_cwd = os.environ.get("TERMINAL_CWD", "").strip()
if terminal_cwd:
    terminal_cfg["cwd"] = terminal_cwd
cfg["terminal"] = terminal_cfg

if truthy(os.environ.get("DEPLOY_TG")):
    telegram_cfg = cfg.get("telegram") if isinstance(cfg.get("telegram"), dict) else {}
    telegram_cfg["allow_from"] = os.environ["TELEGRAM_ALLOWED_USERS"].strip()
    cfg["telegram"] = telegram_cfg

if truthy(os.environ.get("HERMES_FULL_PERMISSIONS")):
    approvals = cfg.get("approvals") if isinstance(cfg.get("approvals"), dict) else {}
    approvals.update({
        "mode": "off",
        "timeout": 60,
        "cron_mode": "approve",
        "mcp_reload_confirm": False,
        "destructive_slash_confirm": False,
    })
    cfg["approvals"] = approvals
    cfg["command_allowlist"] = ["*"]
    cfg["hooks_auto_accept"] = True

    security = cfg.get("security") if isinstance(cfg.get("security"), dict) else {}
    security["allow_private_urls"] = True
    security["tirith_fail_open"] = True
    cfg["security"] = security

    browser = cfg.get("browser") if isinstance(cfg.get("browser"), dict) else {}
    browser["allow_private_urls"] = True
    cfg["browser"] = browser

    delegation = cfg.get("delegation") if isinstance(cfg.get("delegation"), dict) else {}
    delegation["subagent_auto_approve"] = True
    cfg["delegation"] = delegation

config_path.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
config_path.chmod(0o600)
PY
}

install_webui_repo() {
  log "Installing Hermes WebUI from $WEBUI_REPO"
  local ref="$WEBUI_REF"
  if ! git ls-remote --exit-code --heads "$WEBUI_REPO" "$ref" >/dev/null 2>&1; then
    if git ls-remote --exit-code --heads "$WEBUI_REPO" main >/dev/null 2>&1; then
      ref="main"
    else
      die "WebUI ref '$WEBUI_REF' not found and no 'main' fallback exists for $WEBUI_REPO"
    fi
  fi
  if [ -d "$WEBUI_DIR/.git" ]; then
    git -C "$WEBUI_DIR" fetch origin "$ref"
    git -C "$WEBUI_DIR" checkout "$ref" || git -C "$WEBUI_DIR" checkout -B "$ref" "origin/$ref"
    git -C "$WEBUI_DIR" pull --ff-only origin "$ref"
  else
    mkdir -p "$(dirname "$WEBUI_DIR")"
    git clone --depth 1 --branch "$ref" "$WEBUI_REPO" "$WEBUI_DIR"
  fi
}

write_webui_runner() {
  log "Writing WebUI runner and env"
  cat > /etc/hermes-webui.env <<EOF
HERMES_HOME=$HERMES_HOME
HERMES_WEBUI_AGENT_DIR=$HERMES_AGENT_DIR
HERMES_WEBUI_HOST=$WEBUI_HOST
HERMES_WEBUI_PORT=$WEBUI_PORT
HERMES_WEBUI_STATE_DIR=$HERMES_HOME/webui
HERMES_WEBUI_DEFAULT_WORKSPACE=$TERMINAL_CWD
HERMES_WEBUI_DEFAULT_MODEL=$MODEL_DEFAULT
HERMES_WEBUI_SKIP_ONBOARDING=1
HERMES_WEBUI_BOT_NAME=Hermes
EOF
  chmod 600 /etc/hermes-webui.env

  cat > /usr/local/bin/hermes-webui-run <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#export }"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    export "$key=$value"
  done < "$file"
}

load_env_file /etc/hermes-webui.env
load_env_file "${HERMES_HOME:-/root/.hermes}/.env"

export HOME="${HOME:-/root}"
export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
export HERMES_WEBUI_HOST="${HERMES_WEBUI_HOST:-127.0.0.1}"
export HERMES_WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"
export HERMES_WEBUI_PRESERVE_ENV=1
export PATH="/usr/local/bin:/root/.local/bin:${HERMES_HOME}/node/bin:${PATH}"

cd "__WEBUI_DIR__"
exec python3 bootstrap.py --no-browser --foreground --host "$HERMES_WEBUI_HOST" "$HERMES_WEBUI_PORT"
EOF
  sed -i "s#__WEBUI_DIR__#$WEBUI_DIR#g" /usr/local/bin/hermes-webui-run
  chmod 755 /usr/local/bin/hermes-webui-run
}

install_webui_service() {
  log "Installing WebUI service ($SERVICE_MANAGER)"
  mkdir -p "$HERMES_HOME/logs"
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    cat > "/etc/systemd/system/${WEBUI_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Hermes WebUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WEBUI_DIR
Environment=HOME=/root
Environment=HERMES_HOME=$HERMES_HOME
ExecStart=/usr/local/bin/hermes-webui-run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$WEBUI_SERVICE_NAME"
  else
    cat > "/etc/init.d/${WEBUI_SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="$WEBUI_SERVICE_NAME"
description="Hermes WebUI"
command="/usr/local/bin/hermes-webui-run"
command_user="root"
directory="$WEBUI_DIR"
pidfile="/run/${WEBUI_SERVICE_NAME}.pid"
command_background="yes"
output_log="$HERMES_HOME/logs/webui.log"
error_log="$HERMES_HOME/logs/webui.err"
start_stop_daemon_args="--make-pidfile --env HOME=/root --env HERMES_HOME=$HERMES_HOME --env PATH=/usr/local/bin:/root/.local/bin:$HERMES_HOME/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
depend() {
  need net
}
EOF
    chmod 755 "/etc/init.d/${WEBUI_SERVICE_NAME}"
    rc-update add "$WEBUI_SERVICE_NAME" default
    rc-service "$WEBUI_SERVICE_NAME" restart
  fi
}

install_gateway_service() {
  if ! is_true "$DEPLOY_TG" && ! is_true "$ENABLE_API_SERVER"; then
    log "Skipping Hermes gateway service because DEPLOY_TG=0 and ENABLE_API_SERVER=0"
    return 0
  fi

  log "Installing Hermes gateway service ($SERVICE_MANAGER)"
  mkdir -p "$HERMES_HOME/logs"
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    cat > /etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$TERMINAL_CWD
Environment=HOME=/root
Environment=HERMES_HOME=$HERMES_HOME
Environment=HERMES_ACCEPT_HOOKS=1
Environment=PATH=/usr/local/bin:/root/.local/bin:$HERMES_HOME/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HERMES_BIN gateway run --replace --accept-hooks
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hermes-gateway
  else
    cat > /etc/init.d/hermes-gateway <<EOF
#!/sbin/openrc-run
name="hermes-gateway"
description="Hermes Gateway"
command="$HERMES_BIN"
command_args="gateway run --replace --accept-hooks"
command_user="root"
directory="$TERMINAL_CWD"
pidfile="/run/hermes-gateway.pid"
command_background="yes"
output_log="$HERMES_HOME/logs/gateway.log"
error_log="$HERMES_HOME/logs/gateway.err"
start_stop_daemon_args="--make-pidfile --env HOME=/root --env HERMES_HOME=$HERMES_HOME --env HERMES_ACCEPT_HOOKS=1 --env PATH=/usr/local/bin:/root/.local/bin:$HERMES_HOME/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
depend() {
  need net
}
EOF
    chmod 755 /etc/init.d/hermes-gateway
    rc-update add hermes-gateway default
    rc-service hermes-gateway restart
  fi
}

wait_for_webui() {
  local host="$WEBUI_HOST"
  if [ "$host" = "0.0.0.0" ] || [ "$host" = "::" ]; then
    host="127.0.0.1"
  fi
  local url="http://${host}:${WEBUI_PORT}/health"
  log "Waiting for WebUI health at $url"
  local i
  for i in $(seq 1 90); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      log "WebUI health check OK"
      return 0
    fi
    sleep 2
  done
  die "WebUI did not become healthy; check service logs"
}

verify_webui_auth() {
  if ! is_true "$WEBUI_AUTH"; then
    return 0
  fi

  local host="$WEBUI_HOST"
  if [ "$host" = "0.0.0.0" ] || [ "$host" = "::" ]; then
    host="127.0.0.1"
  fi
  local url="http://${host}:${WEBUI_PORT}/api/auth/login"
  log "Verifying WebUI password login at $url"

  WEBUI_LOGIN_URL="$url" WEBUI_LOGIN_PASSWORD="$WEBUI_PASSWORD" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

url = os.environ["WEBUI_LOGIN_URL"]
password = os.environ["WEBUI_LOGIN_PASSWORD"]
payload = json.dumps({"password": password}).encode()
request = urllib.request.Request(
    url,
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read(4096).decode("utf-8", errors="replace")
        data = json.loads(body)
        if response.status != 200 or data.get("ok") is not True:
            raise SystemExit(f"login returned HTTP {response.status}: {body[:200]}")
        if not response.headers.get("Set-Cookie"):
            raise SystemExit("login succeeded but did not return a session cookie")
except urllib.error.HTTPError as exc:
    raise SystemExit(f"login returned HTTP {exc.code}: {exc.read(200).decode(errors='replace')}")
except Exception as exc:
    raise SystemExit(f"login check failed: {exc}")
PY
  log "WebUI password login OK"
}

verify_install() {
  log "Verifying Hermes config"
  "$HERMES_BIN" config check

  if is_true "$RUN_DOCTOR"; then
    "$HERMES_BIN" doctor || log "hermes doctor reported warnings/errors; inspect output above"
  fi

  if is_true "$RUN_CHAT_TEST"; then
    "$HERMES_BIN" chat -q "Reply exactly OK"
  fi

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl --no-pager --full status "$WEBUI_SERVICE_NAME" >/dev/null
    if is_true "$DEPLOY_TG" || is_true "$ENABLE_API_SERVER"; then
      systemctl --no-pager --full status hermes-gateway >/dev/null
    fi
  else
    rc-service "$WEBUI_SERVICE_NAME" status >/dev/null
    if is_true "$DEPLOY_TG" || is_true "$ENABLE_API_SERVER"; then
      rc-service hermes-gateway status >/dev/null
    fi
  fi

  wait_for_webui
  verify_webui_auth
}

print_summary() {
  cat <<EOF

Hermes bot install complete.

Hermes:
  home:        $HERMES_HOME
  source:      $HERMES_AGENT_DIR
  binary:      $HERMES_BIN
  provider:    $MODEL_PROVIDER
  default:     $MODEL_DEFAULT

WebUI:
  source:      $WEBUI_DIR
  service:     $WEBUI_SERVICE_NAME
  listen:      http://$WEBUI_HOST:$WEBUI_PORT
  auth:        $(is_true "$WEBUI_AUTH" && echo enabled || echo disabled)

Telegram:
  deployed:    $(is_true "$DEPLOY_TG" && echo yes || echo no)

API server:
  enabled:     $(is_true "$ENABLE_API_SERVER" && echo "yes, loopback only" || echo no)

Changed files:
  $HERMES_HOME/config.yaml
  $HERMES_HOME/.env
  /etc/hermes-webui.env
  /usr/local/bin/hermes-webui-run
EOF

  if is_true "$GENERATED_WEBUI_PASSWORD"; then
    printf '\nGenerated WebUI password:\n%s\n' "$WEBUI_PASSWORD"
  elif is_true "$REUSED_WEBUI_PASSWORD"; then
    printf '\nWebUI password: reused existing HERMES_WEBUI_PASSWORD from %s/.env\n' "$HERMES_HOME"
  fi
}

main() {
  need_root
  detect_platform
  ensure_expected_host
  ensure_basic_dns
  install_packages
  normalize_inputs
  install_hermes_agent
  write_hermes_env
  write_hermes_config
  install_webui_repo
  write_webui_runner
  install_gateway_service
  install_webui_service
  verify_install
  print_summary
}

main "$@"
