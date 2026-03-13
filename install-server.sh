#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Server Setup Script
# Usage: sudo bash install-server.sh [--no-build]
#
# Mode:
#   Full (default): Installs everything and BUILDS the binary on the server.
#   Light (--no-build): Installs dependencies and services but SKIPS building.
#                       Use this if you deploy via push.sh from your PC.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/root/.skyclaw"
BINARY_PATH="/usr/local/bin/skyclaw"
NO_BUILD=false

if [[ "${1:-}" == "--no-build" ]]; then
  NO_BUILD=true
fi

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash install-server.sh"
fi

header "Server Setup Mode: $(if $NO_BUILD; then echo 'LIGHT (No Build)'; else echo 'FULL (With Build)'; fi)"

# ── Step 1: Core Dependencies ────────────────────────────────────────────────
header "STEP 1 — Runtime Dependencies"

# Git
if ! command -v git &>/dev/null; then
  apt-get update && apt-get install -y git
fi
ok "git found"

# Node.js + npx
if ! command -v node &>/dev/null; then
  info "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y nodejs >/dev/null 2>&1
fi
ok "Node.js $(node --version) found"

# OpenCode
if ! command -v opencode &>/dev/null; then
  info "Installing opencode-ai..."
  npm install -g opencode-ai --silent
fi
ok "opencode found"

# ── Step 2: Build (Optional) ─────────────────────────────────────────────────
if $NO_BUILD; then
  header "STEP 2 — Skipping build (deploy via push.sh later)"
else
  header "STEP 2 — Building on server"
  
  if ! command -v cargo &>/dev/null; then
    info "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
  fi
  
  if ! command -v cc &>/dev/null; then
    apt-get update && apt-get install -y build-essential
  fi

  # ── OpenSSL and pkg-config (Required for openssl-sys) ───────────────────────
  info "Installing build dependencies (OpenSSL, pkg-config)..."
  apt-get update && apt-get install -y libssl-dev pkg-config
  cd "$REPO_DIR"
  rm -f target/release/skyclaw
  set -o pipefail
  cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true
  
  if [[ -f "target/release/skyclaw" ]]; then
    cp "target/release/skyclaw" "$BINARY_PATH"
    chmod 755 "$BINARY_PATH"
    ok "Build and install successful"
  else
    err "Build failed"
  fi
fi

# ── Step 3: Directories & Files ──────────────────────────────────────────────
header "STEP 3 — Filesystem Setup"

for dir in "$INSTALL_DIR" "$INSTALL_DIR/workspace" "$INSTALL_DIR/skills" "$INSTALL_DIR/vault" "/root/.ssh"; do
  mkdir -p "$dir"
  ok "Created $dir"
done
chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/vault" "/root/.ssh"

# Configs
cp "$REPO_DIR/skyclaw.toml" "$INSTALL_DIR/skyclaw.toml"
if [[ ! -f "$INSTALL_DIR/mcp.toml" ]]; then
  cp "$REPO_DIR/deploy/mcp.toml" "$INSTALL_DIR/mcp.toml"
fi
ok "Configuration files initialized"

# .env
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$REPO_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  ok ".env template created"
fi

# ── Step 4: Systemd ──────────────────────────────────────────────────────────
header "STEP 4 — Service Setup"

SERVICE_FILE="/etc/systemd/system/skyclaw.service"
cp "$REPO_DIR/deploy/skyclaw.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable skyclaw
ok "Service skyclaw enabled"

# ── Final ────────────────────────────────────────────────────────────────────
header "Setup Complete"

if $NO_BUILD; then
  info "Binary is NOT installed yet."
  info "Run this on your LOCAL PC to finish deployment:"
  info "  bash push.sh <this-server-ip>"
else
  info "Bot is ready. Start it with: systemctl start skyclaw"
fi
