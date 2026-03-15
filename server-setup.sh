#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# server-setup.sh — First-Time Server Setup
# Usage: sudo bash server-setup.sh [--with-build]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
WITH_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --with-build) WITH_BUILD=true ;;
    *)            echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/root/.skyclaw"
BINARY_PATH="/usr/local/bin/skyclaw"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash server-setup.sh"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Server Setup            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

header "STEP 1 — System dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

for pkg in git curl lsof wget; do
  command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg"
  ok "$pkg"
done

if ! command -v node &>/dev/null; then
  info "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null 2>&1
fi
ok "Node.js $(node --version)"

if ! command -v python3 &>/dev/null; then
  apt-get install -y -qq python3 python3-pip
fi
ok "Python $(python3 --version)"

info "Installing Python dashboard deps..."
pip3 install --quiet --break-system-packages fastapi uvicorn watchdog requests 2>/dev/null || \
  pip3 install --quiet fastapi uvicorn watchdog requests
ok "Python deps: fastapi uvicorn watchdog requests"

if ! command -v opencode &>/dev/null; then
  info "Installing opencode-ai..."
  npm install -g opencode-ai --silent 2>/dev/null || true
fi
command -v opencode &>/dev/null && ok "opencode" || warn "opencode install failed (non-fatal)"

if [[ "$WITH_BUILD" == "true" ]]; then
  if ! command -v cargo &>/dev/null; then
    info "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
  fi
  ok "Rust $(rustc --version)"
  command -v cc &>/dev/null || apt-get install -y build-essential
  dpkg -s libssl-dev &>/dev/null 2>&1 || apt-get install -y libssl-dev pkg-config
  ok "Build tools ready"
fi

header "STEP 2 — Tailscale (secure private network)"
if ! command -v tailscale &>/dev/null; then
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  ok "Tailscale installed"
else
  ok "Tailscale already installed"
fi

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$TAILSCALE_IP" ]]; then
  warn "Tailscale not connected. After setup run: tailscale up"
  warn "Then install Tailscale app on your phone and sign in with the same account."
else
  ok "Tailscale connected: $TAILSCALE_IP"
fi

if [[ "$WITH_BUILD" == "true" ]]; then
  header "STEP 3 — Building release binary"
  source "$HOME/.cargo/env" 2>/dev/null || true
  cd "$REPO_DIR"
  rm -f target/release/skyclaw
  cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true
  [[ ! -f "$REPO_DIR/target/release/skyclaw" ]] && err "Build failed"
  ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"
  cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
  chmod 755 "$BINARY_PATH"
  ok "Binary installed at $BINARY_PATH"
else
  header "STEP 3 — Skipping build"
  info "Use: bash deploy.sh <server-ip> from your local PC"
fi

header "STEP 4 — Directories"
for dir in \
  "$INSTALL_DIR" "$INSTALL_DIR/workspace" "$INSTALL_DIR/workspace/cron" \
  "$INSTALL_DIR/skills" "$INSTALL_DIR/vault" "$INSTALL_DIR/backups" \
  "$INSTALL_DIR/scripts" "/opt/scripts" "/opt/ansible/playbooks" "/opt/terraform"; do
  mkdir -p "$dir"
done
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/vault"
ok "All directories created"

header "STEP 5 — Config files"
cp "$REPO_DIR/skyclaw.toml" "$INSTALL_DIR/skyclaw.toml" && ok "skyclaw.toml"

MCP_TOML="$INSTALL_DIR/mcp.toml"
if [[ -f "$MCP_TOML" ]]; then
  warn "mcp.toml already exists — keeping your version"
else
  cp "$REPO_DIR/deploy/mcp.toml" "$MCP_TOML" && ok "mcp.toml"
fi

for f in workspace/HEARTBEAT.md workspace/backup.sh workspace/restore.sh; do
  if [[ -f "$REPO_DIR/$f" ]]; then
    cp "$REPO_DIR/$f" "$INSTALL_DIR/$f"
    chmod +x "$INSTALL_DIR/$f" 2>/dev/null || true
  fi
done
ok "Workspace files (HEARTBEAT, backup, restore)"

for skill in devops-core incident-response deployment self-management; do
  [[ -f "$REPO_DIR/skills/$skill.md" && ! -f "$INSTALL_DIR/skills/$skill.md" ]] && \
    cp "$REPO_DIR/skills/$skill.md" "$INSTALL_DIR/skills/$skill.md"
