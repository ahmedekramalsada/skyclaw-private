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
  echo ""
  echo "  --init      First-time full setup"
  echo "  -c          Sync skyclaw.toml"
  echo "  -e          Sync .env"
  echo "  --no-build  Push existing binary"
  echo ""
  echo "Examples:"
  echo "  bash deploy.sh 1.2.3.4 --init    First time"
  echo "  bash deploy.sh 1.2.3.4           Normal update"
  echo "  bash deploy.sh 1.2.3.4 -c -e     Update + sync configs"
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

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Deploy to Server        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── INIT: first-time server setup ─────────────────────────────────────────
if [[ "$INIT_MODE" == "true" ]]; then
  info "Running first-time setup on $REMOTE_DEST..."

  ssh "$REMOTE_DEST" bash -s << 'DEPS_EOF'
set -euo pipefail; export DEBIAN_FRONTEND=noninteractive
command -v git &>/dev/null || (apt-get update -qq && apt-get install -y -qq git curl lsof wget)
command -v node &>/dev/null || (curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1 && apt-get install -y -qq nodejs)
command -v python3 &>/dev/null || apt-get install -y -qq python3 python3-pip
pip3 install --quiet --break-system-packages fastapi uvicorn watchdog requests 2>/dev/null || \
  pip3 install --quiet fastapi uvicorn watchdog requests
command -v tailscale &>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
command -v opencode &>/dev/null || npm install -g opencode-ai --silent 2>/dev/null || true
command -v lsof &>/dev/null || apt-get install -y -qq lsof
echo "DEPS_OK"
DEPS_EOF
  ok "Runtime deps installed (git, Node.js, Python, Tailscale, opencode)"

  ssh "$REMOTE_DEST" bash -s << 'DIR_EOF'
for d in /root/.skyclaw /root/.skyclaw/workspace /root/.skyclaw/workspace/cron \
  /root/.skyclaw/skills /root/.skyclaw/vault /root/.skyclaw/backups \
  /root/.skyclaw/scripts /opt/scripts /opt/ansible/playbooks /opt/terraform; do
  mkdir -p "$d"
done
chmod 700 /root/.skyclaw /root/.skyclaw/vault
DIR_EOF
  ok "Directories created"

  # Push all config files
  for f in skyclaw.toml; do
    scp "$REPO_DIR/$f" "$REMOTE_DEST:/tmp/$f"
    ssh "$REMOTE_DEST" "mv /tmp/$f $REMOTE_DIR/$f"
    ok "$f"
  done

  scp "$REPO_DIR/deploy/mcp.toml" "$REMOTE_DEST:/tmp/mcp.toml"
  ssh "$REMOTE_DEST" "test -f $REMOTE_DIR/mcp.toml && echo 'mcp.toml exists, keeping' || mv /tmp/mcp.toml $REMOTE_DIR/mcp.toml"
  ok "mcp.toml"

  if [[ -f "$REPO_DIR/.env.example" ]]; then
    scp "$REPO_DIR/.env.example" "$REMOTE_DEST:/tmp/.env.example"
    ssh "$REMOTE_DEST" "test -f $REMOTE_DIR/.env && rm /tmp/.env.example || (mv /tmp/.env.example $REMOTE_DIR/.env && chmod 600 $REMOTE_DIR/.env)"
    ok ".env template"
  fi

  for f in workspace/HEARTBEAT.md workspace/backup.sh workspace/restore.sh; do
    [[ -f "$REPO_DIR/$f" ]] && scp "$REPO_DIR/$f" "$REMOTE_DEST:$REMOTE_DIR/$f"
  done
  ssh "$REMOTE_DEST" "chmod +x $REMOTE_DIR/workspace/backup.sh $REMOTE_DIR/workspace/restore.sh 2>/dev/null || true"
  ok "Workspace files"

  for skill in devops-core incident-response deployment self-management; do
    [[ -f "$REPO_DIR/skills/$skill.md" ]] && scp "$REPO_DIR/skills/$skill.md" "$REMOTE_DEST:$REMOTE_DIR/skills/$skill.md"
  done
  ok "Skills"

  # Push dashboard + start scripts
  scp "$REPO_DIR/skyclaw-dashboard.py" "$REMOTE_DEST:$REMOTE_DIR/scripts/skyclaw-dashboard.py"
  ssh "$REMOTE_DEST" "chmod +x $REMOTE_DIR/scripts/skyclaw-dashboard.py"
  ok "skyclaw-dashboard.py"

  scp "$REPO_DIR/start.sh" "$REMOTE_DEST:/root/start.sh"
  ssh "$REMOTE_DEST" "chmod +x /root/start.sh"
  ok "start.sh"

  # Bot service
  scp "$REPO_DIR/deploy/skyclaw.service" "$REMOTE_DEST:/tmp/skyclaw.service"
  ssh "$REMOTE_DEST" "mv /tmp/skyclaw.service /etc/systemd/system/skyclaw.service && systemctl daemon-reload && systemctl enable skyclaw"
  ok "skyclaw.service installed"

  # Dashboard service — write with correct PROJECT_DIR for the remote
  ssh "$REMOTE_DEST" bash -s "$REPO_DIR" << 'SVC_EOF'
