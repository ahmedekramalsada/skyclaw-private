#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — One-Command Install Script
# Usage: sudo bash install.sh
#
# What this does:
#   1. Checks dependencies (Rust, cargo)
#   2. Builds the release binary
#   3. Installs binary to /usr/local/bin/skyclaw
#   4. Creates all required directories under /root/.skyclaw/
#   5. Copies config, workspace, and skills files
#   6. Creates .env from .env.example if it doesn't exist
#   7. Generates a dedicated SSH key for remote server access
#   8. Installs and enables the systemd service
#   9. Prints next steps
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

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

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash install.sh"
fi

# ── Detect repo root ─────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/root/.skyclaw"
BINARY_PATH="/usr/local/bin/skyclaw"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       batabeto — DevOps AI Agent         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 1 — Checking dependencies"
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v cargo &>/dev/null; then
  warn "Rust/cargo not found. Installing via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  source "$HOME/.cargo/env"
  ok "Rust installed"
else
  RUST_VERSION=$(rustc --version)
  ok "Rust found: $RUST_VERSION"
fi

if ! command -v git &>/dev/null; then
  err "git is required. Install with: apt install git"
fi
ok "git found"

# ── Node.js + npx (required for MCP servers) ─────────────────────────────────
if ! command -v node &>/dev/null; then
  warn "Node.js not found. Installing via NodeSource (LTS)..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y nodejs >/dev/null 2>&1
  ok "Node.js installed: $(node --version)"
else
  ok "Node.js found: $(node --version)"
fi

if ! command -v npx &>/dev/null; then
  err "npx not found after Node.js install — try: apt install nodejs"
fi
ok "npx found"

# ── OpenCode — AI coding agent (used as MCP by batabeto) ─────────────────────
if ! command -v opencode &>/dev/null; then
  info "Installing opencode-ai (coding agent for MCP delegation)..."
  npm install -g opencode-ai --silent
  ok "opencode installed"
else
  CURRENT_VER=$(opencode --version 2>/dev/null || echo "unknown")
  ok "opencode found: $CURRENT_VER"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 2 — Building release binary"
# ─────────────────────────────────────────────────────────────────────────────

# ── Build one crate at a time (-j1) ─────────────────────────────────────────
# -j1 means one compilation job at a time — crates compile sequentially.
# This is intentional: parallel Rust builds on small servers cause OOM kills
# and mysterious hangs. Sequential is slower but always finishes.

# Check for linker
if ! command -v cc &>/dev/null; then
  warn "cc (linker) not found in PATH. Checking common locations..."
  export PATH="$PATH:/usr/bin:/usr/local/bin"
  if ! command -v cc &>/dev/null; then
    warn "linker 'cc' not found. Installing build-essential..."
    apt-get update && apt-get install -y build-essential
    if ! command -v cc &>/dev/null; then
      err "linker 'cc' still not found after installing build-essential."
    fi
  fi
fi

info "Building skyclaw in release mode (-j1, one crate at a time)..."
info "This takes 20–40 min on a fresh server (incremental builds are much faster)."
echo ""

cd "$REPO_DIR"

# Ensure we don't use a stale binary if build fails
rm -f target/release/skyclaw

# Stream progress — use pipefail to ensure cargo failure is detected
set -o pipefail
cargo build --release -j1 2>&1 | grep -E "^error|^warning|Compiling |Finished " || true

if [[ ! -f "$REPO_DIR/target/release/skyclaw" ]]; then
  err "Build failed — binary not found at target/release/skyclaw"
fi
ok "Build complete: $(du -sh $REPO_DIR/target/release/skyclaw | cut -f1) binary"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 3 — Installing binary"
# ─────────────────────────────────────────────────────────────────────────────

cp "$REPO_DIR/target/release/skyclaw" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
ok "Binary installed at $BINARY_PATH"
ok "Version: $($BINARY_PATH --version 2>/dev/null || echo 'ok')"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 4 — Creating directories"
# ─────────────────────────────────────────────────────────────────────────────

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
  ok "Created $dir"
done

chmod 700 "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR/vault"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 5 — Copying config files"
# ─────────────────────────────────────────────────────────────────────────────

# Main config
cp "$REPO_DIR/skyclaw.toml" "$INSTALL_DIR/skyclaw.toml"
ok "Copied skyclaw.toml → $INSTALL_DIR/skyclaw.toml"

# MCP servers config — only copy if not already customised
MCP_TOML="$INSTALL_DIR/mcp.toml"
if [[ -f "$MCP_TOML" ]]; then
  warn "mcp.toml already exists — skipping (keeping your customised MCP list)"
else
  cp "$REPO_DIR/deploy/mcp.toml" "$MCP_TOML"
  ok "Copied mcp.toml → $MCP_TOML (5 MCP servers pre-configured)"
