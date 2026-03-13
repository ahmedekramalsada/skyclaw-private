#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Pure Server Setup Script
# Usage: sudo bash install-server.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/root/.skyclaw"
BINARY_PATH="/usr/local/bin/skyclaw"

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

header "Server Setup — Optimized for Local Build + Push"

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

# ── Step 2 — Skipping Build ──────────────────────────────────────────────────
header "STEP 2 — Skipping Build"
info "This server will NOT compile SkyClaw."
info "Please use push.sh from your local PC to upload the binary."
ok "Server prepared for binary delivery."

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
  # Try deploy folder if available
  if [[ -f "$REPO_DIR/deploy/mcp.toml" ]]; then
    cp "$REPO_DIR/deploy/mcp.toml" "$INSTALL_DIR/mcp.toml"
  fi
fi
ok "Configuration files initialized"

# .env
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  if [[ -f "$REPO_DIR/.env.example" ]]; then
    cp "$REPO_DIR/.env.example" "$INSTALL_DIR/.env"
  fi
  chmod 600 "$INSTALL_DIR/.env"
  ok ".env template created"
fi

# ── Step 4: Systemd Service ──────────────────────────────────────────────────
header "STEP 4 — Service Setup"

SERVICE_FILE="/etc/systemd/system/skyclaw.service"
if [[ -f "$REPO_DIR/deploy/skyclaw.service" ]]; then
  cp "$REPO_DIR/deploy/skyclaw.service" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable skyclaw
  ok "Service skyclaw enabled"
else
  warn "Service file not found at deploy/skyclaw.service — skipping service setup"
fi

# ── Final ────────────────────────────────────────────────────────────────────
header "Setup Complete"

info "Server setup is finished. To complete installation:"
info "1. Go to your local PC."
info "2. Build local: bash install-local.sh"
info "3. Push to this server: bash push.sh <ip-or-alias>"
echo ""
ok "SkyClaw ready for deployment."
