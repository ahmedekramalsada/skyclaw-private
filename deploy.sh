#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Build locally + push to server
# Usage: bash deploy.sh <target> [flags]
#
# Flags:
#   --init      First-time: install deps + push all files + systemd
#   -c          Also sync skyclaw.toml
#   -e          Also sync .env
#   --no-build  Skip build, push existing binary
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="${1:-}"
SYNC_CONFIG=false; SYNC_ENV=false; DO_BUILD=true; INIT_MODE=false

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
  echo "Usage: bash deploy.sh <target> [flags]"
  echo "  --init      First-time full setup"
  echo "  -c          Sync skyclaw.toml"
  echo "  -e          Sync .env"
  echo "  --no-build  Push existing binary"
  exit 1
fi

REMOTE_DEST="$TARGET"
[[ "$TARGET" != *"@"* && "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && REMOTE_DEST="root@$TARGET"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="skyclaw"
LOCAL_BINARY="$REPO_DIR/target/release/$BINARY_NAME"
REMOTE_PATH="/usr/local/bin/$BINARY_NAME"
REMOTE_DIR="/root/.skyclaw"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RED='\033[0;31m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

SSH_OPTS=()
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(eval echo "~$SUDO_USER")
  [[ -f "$REAL_HOME/.ssh/config" ]] && SSH_OPTS+=(-F "$REAL_HOME/.ssh/config")
  warn "Tip: sudo is not needed. Run: bash deploy.sh $TARGET --init"
fi

_ssh() { ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "$@"; }
_scp() { scp "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "$@"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Deploy to Server        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

if [[ "$INIT_MODE" == "true" ]]; then
  info "Running first-time setup on $REMOTE_DEST..."

  # ── Step 1: system deps ──────────────────────────────────────────────────
  _ssh "$REMOTE_DEST" bash -s << 'DEPS_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq git curl wget sqlite3
command -v node &>/dev/null || \
  (curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash - >/dev/null 2>&1 && \
   sudo apt-get install -y -qq nodejs)
# Install opencode globally so it's available as a system command
command -v opencode &>/dev/null || sudo npm install -g opencode-ai --silent 2>/dev/null || true
# Pre-install MCP server packages so npx doesn't download them cold at runtime
sudo npm install -g \
  @modelcontextprotocol/server-github \
  @modelcontextprotocol/server-sequential-thinking \
  @modelcontextprotocol/server-fetch \
  mcp-server-kubernetes \
  mcp-package-docs \
  --silent 2>/dev/null || true
echo "DEPS_OK"
DEPS_EOF
  ok "Runtime deps (git, Node.js, sqlite3, opencode, MCP packages)"

  # ── Step 2: directories ───────────────────────────────────────────────────
  _ssh "$REMOTE_DEST" bash -s << 'DIR_EOF'
set -euo pipefail
for d in /root/.skyclaw /root/.skyclaw/workspace /root/.skyclaw/workspace/cron \
  /root/.skyclaw/skills /root/.skyclaw/vault /root/.skyclaw/backups \
  /opt/scripts /opt/ansible/playbooks /opt/terraform; do
  sudo mkdir -p "$d"
done
sudo chmod 700 /root/.skyclaw /root/.skyclaw/vault
sudo chown -R root:root /root/.skyclaw
echo "DIRS_OK"
DIR_EOF
  ok "Directories created"

  # ── Step 3: push config files ─────────────────────────────────────────────
  _scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml $REMOTE_DIR/skyclaw.toml"
  ok "skyclaw.toml"

  _scp "$REPO_DIR/deploy/mcp.toml" "$REMOTE_DEST:/tmp/mcp.toml"
  _ssh "$REMOTE_DEST" "sudo test -f $REMOTE_DIR/mcp.toml && rm /tmp/mcp.toml || sudo mv /tmp/mcp.toml $REMOTE_DIR/mcp.toml"
  ok "mcp.toml"

  if [[ -f "$REPO_DIR/.env.example" ]]; then
    _scp "$REPO_DIR/.env.example" "$REMOTE_DEST:/tmp/.env.example"
    _ssh "$REMOTE_DEST" "sudo test -f $REMOTE_DIR/.env && rm /tmp/.env.example || (sudo mv /tmp/.env.example $REMOTE_DIR/.env && sudo chmod 600 $REMOTE_DIR/.env)"
    ok ".env template"
  fi

  for f in workspace/HEARTBEAT.md workspace/backup.sh workspace/restore.sh; do
    if [[ -f "$REPO_DIR/$f" ]]; then
      _scp "$REPO_DIR/$f" "$REMOTE_DEST:/tmp/$(basename $f)"
      _ssh "$REMOTE_DEST" "sudo mv /tmp/$(basename $f) $REMOTE_DIR/$f && sudo chmod +x $REMOTE_DIR/$f 2>/dev/null || true"
    fi
  done
  ok "Workspace files"

  for skill in devops-core incident-response deployment self-management telegram-features study-and-learning planning-and-projects opencode-repair; do
    if [[ -f "$REPO_DIR/skills/$skill.md" ]]; then
      _scp "$REPO_DIR/skills/$skill.md" "$REMOTE_DEST:/tmp/$skill.md"
      _ssh "$REMOTE_DEST" "sudo mv /tmp/$skill.md $REMOTE_DIR/skills/$skill.md"
    fi
  done
  ok "Skills"

  _scp "$REPO_DIR/start.sh" "$REMOTE_DEST:/tmp/start.sh"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/start.sh /root/start.sh && sudo chmod +x /root/start.sh"
  ok "start.sh"

  # ── Step 4: systemd services ──────────────────────────────────────────────
  _scp "$REPO_DIR/deploy/skyclaw.service" "$REMOTE_DEST:/tmp/skyclaw.service"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.service /etc/systemd/system/skyclaw.service"
  ok "skyclaw.service"

  _scp "$REPO_DIR/deploy/opencode.service" "$REMOTE_DEST:/tmp/opencode.service"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/opencode.service /etc/systemd/system/opencode.service"
  ok "opencode.service"

  _ssh "$REMOTE_DEST" "sudo systemctl daemon-reload && sudo systemctl enable skyclaw opencode"
  ok "Services enabled"

  # ── Step 5: cron jobs (backup + heartbeat every 15 min) ───────────────────
  _ssh "$REMOTE_DEST" bash -s << 'CRON_EOF'
# Install cron jobs for root — idempotent (removes old entries first)
TMPFILE=$(mktemp)
crontab -l 2>/dev/null | grep -v "skyclaw\|batabeto\|backup\.sh\|heartbeat" > "$TMPFILE" || true

cat >> "$TMPFILE" << 'CRONLINES'
# batabeto — backup every 15 min
*/15 * * * * bash /root/.skyclaw/workspace/backup.sh >> /var/log/skyclaw-backup.log 2>&1

# batabeto — heartbeat check every 15 min (offset by 7 min so it doesn't clash with backup)
7,22,37,52 * * * * /usr/local/bin/skyclaw heartbeat >> /var/log/skyclaw-heartbeat.log 2>&1
CRONLINES

crontab "$TMPFILE"
rm -f "$TMPFILE"
echo "CRON_OK"
CRON_EOF
  ok "Cron jobs installed (backup + heartbeat every 15 min)"

  # ── Step 6: OpenCode config ───────────────────────────────────────────────
  _ssh "$REMOTE_DEST" bash -s << 'OC_EOF'
sudo mkdir -p /root/.config/opencode
sudo test -f /root/.config/opencode/opencode.json || \
  (echo '{"provider":"openrouter","model":"deepseek/deepseek-r1-0528","autoshare":false,"disabled_providers":[]}' | \
   sudo tee /root/.config/opencode/opencode.json > /dev/null && \
   sudo chmod 600 /root/.config/opencode/opencode.json)
OC_EOF
  ok "OpenCode config"

  # ── Step 7: SSH key for batabeto ──────────────────────────────────────────
  _ssh "$REMOTE_DEST" bash -s << 'SSH_EOF'
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
sudo test -f /root/.ssh/batabeto || \
  sudo ssh-keygen -t ed25519 -C "batabeto-agent" -f /root/.ssh/batabeto -N ""
SSH_EOF
  ok "SSH key"

  echo ""
  ok "Server init complete!"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# BUILD + PUSH BINARY
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$DO_BUILD" == "true" ]]; then
  info "Building $BINARY_NAME locally..."
  source "$HOME/.cargo/env" 2>/dev/null || true
  [[ -n "${SUDO_USER:-}" ]] && source "$(eval echo "~$SUDO_USER")/.cargo/env" 2>/dev/null || true
  cd "$REPO_DIR"
  cargo build --release
  [[ ! -f "$LOCAL_BINARY" ]] && err "Build failed — $LOCAL_BINARY not found"
  ok "Build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"
else
  info "Skipping build (--no-build)"
  [[ ! -f "$LOCAL_BINARY" ]] && err "No binary at $LOCAL_BINARY — build first or remove --no-build"
  ok "Using existing binary: $(du -sh "$LOCAL_BINARY" | cut -f1)"
fi

info "Stopping bot on $REMOTE_DEST..."
_ssh "$REMOTE_DEST" "sudo systemctl stop skyclaw opencode 2>/dev/null || true"
ok "Services stopped"

info "Uploading binary..."
_scp "$LOCAL_BINARY" "$REMOTE_DEST:/tmp/$BINARY_NAME"
_ssh "$REMOTE_DEST" "sudo mv /tmp/$BINARY_NAME $REMOTE_PATH && sudo chmod 755 $REMOTE_PATH"
ok "Binary installed at $REMOTE_PATH"

# Always sync updated service files
_scp "$REPO_DIR/deploy/skyclaw.service" "$REMOTE_DEST:/tmp/skyclaw.service"
_ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.service /etc/systemd/system/skyclaw.service"
_scp "$REPO_DIR/deploy/opencode.service" "$REMOTE_DEST:/tmp/opencode.service"
_ssh "$REMOTE_DEST" "sudo mv /tmp/opencode.service /etc/systemd/system/opencode.service && sudo systemctl daemon-reload"
ok "Service files updated"

if [[ "$SYNC_CONFIG" == "true" ]]; then
  _scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml $REMOTE_DIR/skyclaw.toml"
  ok "skyclaw.toml synced"
fi

if [[ "$SYNC_ENV" == "true" && -f "$REPO_DIR/.env" ]]; then
  _scp "$REPO_DIR/.env" "$REMOTE_DEST:/tmp/.env"
  _ssh "$REMOTE_DEST" "sudo mv /tmp/.env $REMOTE_DIR/.env && sudo chmod 600 $REMOTE_DIR/.env"
  ok ".env synced"
fi

info "Starting services on $REMOTE_DEST..."
_ssh "$REMOTE_DEST" "sudo systemctl start opencode && sleep 2 && sudo systemctl start skyclaw"
ok "Services started (opencode first, then bot)"

echo ""
echo -e "${GREEN}${BOLD}Deploy complete.${RESET}"
echo ""
echo -e "  Bot logs:      ${BLUE}ssh $REMOTE_DEST 'journalctl -fu skyclaw'${RESET}"
echo -e "  OpenCode logs: ${BLUE}ssh $REMOTE_DEST 'journalctl -fu opencode'${RESET}"
echo ""
if [[ "$INIT_MODE" == "true" ]]; then
  echo -e "  ${YELLOW}NEXT STEPS:${RESET}"
  echo -e "  1. Edit .env:   ${BLUE}ssh $REMOTE_DEST 'sudo nano /root/.skyclaw/.env'${RESET}"
  echo -e "     Set: TELEGRAM_BOT_TOKEN, OPENROUTER_API_KEY, OWNER_CHAT_ID"
  echo -e "     For backup: GITHUB_TOKEN, GITHUB_USERNAME, GITHUB_BACKUP_REPO"
  echo -e "  2. Start:       ${BLUE}ssh $REMOTE_DEST 'sudo bash /root/start.sh'${RESET}"

  echo ""
fi