fi

# Heartbeat checklist
cp "$REPO_DIR/workspace/HEARTBEAT.md" "$INSTALL_DIR/workspace/HEARTBEAT.md"
ok "Copied HEARTBEAT.md → $INSTALL_DIR/workspace/HEARTBEAT.md"

# Backup and restore scripts
cp "$REPO_DIR/workspace/backup.sh" "$INSTALL_DIR/workspace/backup.sh"
cp "$REPO_DIR/workspace/restore.sh" "$INSTALL_DIR/workspace/restore.sh"
chmod +x "$INSTALL_DIR/workspace/backup.sh"
chmod +x "$INSTALL_DIR/workspace/restore.sh"
ok "Copied backup.sh + restore.sh → $INSTALL_DIR/workspace/"

# Skills — symlink repo skills/ into ~/.skyclaw/skills/ so edits take effect live without reinstall
# First copy any skills that don't exist yet (in case this is a fresh install)
for skill in devops-core incident-response deployment self-management; do
  if [[ -f "$REPO_DIR/skills/$skill.md" && ! -f "$INSTALL_DIR/skills/$skill.md" ]]; then
    cp "$REPO_DIR/skills/$skill.md" "$INSTALL_DIR/skills/$skill.md"
    ok "Copied skills/$skill.md"
  fi
done
# Create a symlink from ~/.skyclaw/skills/repo-skills -> repo/skills so any new files added
# to the repo skills dir are visible to the agent immediately
if [[ ! -L "$INSTALL_DIR/skills/repo-skills" ]]; then
  ln -s "$REPO_DIR/skills" "$INSTALL_DIR/skills/repo-skills" 2>/dev/null || true
fi
ok "Skills installed → $INSTALL_DIR/skills/ (edits in $REPO_DIR/skills/ take effect live)"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 6 — Setting up .env"
# ─────────────────────────────────────────────────────────────────────────────

ENV_FILE="$INSTALL_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — skipping (not overwriting your secrets)"
else
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Created $ENV_FILE from .env.example"
  warn "You MUST edit $ENV_FILE and set:"
  warn "  TELEGRAM_BOT_TOKEN=your-token-here"
  warn "  OPENROUTER_API_KEY=sk-or-v1-your-key-here"
  warn "  OWNER_CHAT_ID=your-chat-id   (message @userinfobot on Telegram to get it)"
fi

# ── OpenCode config — point it at OpenRouter ─────────────────────────────────
OPENCODE_CONFIG_DIR="/root/.config/opencode"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"

mkdir -p "$OPENCODE_CONFIG_DIR"

if [[ -f "$OPENCODE_CONFIG" ]]; then
  warn "opencode config already exists — skipping"
else
  # Load env to read OPENCODE_MODEL if already set
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
  ok "Created opencode config → $OPENCODE_CONFIG (model: $OPENCODE_MODEL_VAL)"
  info "Change the model anytime: edit OPENCODE_MODEL in $ENV_FILE and re-run install.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 7 — SSH key for remote server access"
# ─────────────────────────────────────────────────────────────────────────────

SSH_KEY="/root/.ssh/batabeto"

if [[ -f "$SSH_KEY" ]]; then
  warn "SSH key already exists at $SSH_KEY — skipping generation"
else
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  ssh-keygen -t ed25519 -C "batabeto-agent" -f "$SSH_KEY" -N ""
  ok "SSH key generated: $SSH_KEY"
fi

ok "Public key (copy this to your remote servers):"
echo ""
echo -e "${YELLOW}$(cat ${SSH_KEY}.pub)${RESET}"
echo ""
info "To authorize on a remote server:"
info "  ssh-copy-id -i $SSH_KEY.pub root@<server-ip>"
info "  OR manually: cat $SSH_KEY.pub >> ~/.ssh/authorized_keys (on remote)"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 8 — SSH config for batabeto connections"
# ─────────────────────────────────────────────────────────────────────────────

SSH_CONFIG="/root/.ssh/config"
BATABETO_CONFIG_MARKER="# batabeto-managed"

if grep -q "$BATABETO_CONFIG_MARKER" "$SSH_CONFIG" 2>/dev/null; then
  warn "SSH config already has batabeto block — skipping"
else
  cat >> "$SSH_CONFIG" << 'SSHEOF'

# batabeto-managed — remote server SSH defaults
# Add your servers below using this pattern:
#
# Host server1
#     HostName 10.0.0.5
#     User root
#     IdentityFile /root/.ssh/batabeto
#     StrictHostKeyChecking no
#     ConnectTimeout 5
#
# Host server2
#     HostName 10.0.0.6
#     User root
#     IdentityFile /root/.ssh/batabeto
#     StrictHostKeyChecking no
#     ConnectTimeout 5

