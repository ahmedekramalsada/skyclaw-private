#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Local Build Script
# Usage: bash install-local.sh
#
# This script prepares your local machine for building SkyClaw.
# It installs Rust and build tools, then compiles the binary.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }

echo -e "${BOLD}Local Setup & Build${RESET}\n"

# ── Step 1: Dependencies ─────────────────────────────────────────────────────
info "Checking local dependencies..."

if ! command -v cargo &>/dev/null; then
  warn "Rust/cargo not found. Installing..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
else
  ok "Rust/cargo found."
fi

if ! command -v cc &>/dev/null; then
  warn "C linker (cc) not found. Please install build-essential."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt update && sudo apt install -y build-essential
  fi
fi
ok "Linker found."

# ── Step 1.1: OpenSSL & pkg-config (Linux only) ──────────────────────────────
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  info "Checking for OpenSSL development headers..."
  if ! dpkg -s libssl-dev &>/dev/null || ! command -v pkg-config &>/dev/null; then
    warn "OpenSSL headers or pkg-config missing. Installing..."
    sudo apt update && sudo apt install -y libssl-dev pkg-config
  fi
  ok "Build dependencies (OpenSSL/pkg-config) ready."
fi

# ── Step 2: Build ────────────────────────────────────────────────────────────
info "Building skyclaw locally..."
cd "$REPO_DIR"
cargo build --release

if [[ -f "target/release/skyclaw" ]]; then
  ok "Local build complete: target/release/skyclaw"
  echo ""
  info "NEXT STEP: Deploy to your server using push.sh"
  info "Usage: bash push.sh <server-alias-or-ip>"
else
  echo -e "Error: Build failed."
  exit 1
fi
