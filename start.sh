#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — Start batabeto + OpenCode
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
[[ ! -f "$BINARY" ]] && err "Binary not found at $BINARY — run deploy.sh first"
ok "Binary: $BINARY ($(du -sh $BINARY | cut -f1))"
[[ ! -f "$ENV_FILE" ]] && err ".env not found at $ENV_FILE — run deploy.sh --init first"
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
  warn "OWNER_CHAT_ID not set — proactive alerts disabled"
else
  ok "OWNER_CHAT_ID ($OWNER_CHAT_ID)"
fi
[[ $MISSING -eq 1 ]] && err "TELEGRAM_BOT_TOKEN is required. Edit: nano $ENV_FILE"

header "STEP 3 — OpenCode (systemd)"
# OpenCode runs as a proper systemd service — not a fragile background process
if systemctl is-enabled opencode &>/dev/null; then
  systemctl restart opencode
  sleep 2
  systemctl is-active --quiet opencode && ok "OpenCode running on port 4096" || \
    warn "OpenCode failed — coding tasks will use shell fallback. Check: journalctl -fu opencode"
else
  warn "opencode.service not installed — run deploy.sh --init to fix"
  warn "Coding tasks will use shell fallback"
fi

header "STEP 4 — Kill any stale bot processes (prevents 409)"
pkill -f "/usr/local/bin/skyclaw" 2>/dev/null || true
sleep 2
ok "Stale processes cleared"

header "STEP 5 — Start batabeto"
systemctl start skyclaw
sleep 2
systemctl is-active --quiet skyclaw && ok "batabeto running" || \
  err "batabeto failed to start. Check: journalctl -fu skyclaw"

header "STEP 6 — Cron jobs"
if crontab -l 2>/dev/null | grep -q "backup\.sh"; then
  ok "Backup cron active"
else
  warn "Backup cron not installed — run deploy.sh --init to fix"
fi
if crontab -l 2>/dev/null | grep -q "heartbeat"; then
  ok "Heartbeat cron active"
else
  warn "Heartbeat cron not installed — run deploy.sh --init to fix"
fi

echo ""
echo -e "${GREEN}${BOLD}batabeto is live!${RESET}"
echo ""
echo -e "  ${BOLD}Telegram commands:${RESET}"
echo -e "    /help      — list all commands"
echo -e "    /addkey    — add your OpenRouter API key"
echo -e "    /model     — choose your model"
echo -e "    /status    — server health snapshot"
echo ""
echo -e "  ${BOLD}Logs:${RESET}"
echo -e "    ${BLUE}journalctl -fu skyclaw${RESET}   — bot"
echo -e "    ${BLUE}journalctl -fu opencode${RESET}  — opencode"
echo ""
header "Live logs (Ctrl+C to exit)"
echo ""
journalctl -fu skyclaw --output=short-iso