PROJECT_DIR="$1"  # This is the remote path — update if different
cat > /etc/systemd/system/skyclaw-dashboard.service << SVCEOF
[Unit]
Description=batabeto live dashboard
After=network.target skyclaw.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/.skyclaw
EnvironmentFile=-/root/.skyclaw/.env
Environment="PROJECT_DIR=/root/skyclaw-private"
Environment="SKYCLAW_DIR=/root/.skyclaw"
Environment="SKYCLAW_SERVICE=skyclaw"
Environment="DASHBOARD_PORT=8888"
Environment="TTYD_PORT=8889"
ExecStart=/usr/bin/python3 /root/.skyclaw/scripts/skyclaw-dashboard.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload && systemctl enable skyclaw-dashboard
SVC_EOF
  ok "skyclaw-dashboard.service installed"

  # ttyd
  ssh "$REMOTE_DEST" bash -s << 'TTYD_EOF'
command -v ttyd &>/dev/null || \
  (curl -sL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64" \
    -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd)
TS_IP=$(tailscale ip -4 2>/dev/null || echo "0.0.0.0")
cat > /etc/systemd/system/ttyd.service << TTYDEOF
[Unit]
Description=ttyd terminal
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd --port 8889 --interface ${TS_IP} bash
Restart=always
User=root

[Install]
WantedBy=multi-user.target
TTYDEOF
systemctl daemon-reload && systemctl enable ttyd
TTYD_EOF
  ok "ttyd installed"

  # OpenCode config
  ssh "$REMOTE_DEST" bash -s << 'OC_EOF'
mkdir -p /root/.config/opencode
test -f /root/.config/opencode/opencode.json || \
  (echo '{"provider":"openrouter","model":"deepseek/deepseek-r1-0528","autoshare":false,"disabled_providers":[]}' \
    > /root/.config/opencode/opencode.json && chmod 600 /root/.config/opencode/opencode.json)
OC_EOF
  ok "OpenCode config"

  # SSH key
  ssh "$REMOTE_DEST" bash -s << 'SSH_EOF'
mkdir -p /root/.ssh && chmod 700 /root/.ssh
test -f /root/.ssh/batabeto || ssh-keygen -t ed25519 -C "batabeto-agent" -f /root/.ssh/batabeto -N ""
SSH_EOF
  ok "SSH key"

  echo ""
  ok "Server init complete!"
fi

# ── Build + push binary ───────────────────────────────────────────────────
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
  [[ ! -f "$LOCAL_BINARY" ]] && err "No binary found at $LOCAL_BINARY"
  ok "Using existing binary: $(du -sh "$LOCAL_BINARY" | cut -f1)"
fi

info "Stopping bot on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "systemctl stop skyclaw 2>/dev/null || true; systemctl stop skyclaw-dashboard 2>/dev/null || true"
ok "Services stopped"

info "Uploading binary..."
scp "$LOCAL_BINARY" "$REMOTE_DEST:/tmp/$BINARY_NAME"
ssh "$REMOTE_DEST" "mv /tmp/$BINARY_NAME $REMOTE_PATH && chmod 755 $REMOTE_PATH"
ok "Binary installed at $REMOTE_PATH"

# ── Push dashboard script update ────────────────────────────────────────
info "Updating dashboard script..."
scp "$REPO_DIR/skyclaw-dashboard.py" "$REMOTE_DEST:$REMOTE_DIR/scripts/skyclaw-dashboard.py"
ssh "$REMOTE_DEST" "chmod +x $REMOTE_DIR/scripts/skyclaw-dashboard.py"
ok "Dashboard script updated"

# ── Optional: sync configs ────────────────────────────────────────────────
if [[ "$SYNC_CONFIG" == "true" ]]; then
  scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  ssh "$REMOTE_DEST" "mv /tmp/skyclaw.toml $REMOTE_DIR/skyclaw.toml"
  ok "skyclaw.toml synced"
fi

if [[ "$SYNC_ENV" == "true" && -f "$REPO_DIR/.env" ]]; then
  scp "$REPO_DIR/.env" "$REMOTE_DEST:/tmp/.env"
  ssh "$REMOTE_DEST" "mv /tmp/.env $REMOTE_DIR/.env && chmod 600 $REMOTE_DIR/.env"
  ok ".env synced"
fi

# ── Restart services ──────────────────────────────────────────────────────
info "Restarting services on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "systemctl start skyclaw && systemctl start skyclaw-dashboard && (systemctl start ttyd 2>/dev/null || true)"
ok "Services started"

echo ""
echo -e "${GREEN}${BOLD}Deploy complete.${RESET}"
echo ""
echo -e "  Watch logs:  ${BLUE}ssh $REMOTE_DEST 'journalctl -fu skyclaw'${RESET}"
echo -e "  Dashboard:   ${BLUE}ssh $REMOTE_DEST 'journalctl -fu skyclaw-dashboard'${RESET}"
echo ""
if [[ "$INIT_MODE" == "true" ]]; then
  echo -e "  ${YELLOW}IMPORTANT:${RESET} Edit .env on the server:"
  echo -e "  ${BLUE}ssh $REMOTE_DEST 'nano /root/.skyclaw/.env'${RESET}"
  echo -e "  Then: ${BLUE}ssh $REMOTE_DEST 'bash /root/start.sh'${RESET}"
  echo ""
  echo -e "  Also run Tailscale: ${BLUE}ssh $REMOTE_DEST 'tailscale up'${RESET}"
  echo -e "  Then install Tailscale app on your phone."
  echo ""
fi
