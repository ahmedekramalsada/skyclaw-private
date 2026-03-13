#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Fast Update Script
# Usage: sudo bash update.sh
#
# Use this after ANY change to Rust source code (system prompt, telegram.rs, etc).
# Does NOT reinstall Node.js, SSH keys, directories, or service files.
# Just: pull latest → build → copy binary → restart.
#
# For non-code changes, skip this entirely:
#   Edit .env / skyclaw.toml / mcp.toml → systemctl restart skyclaw
#   Edit skill files (*.md)             → nothing, symlink is live
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
  err "Run as root: sudo bash update.sh"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="/usr/local/bin/skyclaw"
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Fast Update             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1 — Stop service ────────────────────────────────────────────────────
header "STEP 1 — Stopping batabeto"

if systemctl is-active --quiet skyclaw 2>/dev/null; then
  systemctl stop skyclaw
  ok "batabeto stopped"
else
  warn "batabeto was not running"
fi

# ── Step 2 — Build ───────────────────────────────────────────────────────────
header "STEP 2 — Building release binary"
info "Using -j1 (one crate at a time). Slow on first build, fast on incremental."

source "$HOME/.cargo/env" 2>/dev/null || true

info "Building with single-threaded settings (safe for 2 GB RAM)..."
info "This takes 5–15 min if only a few files changed (incremental build)."
echo ""

cd "$REPO_DIR"

cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true

if [[ ! -f "$REPO_DIR/target/release/skyclaw" ]]; then
  err "Build failed — binary not found"
fi
ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"

# ── Step 3 — Install binary ───────────────────────────────────────────────────
header "STEP 3 — Installing binary"

cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
ok "Binary installed: $BINARY_PATH"

# ── Step 4 — Restart ─────────────────────────────────────────────────────────
header "STEP 4 — Restarting batabeto"

systemctl start skyclaw
sleep 2

if systemctl is-active --quiet skyclaw; then
  ok "batabeto is running"
else
  err "batabeto failed to start — check: journalctl -fu skyclaw"
fi

echo ""
echo -e "${GREEN}${BOLD}Update complete. batabeto is live.${RESET}"
echo ""
echo -e "  Watch logs:   ${BLUE}journalctl -fu skyclaw${RESET}"
echo -e "  Check status: ${BLUE}systemctl status skyclaw${RESET}"
echo ""
