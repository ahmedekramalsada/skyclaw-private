#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# server-update.sh — Pull + Build + Restart (Big Servers Only)
# Usage: sudo bash server-update.sh
#
# For servers that build on-server (>2 GB RAM).
# Pulls latest code, builds, installs binary, restarts service.
#
# For small servers, use deploy.sh from your local PC instead.
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
  err "Run as root: sudo bash server-update.sh"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="/usr/local/bin/skyclaw"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Server Update           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1 — Pull latest ────────────────────────────────────────────────────
header "STEP 1 — Pulling latest code"

cd "$REPO_DIR"
git pull --ff-only || git pull --rebase
ok "Code updated"

# ── Step 2 — Stop service ───────────────────────────────────────────────────
header "STEP 2 — Stopping batabeto"

if systemctl is-active --quiet skyclaw 2>/dev/null; then
  systemctl stop skyclaw
  ok "batabeto stopped"
else
  warn "batabeto was not running"
fi

# ── Step 3 — Build ──────────────────────────────────────────────────────────
header "STEP 3 — Building release binary"

# Ensure linker is available
if ! command -v cc &>/dev/null; then
  warn "cc (linker) not found. Checking common locations..."
  export PATH="$PATH:/usr/bin:/usr/local/bin"
  if ! command -v cc &>/dev/null; then
    err "linker 'cc' not found. Try: apt install build-essential"
  fi
fi

source "$HOME/.cargo/env" 2>/dev/null || true

info "Building with -j1 (one crate at a time, safe for low RAM)..."
info "Incremental builds take 5–15 min."
echo ""

# Ensure we don't use a stale binary
rm -f target/release/skyclaw

set -o pipefail
cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true

if [[ ! -f "$REPO_DIR/target/release/skyclaw" ]]; then
  err "Build failed — binary not found. Try: sudo -E bash server-update.sh"
fi
ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"

# ── Step 4 — Install binary ─────────────────────────────────────────────────
header "STEP 4 — Installing binary"

cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
ok "Binary installed: $BINARY_PATH"

# ── Step 5 — Restart ────────────────────────────────────────────────────────
header "STEP 5 — Restarting batabeto"

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
