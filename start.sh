#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — Start batabeto + dashboard + terminal
# Usage: sudo bash start.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash start.sh"

ENV_FILE="/root/.skyclaw/.env"
BINARY="/usr/local/bin/skyclaw"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Startup                 ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

header "STEP 1 — Pre-flight checks"
[[ ! -f "$BINARY" ]] && err "Binary not found at $BINARY — run server-setup.sh or deploy.sh first"
ok "Binary: $BINARY ($(du -sh $BINARY | cut -f1))"

[[ ! -f "$ENV_FILE" ]] && err ".env not found at $ENV_FILE — run server-setup.sh first"
ok ".env found"

header "STEP 2 — Validate .env"
source "$ENV_FILE" 2>/dev/null || true

MISSING=0
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || "${TELEGRAM_BOT_TOKEN:-}" == *"your"* ]]; then
  warn "TELEGRAM_BOT_TOKEN not set"; MISSING=1
else
  ok "TELEGRAM_BOT_TOKEN (${TELEGRAM_BOT_TOKEN:0:10}...)"
fi
if [[ -z "${OWNER_CHAT_ID:-}" || "${OWNER_CHAT_ID:-}" == *"your"* ]]; then
  warn "OWNER_CHAT_ID not set — proactive alerts + dashboard link disabled"
else
  ok "OWNER_CHAT_ID ($OWNER_CHAT_ID)"
fi
[[ $MISSING -eq 1 ]] && err "TELEGRAM_BOT_TOKEN is required. Edit: nano $ENV_FILE"

header "STEP 3 — OpenCode"
info "Cleaning stale opencode processes..."
killall opencode-mcp opencode 2>/dev/null || true
sleep 1
info "Starting OpenCode on port 4096..."
opencode serve --port 4096 > /tmp/opencode-startup.log 2>&1 &
sleep 2
lsof -i :4096 >/dev/null 2>&1 && ok "OpenCode running on port 4096" || \
  warn "OpenCode failed to start — coding tasks will use shell fallback"

header "STEP 4 — Dashboard"
if [[ -f /root/.skyclaw/scripts/skyclaw-dashboard.py ]]; then
  if systemctl is-active --quiet skyclaw-dashboard 2>/dev/null; then
    systemctl restart skyclaw-dashboard
    ok "Dashboard restarted"
  else
    systemctl start skyclaw-dashboard 2>/dev/null && ok "Dashboard started" || \
      warn "Dashboard failed — check: journalctl -fu skyclaw-dashboard"
  fi
else
  warn "Dashboard script not found — run server-setup.sh first"
fi

header "STEP 5 — ttyd terminal"
if command -v ttyd &>/dev/null; then
  if systemctl is-active --quiet ttyd 2>/dev/null; then
    systemctl restart ttyd && ok "ttyd restarted"
  else
    systemctl start ttyd 2>/dev/null && ok "ttyd started" || warn "ttyd failed to start"
  fi
else
  warn "ttyd not installed — Terminal tab won't work"
fi

header "STEP 6 — Start batabeto"
if systemctl is-active --quiet skyclaw 2>/dev/null; then
  warn "Already running — restarting"
  systemctl restart skyclaw
  ok "batabeto restarted"
else
  systemctl start skyclaw
  ok "batabeto started"
fi

sleep 2
systemctl is-active --quiet skyclaw || err "batabeto failed to start. Check: journalctl -fu skyclaw"

echo ""
echo -e "${GREEN}${BOLD}batabeto is live!${RESET}"
echo ""
echo -e "  ${BOLD}Telegram commands:${RESET}"
echo -e "    /help      — list all commands"
echo -e "    /addkey    — add your OpenRouter API key"
echo -e "    /model     — choose your model"
echo -e "    /status    — server health snapshot"
echo ""
echo -e "  ${BOLD}Dashboard:${RESET}"
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [[ -n "$TS_IP" ]]; then
  TOKEN=$(cat /root/.skyclaw/dashboard-token 2>/dev/null || echo "(starting...)")
  echo -e "    ${BLUE}http://$TS_IP:8888/dashboard?token=$TOKEN${RESET}"
else
  echo -e "    Run 'tailscale up' then the bot will send you the link"
fi
echo ""
echo -e "  ${BOLD}Logs:${RESET}"
echo -e "    ${BLUE}journalctl -fu skyclaw${RESET}           — bot"
echo -e "    ${BLUE}journalctl -fu skyclaw-dashboard${RESET} — dashboard"
echo ""
header "Live logs (Ctrl+C to exit)"
echo ""
journalctl -fu skyclaw --output=short-iso
