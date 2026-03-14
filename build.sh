#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Local Build
# Usage: bash build.sh
#
# Builds the skyclaw release binary on your local machine.
# After building, use deploy.sh to push it to a server.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="skyclaw"
LOCAL_BINARY="$REPO_DIR/target/release/$BINARY_NAME"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RED='\033[0;31m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Local Build             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Check dependencies ───────────────────────────────────────────────
info "Checking build dependencies..."

if ! command -v cargo &>/dev/null; then
  warn "Rust/cargo not found. Installing via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
  ok "Rust installed"
else
  ok "Rust found: $(rustc --version)"
fi

if ! command -v cc &>/dev/null; then
  warn "C linker (cc) not found. Installing build-essential..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt update && sudo apt install -y build-essential
  else
    err "Please install a C compiler for your OS"
  fi
fi
ok "Linker found"

# OpenSSL + pkg-config (Linux only)
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  if ! dpkg -s libssl-dev &>/dev/null 2>&1 || ! command -v pkg-config &>/dev/null; then
    warn "OpenSSL headers or pkg-config missing. Installing..."
    sudo apt update && sudo apt install -y libssl-dev pkg-config
  fi
  ok "OpenSSL/pkg-config ready"
fi

# ── Step 2: Build ────────────────────────────────────────────────────────────
info "Building $BINARY_NAME in release mode..."
cd "$REPO_DIR"
cargo build --release

if [[ ! -f "$LOCAL_BINARY" ]]; then
  err "Build failed — binary not found at $LOCAL_BINARY"
fi

ok "Build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"
echo ""
echo -e "  Binary: ${BLUE}$LOCAL_BINARY${RESET}"
echo ""
echo -e "  ${BOLD}NEXT:${RESET} Deploy to server:"
echo -e "    ${BLUE}bash deploy.sh <server-alias-or-ip>${RESET}"
echo -e "    ${BLUE}bash deploy.sh <target> -c${RESET}       (also sync config)"
echo -e "    ${BLUE}bash deploy.sh <target> --no-build${RESET} (skip build, push existing)"
echo ""
