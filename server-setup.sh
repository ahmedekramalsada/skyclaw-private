#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# server-setup.sh — First-Time Server Setup
# Usage: sudo bash server-setup.sh [--with-build]
#
# Default:       Install runtime deps + set up dirs/configs/service.
#                NO Rust, NO build. Use deploy.sh from your local PC to push
#                the binary afterward.
#
# --with-build:  Also install Rust + build-essential and compile the binary
#                on the server. Use this for servers with >2 GB RAM.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Parse flags ──────────────────────────────────────────────────────────────
WITH_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --with-build) WITH_BUILD=true ;;
    *)            echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

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

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
info()   { echo -e "${BLUE}→${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; echo "────────────────────────────────────────"; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash server-setup.sh"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — Server Setup            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
if [[ "$WITH_BUILD" == "true" ]]; then
  echo -e "${BOLD}║       Mode: FULL (with build)            ║${RESET}"
else
  echo -e "${BOLD}║       Mode: RUNTIME ONLY (no build)      ║${RESET}"
fi
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Dependencies
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 1 — Installing dependencies"

# Git
if ! command -v git &>/dev/null; then
  info "Installing git..."
  apt-get update && apt-get install -y git
fi
ok "git found"

# Node.js + npx (required for MCP servers)
if ! command -v node &>/dev/null; then
  info "Installing Node.js (LTS)..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y nodejs >/dev/null 2>&1
fi
ok "Node.js $(node --version)"

if ! command -v npx &>/dev/null; then
  err "npx not found after Node.js install — try: apt install nodejs"
fi
ok "npx found"

# OpenCode — AI coding agent (MCP integration)
if ! command -v opencode &>/dev/null; then
  info "Installing opencode-ai..."
  npm install -g opencode-ai --silent
fi
ok "opencode found"

# ── Build dependencies (only with --with-build) ─────────────────────────────
if [[ "$WITH_BUILD" == "true" ]]; then
  # Rust
  if ! command -v cargo &>/dev/null; then
    info "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
    ok "Rust installed"
  else
    ok "Rust found: $(rustc --version)"
  fi

  # C linker + build tools
  if ! command -v cc &>/dev/null; then
    info "Installing build-essential..."
    apt-get update && apt-get install -y build-essential
  fi
  ok "C linker found"

  # OpenSSL dev headers
  if ! dpkg -s libssl-dev &>/dev/null 2>&1 || ! command -v pkg-config &>/dev/null; then
    info "Installing OpenSSL dev headers + pkg-config..."
    apt-get update && apt-get install -y libssl-dev pkg-config
  fi
  ok "OpenSSL/pkg-config ready"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Build (only with --with-build)
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$WITH_BUILD" == "true" ]]; then
  header "STEP 2 — Building release binary"

  # Ensure cargo is in PATH
  source "$HOME/.cargo/env" 2>/dev/null || true

  info "Building skyclaw (-j1, safe for low-RAM servers)..."
  info "First build takes 20–40 min. Incremental builds are much faster."
  echo ""

  cd "$REPO_DIR"
  rm -f target/release/skyclaw

  set -o pipefail
  cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true

  if [[ ! -f "$REPO_DIR/target/release/skyclaw" ]]; then
    err "Build failed — binary not found at target/release/skyclaw"
  fi
  ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1)"

  # Install binary
  cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
  chmod 755 "$BINARY_PATH"
  ok "Binary installed at $BINARY_PATH"
else
  header "STEP 2 — Skipping build"
  info "This server will NOT compile SkyClaw."
  info "Use deploy.sh from your local PC to push the binary."
  ok "Server prepared for binary delivery"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Directories
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 3 — Creating directories"

for dir in \
  "$INSTALL_DIR" \
  "$INSTALL_DIR/workspace" \
  "$INSTALL_DIR/workspace/cron" \
  "$INSTALL_DIR/skills" \
  "$INSTALL_DIR/vault" \
  "$INSTALL_DIR/backups" \
  "/opt/scripts" \
  "/opt/ansible/playbooks" \
  "/opt/terraform"; do
  mkdir -p "$dir"
done

chmod 700 "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR/vault"
ok "All directories created"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Config files
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 4 — Copying config files"

# Main config
cp "$REPO_DIR/skyclaw.toml" "$INSTALL_DIR/skyclaw.toml"
ok "skyclaw.toml"

# MCP config — don't overwrite if customised
MCP_TOML="$INSTALL_DIR/mcp.toml"
if [[ -f "$MCP_TOML" ]]; then
  warn "mcp.toml already exists — keeping your customised version"
else
  if [[ -f "$REPO_DIR/deploy/mcp.toml" ]]; then
    cp "$REPO_DIR/deploy/mcp.toml" "$MCP_TOML"
    ok "mcp.toml (from deploy/)"
  fi
fi

# Heartbeat checklist
if [[ -f "$REPO_DIR/workspace/HEARTBEAT.md" ]]; then
  cp "$REPO_DIR/workspace/HEARTBEAT.md" "$INSTALL_DIR/workspace/HEARTBEAT.md"
  ok "HEARTBEAT.md"
fi

# Backup and restore scripts
for script in backup.sh restore.sh; do
  if [[ -f "$REPO_DIR/workspace/$script" ]]; then
    cp "$REPO_DIR/workspace/$script" "$INSTALL_DIR/workspace/$script"
    chmod +x "$INSTALL_DIR/workspace/$script"
  fi
done
ok "backup.sh + restore.sh"

# Skills — symlink so edits in repo take effect live
for skill in devops-core incident-response deployment self-management; do
  if [[ -f "$REPO_DIR/skills/$skill.md" && ! -f "$INSTALL_DIR/skills/$skill.md" ]]; then
    cp "$REPO_DIR/skills/$skill.md" "$INSTALL_DIR/skills/$skill.md"
  fi