done
ok "Skills"

header "STEP 6 — .env"
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — not overwriting"
else
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Created $ENV_FILE — edit it now!"
  warn "Required: TELEGRAM_BOT_TOKEN, OPENROUTER_API_KEY, OWNER_CHAT_ID"
fi

mkdir -p /root/.config/opencode
if [[ ! -f /root/.config/opencode/opencode.json ]]; then
  set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
  cat > /root/.config/opencode/opencode.json << OEOF
{
  "provider": "openrouter",
  "model": "${OPENCODE_MODEL:-deepseek/deepseek-r1-0528}",
  "autoshare": false,
  "disabled_providers": []
}
OEOF
  chmod 600 /root/.config/opencode/opencode.json
  ok "opencode.json created"
fi

header "STEP 7 — SSH key"
SSH_KEY="/root/.ssh/batabeto"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -C "batabeto-agent" -f "$SSH_KEY" -N ""
  ok "SSH key generated"
else
  warn "SSH key already exists"
fi

if ! grep -q "batabeto-managed" /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config << 'SSHEOF'

# batabeto-managed
Host *
    IdentityFile /root/.ssh/batabeto
    ConnectTimeout 5
    StrictHostKeyChecking no
    ServerAliveInterval 30
SSHEOF
  chmod 600 /root/.ssh/config
  ok "SSH config updated"
fi

header "STEP 8 — Restore from GitHub backup"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
fi
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_USERNAME:-}" ]]; then
  bash "$INSTALL_DIR/workspace/restore.sh" && ok "Restore complete" || warn "No backup found"
else
  warn "GITHUB_TOKEN/GITHUB_USERNAME not set — skipping restore"
fi

header "STEP 9 — Bot systemd service"
cp "$REPO_DIR/deploy/skyclaw.service" /etc/systemd/system/skyclaw.service
systemctl daemon-reload
systemctl enable skyclaw
ok "skyclaw.service installed and enabled"

header "STEP 10 — Dashboard service"
cp "$REPO_DIR/skyclaw-dashboard.py" "$INSTALL_DIR/scripts/skyclaw-dashboard.py"
chmod +x "$INSTALL_DIR/scripts/skyclaw-dashboard.py"
ok "skyclaw-dashboard.py installed"

cat > /etc/systemd/system/skyclaw-dashboard.service << SVCEOF
[Unit]
Description=batabeto live dashboard
After=network.target skyclaw.service
Wants=skyclaw.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/.skyclaw
EnvironmentFile=-/root/.skyclaw/.env
Environment="PROJECT_DIR=$REPO_DIR"
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

systemctl daemon-reload
systemctl enable skyclaw-dashboard
ok "skyclaw-dashboard.service installed and enabled"

header "STEP 11 — ttyd (terminal tab)"
if ! command -v ttyd &>/dev/null; then
  info "Installing ttyd..."
  curl -sL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64" \
    -o /usr/local/bin/ttyd 2>/dev/null && chmod +x /usr/local/bin/ttyd || true
fi

if command -v ttyd &>/dev/null; then
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
  systemctl daemon-reload
  systemctl enable ttyd
  ok "ttyd installed and enabled"
else
  warn "ttyd install failed — Terminal tab won't work. Manual install: https://github.com/tsl0922/ttyd/releases"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║              SETUP COMPLETE                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}NEXT STEPS:${RESET}"
echo ""
echo -e "  ${YELLOW}1.${RESET} Edit secrets: ${BLUE}nano $INSTALL_DIR/.env${RESET}"
echo -e "     Required: TELEGRAM_BOT_TOKEN, OPENROUTER_API_KEY, OWNER_CHAT_ID"
echo ""
echo -e "  ${YELLOW}2.${RESET} Connect Tailscale on your phone:"
echo -e "     Install Tailscale app → sign in with same account as server"
echo ""
if [[ "$WITH_BUILD" == "true" ]]; then
  echo -e "  ${YELLOW}3.${RESET} Start everything: ${BLUE}sudo bash start.sh${RESET}"
else
  echo -e "  ${YELLOW}3.${RESET} From local PC, push the binary: ${BLUE}bash deploy.sh <server-ip>${RESET}"
  echo -e "  ${YELLOW}4.${RESET} Then start: ${BLUE}sudo bash start.sh${RESET}"
fi
echo ""
echo -e "${GREEN}${BOLD}Server is ready.${RESET}"
echo ""
