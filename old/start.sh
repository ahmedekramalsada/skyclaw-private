#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Start Script
# Usage: sudo bash start.sh
#
# Run this after install.sh to:
#   1. Verify .env is configured (TELEGRAM_BOT_TOKEN + OWNER_CHAT_ID)
#   2. Check binary and systemd service exist
#   3. Start the service
#   4. Confirm it's running and show live logs
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash start.sh"
fi

ENV_FILE="/root/.skyclaw/.env"
BINARY="/usr/local/bin/skyclaw"
SERVICE="skyclaw"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Startup                 ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── STEP 1 — Pre-flight checks ───────────────────────────────────────────────
header "STEP 1 — Pre-flight checks"

# Binary
if [[ ! -f "$BINARY" ]]; then
  err "Binary not found at $BINARY — run install.sh first"
fi
ok "Binary found: $BINARY ($(du -sh $BINARY | cut -f1))"

# Systemd service file
if ! systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
  err "Systemd service '${SERVICE}' not found — run install.sh first"
fi
ok "Systemd service registered: ${SERVICE}.service"

# .env file
if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found at $ENV_FILE — run install.sh first"
fi
ok ".env file found: $ENV_FILE"

# ── STEP 2 — Validate .env ───────────────────────────────────────────────────
header "STEP 2 — Validating .env"

source "$ENV_FILE" 2>/dev/null || true

MISSING=0

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ "${TELEGRAM_BOT_TOKEN:-}" == "your_telegram_bot_token_here" ]]; then
  warn "TELEGRAM_BOT_TOKEN is not set in $ENV_FILE"
  echo "       Get a token from @BotFather on Telegram, then:"
  echo "       nano $ENV_FILE"
  MISSING=1
else
  # Mask the token in output
  MASKED="${TELEGRAM_BOT_TOKEN:0:10}...${TELEGRAM_BOT_TOKEN: -4}"
  ok "TELEGRAM_BOT_TOKEN set ($MASKED)"
fi

if [[ -z "${OWNER_CHAT_ID:-}" ]] || [[ "${OWNER_CHAT_ID:-}" == "your_telegram_chat_id_here" ]]; then
  warn "OWNER_CHAT_ID is not set — proactive alerts and heartbeat reports will be disabled"
  echo "       Get your chat ID from @userinfobot on Telegram, then:"
  echo "       echo 'OWNER_CHAT_ID=123456789' >> $ENV_FILE"
else
  ok "OWNER_CHAT_ID set ($OWNER_CHAT_ID)"
fi

if [[ $MISSING -eq 1 ]]; then
  echo ""
  echo -e "${RED}✗${RESET} Cannot start — TELEGRAM_BOT_TOKEN is required."
  echo ""
  echo "  Edit your .env file:"
  echo -e "  ${BLUE}nano $ENV_FILE${RESET}"
  echo ""
  echo "  Then re-run this script:"
  echo -e "  ${BLUE}sudo bash start.sh${RESET}"
  echo ""
  exit 1
fi

# ── STEP 3 — Clean Slate & OpenCode Startup ──────────────────────────────────
header "STEP 3 — Clean Slate & OpenCode Startup"

info "Cleaning up stale opencode processes..."
killall opencode-mcp opencode 2>/dev/null || true
# Wait for port to clear
sleep 1

info "Starting OpenCode server on port 4096..."
opencode serve --port 4096 > /tmp/opencode-startup.log 2>&1 &
sleep 2

if ! lsof -i :4096 >/dev/null; then
  err "OpenCode server failed to start on port 4096. Check /tmp/opencode-startup.log"
fi
ok "OpenCode server is running on port 4096"

# ── STEP 4 — Start service ───────────────────────────────────────────────────
header "STEP 4 — Starting batabeto"

# If already running, restart instead
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  warn "batabeto is already running — restarting"
  systemctl restart "$SERVICE"
  ok "batabeto restarted"
else
  systemctl start "$SERVICE"
  ok "batabeto started"
fi

# ── STEP 4 — Verify it came up ───────────────────────────────────────────────
header "STEP 4 — Verifying startup"

sleep 2

if systemctl is-active --quiet "$SERVICE"; then
  ok "batabeto is running"
  UPTIME=$(systemctl show "$SERVICE" --property=ActiveEnterTimestamp | cut -d= -f2)
  info "Started at: $UPTIME"
else
  echo ""
  err "batabeto failed to start. Check logs:"$'\n'"  journalctl -fu $SERVICE"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}batabeto is live. Open Telegram and message your bot.${RESET}"
echo ""
echo -e "  First message:  ${BLUE}/help${RESET}"
echo -e "  Add API key:    ${BLUE}/addkey${RESET}"
echo -e "  Watch logs:     ${BLUE}journalctl -fu $SERVICE${RESET}"
echo -e "  Stop:           ${BLUE}systemctl stop $SERVICE${RESET}"
echo ""

# ── STEP 5 — Tail logs ───────────────────────────────────────────────────────
header "STEP 5 — Live logs (Ctrl+C to exit)"
echo ""
journalctl -fu "$SERVICE" --output=short-iso
