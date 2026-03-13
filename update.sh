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
SWAP_FILE=/swapfile_batabeto_build

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

# ── Step 2 — Add swap if RAM is low ──────────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

if [[ "$TOTAL_RAM_MB" -lt 3072 ]]; then
  warn "Low RAM (${TOTAL_RAM_MB} MB) — adding 2 GB swap for the build..."
  if [[ ! -f "$SWAP_FILE" ]]; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE" 2>/dev/null || true
  ok "Swap enabled"
fi

# ── Step 3 — Build ───────────────────────────────────────────────────────────
header "STEP 2 — Building release binary"

source "$HOME/.cargo/env" 2>/dev/null || true

info "Building with single-threaded settings (safe for 2 GB RAM)..."
info "This takes 5–15 min if only a few files changed (incremental build)."
echo ""

cd "$REPO_DIR"

export CARGO_BUILD_JOBS=1
export RUSTFLAGS="-C codegen-units=1 -C opt-level=s"

cargo build --release --jobs 1 2>&1 | grep -E "Compiling|Finished|error\[|warning\[" || true

if [[ ! -f "$REPO_DIR/target/release/skyclaw" ]]; then
  err "Build failed — binary not found"
fi
ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"

# ── Step 4 — Install binary ───────────────────────────────────────────────────
header "STEP 3 — Installing binary"

cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
ok "Binary installed: $BINARY_PATH"

# ── Step 5 — Remove swap ─────────────────────────────────────────────────────
if [[ -f "$SWAP_FILE" ]]; then
  swapoff "$SWAP_FILE" 2>/dev/null || true
  rm -f "$SWAP_FILE"
  ok "Build swap removed"
fi

# ── Step 6 — Restart ─────────────────────────────────────────────────────────
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
