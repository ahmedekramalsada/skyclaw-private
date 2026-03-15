#!/usr/bin/env bash
# server-setup.sh — First-time server setup (run directly on the server)
# Usage: sudo bash server-setup.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash server-setup.sh"

INSTALL_DIR="/root/.skyclaw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    batabeto — First-time Server Setup    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

header "STEP 1 — System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl wget build-essential sqlite3
ok "System packages installed"

header "STEP 2 — Node.js"
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
fi
ok "Node.js $(node --version)"

header "STEP 3 — OpenCode"
command -v opencode &>/dev/null || npm install -g opencode-ai --silent 2>/dev/null || true
command -v opencode &>/dev/null && ok "OpenCode installed" || warn "OpenCode install failed — coding tasks will use shell fallback"

header "STEP 4 — Directories"
for d in "$INSTALL_DIR" "$INSTALL_DIR/workspace" "$INSTALL_DIR/workspace/cron" \
  "$INSTALL_DIR/skills" "$INSTALL_DIR/vault" "$INSTALL_DIR/backups" \
  /opt/scripts /opt/ansible/playbooks /opt/terraform; do
  mkdir -p "$d"
done
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/vault"
chown -R root:root "$INSTALL_DIR"
ok "Directories created"

header "STEP 5 — Config files"
[[ -f "$SCRIPT_DIR/skyclaw.toml" ]] && cp "$SCRIPT_DIR/skyclaw.toml" "$INSTALL_DIR/skyclaw.toml" && ok "skyclaw.toml"
if [[ -f "$SCRIPT_DIR/deploy/mcp.toml" ]]; then
  [[ ! -f "$INSTALL_DIR/mcp.toml" ]] && cp "$SCRIPT_DIR/deploy/mcp.toml" "$INSTALL_DIR/mcp.toml"
  ok "mcp.toml"
fi
if [[ ! -f "$INSTALL_DIR/.env" && -f "$SCRIPT_DIR/.env.example" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  ok ".env created from template — edit it: nano $INSTALL_DIR/.env"
fi

header "STEP 6 — Skills"
for skill in devops-core incident-response deployment self-management telegram-features study-and-learning planning-and-projects; do
  [[ -f "$SCRIPT_DIR/skills/$skill.md" ]] && \
    cp "$SCRIPT_DIR/skills/$skill.md" "$INSTALL_DIR/skills/$skill.md"
done
ok "Skills installed"

header "STEP 7 — Workspace files"
for f in HEARTBEAT.md backup.sh restore.sh; do
  [[ -f "$SCRIPT_DIR/workspace/$f" ]] && \
    cp "$SCRIPT_DIR/workspace/$f" "$INSTALL_DIR/workspace/$f" && \
    chmod +x "$INSTALL_DIR/workspace/$f" 2>/dev/null || true
done
ok "Workspace files installed"

header "STEP 8 — Bot systemd service"
cp "$SCRIPT_DIR/deploy/skyclaw.service" /etc/systemd/system/skyclaw.service
systemctl daemon-reload
systemctl enable skyclaw
ok "skyclaw.service installed and enabled"

header "STEP 9 — SSH key for batabeto"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[[ ! -f /root/.ssh/batabeto ]] && \
  ssh-keygen -t ed25519 -C "batabeto-agent" -f /root/.ssh/batabeto -N ""
ok "SSH key ready: /root/.ssh/batabeto"

header "STEP 10 — OpenCode config"
mkdir -p /root/.config/opencode
if [[ ! -f /root/.config/opencode/opencode.json ]]; then
  echo '{"provider":"openrouter","model":"deepseek/deepseek-r1-0528","autoshare":false,"disabled_providers":[]}' \
    > /root/.config/opencode/opencode.json
  chmod 600 /root/.config/opencode/opencode.json
fi
ok "OpenCode config"

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo -e "  ${YELLOW}NEXT STEPS:${RESET}"
echo -e "  1. Edit .env:     ${BLUE}nano $INSTALL_DIR/.env${RESET}"
echo -e "     Set: TELEGRAM_BOT_TOKEN, OPENROUTER_API_KEY, OWNER_CHAT_ID"
echo -e "  3. Copy binary:   ${BLUE}sudo cp target/release/skyclaw /usr/local/bin/${RESET}"
echo -e "  4. Start:         ${BLUE}sudo bash start.sh${RESET}"
echo ""
