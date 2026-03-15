#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# server-update.sh — Pull + Build + Restart (on-server build)
# Usage: sudo bash server-update.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash server-update.sh"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="/usr/local/bin/skyclaw"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Server Update           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

header "STEP 1 — Pull latest code"
cd "$REPO_DIR"
git pull --ff-only || git pull --rebase
ok "Code updated"

header "STEP 2 — Stop services"
systemctl is-active --quiet skyclaw 2>/dev/null && systemctl stop skyclaw && ok "bot stopped" || warn "bot was not running"
systemctl is-active --quiet skyclaw-dashboard 2>/dev/null && systemctl stop skyclaw-dashboard && ok "dashboard stopped" || true

header "STEP 3 — Build release binary"
command -v cc &>/dev/null || err "linker 'cc' not found — try: apt install build-essential"
source "$HOME/.cargo/env" 2>/dev/null || true

info "Building (incremental, ~5-15 min)..."
rm -f target/release/skyclaw
cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true
[[ ! -f "$REPO_DIR/target/release/skyclaw" ]] && err "Build failed — see output above"
ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"

header "STEP 4 — Install binary"
cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
ok "Binary installed: $BINARY_PATH"

header "STEP 5 — Update dashboard script"
cp "$REPO_DIR/skyclaw-dashboard.py" /root/.skyclaw/scripts/skyclaw-dashboard.py
chmod +x /root/.skyclaw/scripts/skyclaw-dashboard.py
ok "Dashboard script updated"

header "STEP 6 — Update MCP config"
# Only update mcp.toml if it hasn't been customised (check via git)
if git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -q "deploy/mcp.toml"; then
  warn "deploy/mcp.toml changed in this update."
  warn "Your current /root/.skyclaw/mcp.toml was NOT overwritten."
  warn "Review the changes: git diff HEAD~1 HEAD deploy/mcp.toml"
  warn "Then manually apply to /root/.skyclaw/mcp.toml if needed."
fi

header "STEP 7 — Restart services"
systemctl start skyclaw
sleep 2
systemctl is-active --quiet skyclaw && ok "bot running" || err "bot failed to start — check: journalctl -fu skyclaw"

systemctl start skyclaw-dashboard
sleep 1
systemctl is-active --quiet skyclaw-dashboard && ok "dashboard running" || warn "dashboard failed to start — check: journalctl -fu skyclaw-dashboard"

systemctl is-active --quiet ttyd 2>/dev/null && systemctl restart ttyd && ok "ttyd running" || true

echo ""
echo -e "${GREEN}${BOLD}Update complete. batabeto is live.${RESET}"
echo ""
echo -e "  Watch bot logs:       ${BLUE}journalctl -fu skyclaw${RESET}"
echo -e "  Watch dashboard logs: ${BLUE}journalctl -fu skyclaw-dashboard${RESET}"
echo ""