done
if [[ ! -L "$INSTALL_DIR/skills/repo-skills" ]]; then
  ln -s "$REPO_DIR/skills" "$INSTALL_DIR/skills/repo-skills" 2>/dev/null || true
fi
ok "Skills installed (live symlink)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — .env
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 5 — Setting up .env"

ENV_FILE="$INSTALL_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — not overwriting your secrets"
else
  if [[ -f "$REPO_DIR/.env.example" ]]; then
    cp "$REPO_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Created $ENV_FILE from .env.example"
    warn "You MUST edit $ENV_FILE and set:"
    warn "  TELEGRAM_BOT_TOKEN=your-token-here"
    warn "  OPENROUTER_API_KEY=sk-or-v1-your-key-here"
    warn "  OWNER_CHAT_ID=your-chat-id"
  fi
fi

# OpenCode config
OPENCODE_CONFIG_DIR="/root/.config/opencode"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
mkdir -p "$OPENCODE_CONFIG_DIR"

if [[ -f "$OPENCODE_CONFIG" ]]; then
  warn "opencode config already exists — skipping"
else
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
  fi
  OPENCODE_MODEL_VAL="${OPENCODE_MODEL:-deepseek/deepseek-r1-0528}"

  cat > "$OPENCODE_CONFIG" << OEOF
{
  "provider": "openrouter",
  "model": "$OPENCODE_MODEL_VAL",
  "autoshare": false,
  "disabled_providers": []
}
OEOF
  chmod 600 "$OPENCODE_CONFIG"
  ok "opencode config created (model: $OPENCODE_MODEL_VAL)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — SSH key
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 6 — SSH key for remote access"

SSH_KEY="/root/.ssh/batabeto"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -f "$SSH_KEY" ]]; then
  warn "SSH key already exists — skipping generation"
else
  ssh-keygen -t ed25519 -C "batabeto-agent" -f "$SSH_KEY" -N ""
  ok "SSH key generated: $SSH_KEY"
fi

ok "Public key:"
echo ""
echo -e "${YELLOW}$(cat ${SSH_KEY}.pub)${RESET}"
echo ""

# SSH config
SSH_CONFIG="/root/.ssh/config"
BATABETO_CONFIG_MARKER="# batabeto-managed"

if grep -q "$BATABETO_CONFIG_MARKER" "$SSH_CONFIG" 2>/dev/null; then
  warn "SSH config already has batabeto block — skipping"
else
  cat >> "$SSH_CONFIG" << 'SSHEOF'

# batabeto-managed — remote server SSH defaults
Host *
    IdentityFile /root/.ssh/batabeto
    ConnectTimeout 5
    StrictHostKeyChecking no
    ServerAliveInterval 30
    ServerAliveCountMax 3
SSHEOF
  chmod 600 "$SSH_CONFIG"
  ok "SSH config updated"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — GitHub backup restore
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 7 — Restoring from GitHub backup (if configured)"

if [[ -f "$INSTALL_DIR/.env" ]]; then
  set -a; source "$INSTALL_DIR/.env" 2>/dev/null || true; set +a
fi

if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_USERNAME:-}" ]]; then
  info "GitHub credentials found — checking for backup..."
  bash "$INSTALL_DIR/workspace/restore.sh" && ok "Restore complete" || warn "No backup found — starting fresh"
else
  warn "GITHUB_TOKEN/GITHUB_USERNAME not set — skipping restore"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — Systemd service
# ═════════════════════════════════════════════════════════════════════════════
header "STEP 8 — Installing systemd service"

SERVICE_FILE="/etc/systemd/system/skyclaw.service"

if [[ -f "$REPO_DIR/deploy/skyclaw.service" ]]; then
  cp "$REPO_DIR/deploy/skyclaw.service" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable skyclaw
  ok "Service installed and enabled"
else
  warn "deploy/skyclaw.service not found — skipping"
fi

# ═════════════════════════════════════════════════════════════════════════════
# DONE
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                   SETUP COMPLETE                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${BOLD}NEXT STEPS:${RESET}"
echo ""
echo -e "  ${YELLOW}1.${RESET} Edit your secrets:"
echo -e "     ${BLUE}nano $INSTALL_DIR/.env${RESET}"
echo -e "     Required: TELEGRAM_BOT_TOKEN and OPENROUTER_API_KEY"
echo ""

if [[ "$WITH_BUILD" == "true" ]]; then
  echo -e "  ${YELLOW}2.${RESET} Start batabeto:"
  echo -e "     ${BLUE}sudo bash start.sh${RESET}"
  echo ""
  echo -e "  ${YELLOW}3.${RESET} After code changes, update with:"
  echo -e "     ${BLUE}sudo bash server-update.sh${RESET}"
else
  echo -e "  ${YELLOW}2.${RESET} From your local PC, build and push the binary:"
  echo -e "     ${BLUE}bash deploy.sh <this-server-ip-or-alias>${RESET}"
  echo ""
  echo -e "  ${YELLOW}3.${RESET} Then start batabeto:"
  echo -e "     ${BLUE}sudo bash start.sh${RESET}"
fi
echo ""

echo -e "${BOLD}USEFUL COMMANDS:${RESET}"
echo -e "  systemctl status skyclaw       — check if running"
echo -e "  systemctl restart skyclaw      — restart after config changes"
echo -e "  journalctl -fu skyclaw         — follow live logs"
echo -e "  systemctl stop skyclaw         — stop the agent"
echo ""
echo -e "${GREEN}${BOLD}Server is ready.${RESET}"
echo ""
