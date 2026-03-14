#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — The One Script to Rule Them All
# Usage: bash deploy.sh <target> [flags]
#
# <target>   IP address (e.g. 1.2.3.4) or SSH alias (e.g. x)
#
# Flags:
#   --init      First-time setup: install deps + push configs + binary + systemd
#   -c          Also sync skyclaw.toml config to server
#   -e          Also sync .env file to server
#   --no-build  Skip local build, push existing binary
#
# Examples:
#   bash deploy.sh x --init        First time: full setup + push binary
#   bash deploy.sh x               Build + push binary (normal update)
#   bash deploy.sh x --no-build    Push existing binary (no build)
#   bash deploy.sh x -c            Build + push binary + sync config
#   bash deploy.sh 1.2.3.4 -c -e   Build + push + sync config + sync .env
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET="${1:-}"
SYNC_CONFIG=false
SYNC_ENV=false
DO_BUILD=true
INIT_MODE=false

# ── Parse flags ──────────────────────────────────────────────────────────────
shift || true
for arg in "$@"; do
  case "$arg" in
    -c)         SYNC_CONFIG=true ;;
    -e)         SYNC_ENV=true ;;
    --no-build) DO_BUILD=false ;;
    --init)     INIT_MODE=true ;;
    *)          echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo -e "Usage: bash deploy.sh <target> [flags]"
  echo ""
  echo "  Flags:"
  echo "    --init      First-time: install deps + push everything + systemd"
  echo "    -c          Sync skyclaw.toml to server"
  echo "    -e          Sync .env to server"
  echo "    --no-build  Skip local build, push existing binary"
  echo ""
  echo "  Examples:"
  echo "    bash deploy.sh x --init        First-time full setup"
  echo "    bash deploy.sh x               Normal update (build + push binary)"
  echo "    bash deploy.sh x --no-build    Push existing binary"
  echo "    bash deploy.sh x -c -e         Push + sync config + .env"
  exit 1
fi