# Default for all hosts — use batabeto key, fast timeout
Host *
    IdentityFile /root/.ssh/batabeto
    ConnectTimeout 5
    StrictHostKeyChecking no
    ServerAliveInterval 30
    ServerAliveCountMax 3
SSHEOF
  chmod 600 "$SSH_CONFIG"
  ok "SSH config updated at $SSH_CONFIG"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 9 — Restoring from GitHub backup (if configured)"
# ─────────────────────────────────────────────────────────────────────────────
# This runs BEFORE the service is enabled so any restored memory/vault/skills
# are in place before batabeto first starts.

if [[ -f "$INSTALL_DIR/.env" ]]; then
  set -a
  source "$INSTALL_DIR/.env" 2>/dev/null || true
  set +a
fi

if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_USERNAME:-}" ]]; then
  info "GitHub credentials found — checking for backup..."
  bash "$INSTALL_DIR/workspace/restore.sh" && ok "Restore complete" || warn "No backup found or restore skipped — starting fresh"
else
  warn "GITHUB_TOKEN or GITHUB_USERNAME not set in .env — skipping restore"
  warn "Set them later and run: bash ~/.skyclaw/workspace/restore.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 10 — Installing systemd service"
# ─────────────────────────────────────────────────────────────────────────────

SERVICE_FILE="/etc/systemd/system/skyclaw.service"

cp "$REPO_DIR/deploy/skyclaw.service" "$SERVICE_FILE"
ok "Copied service file to $SERVICE_FILE"

systemctl daemon-reload
ok "systemctl daemon-reload done"

systemctl enable skyclaw
ok "skyclaw service enabled (will start on boot)"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 11 — Verifying installation"
# ─────────────────────────────────────────────────────────────────────────────

ok "Binary:       $BINARY_PATH"
ok "Config:       $INSTALL_DIR/skyclaw.toml"
ok "Env file:     $INSTALL_DIR/.env"
ok "Heartbeat:    $INSTALL_DIR/workspace/HEARTBEAT.md"
ok "Skills:       $(ls $INSTALL_DIR/skills/*.md 2>/dev/null | wc -l) files"
ok "SSH key:      $SSH_KEY"
ok "Service:      $SERVICE_FILE"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                   INSTALLATION COMPLETE                     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}NEXT STEPS:${RESET}"
echo ""
echo -e "  ${YELLOW}1.${RESET} Edit your secrets:"
echo -e "     ${BLUE}nano $INSTALL_DIR/.env${RESET}"
echo -e "     Required: TELEGRAM_BOT_TOKEN and OPENROUTER_API_KEY"
echo -e "     For GitHub MCP: set GITHUB_PERSONAL_ACCESS_TOKEN (same value as GITHUB_TOKEN)"
echo -e "     For a different OpenCode model: set OPENCODE_MODEL (default: deepseek/deepseek-r1-0528)"
echo ""
echo -e "  ${YELLOW}2.${RESET} Start batabeto:"
echo -e "     ${BLUE}systemctl start skyclaw${RESET}"
echo ""
echo -e "  ${YELLOW}3.${RESET} Watch the logs:"
echo -e "     ${BLUE}journalctl -fu skyclaw${RESET}"
echo ""
echo -e "  ${YELLOW}4.${RESET} Open Telegram and message your bot"
echo -e "     First message triggers auto-whitelist (you become the owner)"
echo -e "     Then paste your OpenRouter key when prompted"
echo ""
echo -e "  ${YELLOW}5.${RESET} Tell batabeto about your servers:"
echo -e "     ${BLUE}Remember: server1 is at 10.0.0.5, user root, runs Nginx${RESET}"
echo -e "     ${BLUE}Remember: my K3s kubeconfig is at /etc/rancher/k3s/k3s.yaml${RESET}"
echo -e "     ${BLUE}Remember: my Ansible inventory is at /opt/ansible/inventory.yml${RESET}"
echo ""
echo -e "  ${YELLOW}6.${RESET} Authorize batabeto SSH key on remote servers:"
echo -e "     ${BLUE}ssh-copy-id -i /root/.ssh/batabeto.pub root@<server-ip>${RESET}"
echo ""
echo -e "  ${YELLOW}7.${RESET} Add your servers to SSH config:"
echo -e "     ${BLUE}nano /root/.ssh/config${RESET}"
echo -e "     Follow the template already added at the bottom"
echo ""
echo -e "${BOLD}USEFUL COMMANDS:${RESET}"
echo -e "  systemctl status skyclaw       — check if running"
echo -e "  systemctl restart skyclaw      — restart after config changes"
echo -e "  journalctl -fu skyclaw         — follow live logs"
echo -e "  systemctl stop skyclaw         — stop the agent"
echo ""
echo -e "${GREEN}${BOLD}batabeto is ready. Start it and open Telegram.${RESET}"
echo ""