# ── Resolve SSH target ───────────────────────────────────────────────────────
REMOTE_DEST="$TARGET"
if [[ "$TARGET" != *"@"* ]] && [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  REMOTE_DEST="root@$TARGET"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="skyclaw"
LOCAL_BINARY="$REPO_DIR/target/release/$BINARY_NAME"
REMOTE_PATH="/usr/local/bin/$BINARY_NAME"
REMOTE_CONFIG_DIR="/root/.skyclaw"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RED='\033[0;31m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Deploy to Server        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
if [[ "$INIT_MODE" == "true" ]]; then
  echo -e "${BOLD}║       Mode: FIRST-TIME INIT              ║${RESET}"
fi
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# INIT MODE — First-time server setup (runs BEFORE build + push)
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$INIT_MODE" == "true" ]]; then

  # ── Install runtime deps on server ───────────────────────────────────────
  info "Installing runtime dependencies on $REMOTE_DEST..."

  ssh "$REMOTE_DEST" bash -s << 'DEPS_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Git
if ! command -v git &>/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq git
fi

# Node.js + npx
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs >/dev/null 2>&1
fi

# OpenCode
if ! command -v opencode &>/dev/null; then
  sudo npm install -g opencode-ai --silent 2>/dev/null
fi

# lsof (needed by start.sh)
if ! command -v lsof &>/dev/null; then
  sudo apt-get install -y -qq lsof 2>/dev/null
fi

echo "DEPS_OK"
DEPS_EOF
  ok "Runtime deps installed (git, Node.js, npx, opencode)"

  # ── Create directories on server ─────────────────────────────────────────
  info "Creating directories on $REMOTE_DEST..."

  ssh "$REMOTE_DEST" bash -s << 'DIR_EOF'
set -euo pipefail
for dir in \
  /root/.skyclaw \
  /root/.skyclaw/workspace \
  /root/.skyclaw/workspace/cron \
  /root/.skyclaw/skills \
  /root/.skyclaw/vault \
  /root/.skyclaw/backups \
  /opt/scripts \
  /opt/ansible/playbooks \
  /opt/terraform; do
  sudo mkdir -p "$dir"
done
sudo chmod 700 /root/.skyclaw /root/.skyclaw/vault
echo "DIRS_OK"
DIR_EOF
  ok "Directories created"

  # ── Push config files ────────────────────────────────────────────────────
  info "Pushing config files to $REMOTE_DEST..."

  # skyclaw.toml
  scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml $REMOTE_CONFIG_DIR/skyclaw.toml"
  ok "skyclaw.toml"

  # mcp.toml (only if not already customised)
  if [[ -f "$REPO_DIR/deploy/mcp.toml" ]]; then
    scp "$REPO_DIR/deploy/mcp.toml" "$REMOTE_DEST:/tmp/mcp.toml"
    ssh "$REMOTE_DEST" "sudo test -f $REMOTE_CONFIG_DIR/mcp.toml && echo 'exists' || sudo mv /tmp/mcp.toml $REMOTE_CONFIG_DIR/mcp.toml"
    ok "mcp.toml"
  fi

  # .env from .env.example (only if not exists)
  if [[ -f "$REPO_DIR/.env.example" ]]; then
    scp "$REPO_DIR/.env.example" "$REMOTE_DEST:/tmp/.env.example"
    ssh "$REMOTE_DEST" bash -s << 'ENV_EOF'
if sudo test ! -f /root/.skyclaw/.env; then
  sudo mv /tmp/.env.example /root/.skyclaw/.env
  sudo chmod 600 /root/.skyclaw/.env
  echo "CREATED"
else
  rm -f /tmp/.env.example
  echo "EXISTS"
fi
ENV_EOF
    ok ".env template"
  fi

  # Workspace files (HEARTBEAT, backup, restore)
  for f in workspace/HEARTBEAT.md workspace/backup.sh workspace/restore.sh; do
    if [[ -f "$REPO_DIR/$f" ]]; then
      scp "$REPO_DIR/$f" "$REMOTE_DEST:/tmp/$(basename $f)"
      ssh "$REMOTE_DEST" "sudo mv /tmp/$(basename $f) $REMOTE_CONFIG_DIR/$f && sudo chmod +x $REMOTE_CONFIG_DIR/$f 2>/dev/null || true"
    fi
  done
  ok "Workspace files (HEARTBEAT, backup, restore)"

  # Skills
  for skill in devops-core incident-response deployment self-management; do
    if [[ -f "$REPO_DIR/skills/$skill.md" ]]; then
      scp "$REPO_DIR/skills/$skill.md" "$REMOTE_DEST:/tmp/$skill.md"
      ssh "$REMOTE_DEST" "sudo mv /tmp/$skill.md $REMOTE_CONFIG_DIR/skills/$skill.md"
    fi
  done
  ok "Skills"

  # start.sh — push it to the server so they can use it
  scp "$REPO_DIR/start.sh" "$REMOTE_DEST:/tmp/start.sh"
  ssh "$REMOTE_DEST" "sudo mv /tmp/start.sh /root/start.sh && sudo chmod +x /root/start.sh"
  ok "start.sh pushed to /root/start.sh"

  # ── Systemd service ─────────────────────────────────────────────────────
  info "Installing systemd service..."
  if [[ -f "$REPO_DIR/deploy/skyclaw.service" ]]; then
    scp "$REPO_DIR/deploy/skyclaw.service" "$REMOTE_DEST:/tmp/skyclaw.service"
    ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.service /etc/systemd/system/skyclaw.service && sudo systemctl daemon-reload && sudo systemctl enable skyclaw"
    ok "systemd service installed and enabled"
  fi

  # ── OpenCode config ─────────────────────────────────────────────────────
  info "Setting up OpenCode config..."
  ssh "$REMOTE_DEST" bash -s << 'OC_EOF'
sudo mkdir -p /root/.config/opencode
if sudo test ! -f /root/.config/opencode/opencode.json; then
  sudo tee /root/.config/opencode/opencode.json > /dev/null << 'OCJSON'
{
  "provider": "openrouter",
  "model": "deepseek/deepseek-r1-0528",
  "autoshare": false,
  "disabled_providers": []
}
OCJSON
  sudo chmod 600 /root/.config/opencode/opencode.json
  echo "CREATED"
else
  echo "EXISTS"
fi
OC_EOF
  ok "OpenCode config"

  # ── SSH key ─────────────────────────────────────────────────────────────
  info "Setting up SSH key..."
  ssh "$REMOTE_DEST" bash -s << 'SSH_EOF'
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
if sudo test ! -f /root/.ssh/batabeto; then
  sudo ssh-keygen -t ed25519 -C "batabeto-agent" -f /root/.ssh/batabeto -N ""
  echo "GENERATED"
else
  echo "EXISTS"
fi
SSH_EOF
  ok "SSH key"

  echo ""
  ok "Server init complete!"
  echo ""
fi

# ═════════════════════════════════════════════════════════════════════════════
# BUILD + PUSH BINARY (runs always)
# ═════════════════════════════════════════════════════════════════════════════

# ── Build locally (unless --no-build) ────────────────────────────────────────
if [[ "$DO_BUILD" == "true" ]]; then
  info "Building $BINARY_NAME locally in release mode..."

  # Source cargo env — handle both normal and sudo cases
  source "$HOME/.cargo/env" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(eval echo "~$SUDO_USER")
    source "$REAL_HOME/.cargo/env" 2>/dev/null || true
  fi

  cd "$REPO_DIR"
  cargo build --release

  if [[ ! -f "$LOCAL_BINARY" ]]; then
    err "Build failed — binary not found at $LOCAL_BINARY"
  fi
  ok "Local build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"
else
  info "Skipping build (--no-build)"
  if [[ ! -f "$LOCAL_BINARY" ]]; then
    err "No binary found at $LOCAL_BINARY — run 'bash build.sh' first or remove --no-build"
  fi
  ok "Using existing binary: $(du -sh "$LOCAL_BINARY" | cut -f1)"
fi

# ── Stop remote service ─────────────────────────────────────────────────────
info "Stopping skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl stop skyclaw 2>/dev/null" || true
ok "Service stopped"

# ── Upload binary ────────────────────────────────────────────────────────────
info "Uploading binary to $REMOTE_DEST..."
scp "$LOCAL_BINARY" "$REMOTE_DEST:/tmp/$BINARY_NAME"
ok "Binary uploaded"

info "Installing binary to $REMOTE_PATH..."
ssh "$REMOTE_DEST" "sudo mv /tmp/$BINARY_NAME $REMOTE_PATH && sudo chown root:root $REMOTE_PATH && sudo chmod 755 $REMOTE_PATH"
ok "Binary installed"

# ── Sync config files (optional, for non-init updates) ───────────────────────
if [[ "$SYNC_CONFIG" == "true" ]]; then
  info "Syncing skyclaw.toml to $REMOTE_DEST..."
  scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml $REMOTE_CONFIG_DIR/skyclaw.toml && sudo chown root:root $REMOTE_CONFIG_DIR/skyclaw.toml"
  ok "Config synced"
fi

if [[ "$SYNC_ENV" == "true" ]]; then
  if [[ -f "$REPO_DIR/.env" ]]; then
    info "Syncing .env to $REMOTE_DEST..."
    scp "$REPO_DIR/.env" "$REMOTE_DEST:/tmp/.env"
    ssh "$REMOTE_DEST" "sudo mv /tmp/.env $REMOTE_CONFIG_DIR/.env && sudo chown root:root $REMOTE_CONFIG_DIR/.env && sudo chmod 600 $REMOTE_CONFIG_DIR/.env"
    ok ".env synced"
  else
    warn "No .env file found locally — skipping"
  fi
fi

# ── Start service ────────────────────────────────────────────────────────────
info "Starting skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl start skyclaw"
ok "skyclaw is live on $REMOTE_DEST"

echo ""
echo -e "${GREEN}${BOLD}Deploy complete.${RESET}"
echo ""
echo -e "  Watch logs: ${BLUE}ssh $REMOTE_DEST 'sudo journalctl -fu skyclaw'${RESET}"
echo -e "  Status:     ${BLUE}ssh $REMOTE_DEST 'sudo systemctl status skyclaw'${RESET}"
echo ""
if [[ "$INIT_MODE" == "true" ]]; then
  echo -e "  ${YELLOW}IMPORTANT:${RESET} Edit .env on the server:"
  echo -e "  ${BLUE}ssh $REMOTE_DEST${RESET} then ${BLUE}sudo nano /root/.skyclaw/.env${RESET}"
  echo -e "  Set: TELEGRAM_BOT_TOKEN, OPENROUTER_API_KEY, OWNER_CHAT_ID"
  echo -e "  Then: ${BLUE}sudo systemctl restart skyclaw${RESET}"
  echo ""
fi
