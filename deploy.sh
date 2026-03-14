#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Build Locally + Push to Server
# Usage: bash deploy.sh <target> [flags]
#
# <target>   IP address (e.g. 1.2.3.4) or SSH alias (e.g. x)
#
# Flags:
#   -c          Also sync skyclaw.toml config to server
#   -e          Also sync .env file to server
#   --no-build  Skip local build, push existing binary
#
# Examples:
#   bash deploy.sh x              Build + push binary
#   bash deploy.sh x -c           Build + push binary + sync config
#   bash deploy.sh x --no-build   Push existing binary (no build)
#   bash deploy.sh 1.2.3.4 -c -e  Build + push + sync config + sync .env
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET="${1:-}"
SYNC_CONFIG=false
SYNC_ENV=false
DO_BUILD=true

# ── Parse flags ──────────────────────────────────────────────────────────────
shift || true
for arg in "$@"; do
  case "$arg" in
    -c)         SYNC_CONFIG=true ;;
    -e)         SYNC_ENV=true ;;
    --no-build) DO_BUILD=false ;;
    *)          echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo -e "Usage: bash deploy.sh <target> [flags]"
  echo ""
  echo "  Flags:"
  echo "    -c          Sync skyclaw.toml to server"
  echo "    -e          Sync .env to server"
  echo "    --no-build  Skip local build, push existing binary"
  echo ""
  echo "  Examples:"
  echo "    bash deploy.sh x"
  echo "    bash deploy.sh x -c"
  echo "    bash deploy.sh x --no-build"
  echo "    bash deploy.sh 1.2.3.4 -c -e"
  exit 1
fi

# ── Resolve SSH target ───────────────────────────────────────────────────────
REMOTE_DEST="$TARGET"
if [[ "$TARGET" != *"@"* ]] && [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  REMOTE_DEST="root@$TARGET"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="skyclaw"
LOCAL_BINARY="$REPO_DIR/target/release/$BINARY_NAME"
REMOTE_PATH="/usr/local/bin/$BINARY_NAME"
REMOTE_CONFIG_DIR="/root/.skyclaw"

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
echo -e "${BOLD}║       batabeto — Deploy to Server        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Build locally (unless --no-build) ────────────────────────────────
if [[ "$DO_BUILD" == "true" ]]; then
  info "Building $BINARY_NAME locally in release mode..."

  # Source cargo env — handle both normal and sudo cases
  source "$HOME/.cargo/env" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(eval echo "~$SUDO_USER")
    source "$REAL_HOME/.cargo/env" 2>/dev/null || true
  fi

  cd "$REPO_DIR"
  cargo build --release

  if [[ ! -f "$LOCAL_BINARY" ]]; then
    err "Build failed — binary not found at $LOCAL_BINARY"
  fi
  ok "Local build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"
else
  info "Skipping build (--no-build)"
  if [[ ! -f "$LOCAL_BINARY" ]]; then
    err "No binary found at $LOCAL_BINARY — run 'bash build.sh' first or remove --no-build"
  fi
  ok "Using existing binary: $(du -sh "$LOCAL_BINARY" | cut -f1)"
fi

# ── Step 2: Stop remote service ──────────────────────────────────────────────
info "Stopping skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl stop skyclaw 2>/dev/null" || true
ok "Service stopped"

# ── Step 3: Upload binary ────────────────────────────────────────────────────
info "Uploading binary to $REMOTE_DEST..."
scp "$LOCAL_BINARY" "$REMOTE_DEST:/tmp/$BINARY_NAME"
ok "Binary uploaded"

info "Installing binary to $REMOTE_PATH..."
ssh "$REMOTE_DEST" "sudo mv /tmp/$BINARY_NAME $REMOTE_PATH && sudo chown root:root $REMOTE_PATH && sudo chmod 755 $REMOTE_PATH"
ok "Binary installed"

# ── Step 4: Sync config files (optional) ─────────────────────────────────────
if [[ "$SYNC_CONFIG" == "true" ]]; then
  info "Syncing skyclaw.toml to $REMOTE_DEST..."
  scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml $REMOTE_CONFIG_DIR/skyclaw.toml && sudo chown root:root $REMOTE_CONFIG_DIR/skyclaw.toml"
  ok "Config synced"
fi

if [[ "$SYNC_ENV" == "true" ]]; then
  if [[ -f "$REPO_DIR/.env" ]]; then
    info "Syncing .env to $REMOTE_DEST..."
    scp "$REPO_DIR/.env" "$REMOTE_DEST:/tmp/.env"
    ssh "$REMOTE_DEST" "sudo mv /tmp/.env $REMOTE_CONFIG_DIR/.env && sudo chown root:root $REMOTE_CONFIG_DIR/.env && sudo chmod 600 $REMOTE_CONFIG_DIR/.env"
    ok ".env synced"
  else
    warn "No .env file found locally — skipping"
  fi
fi

# ── Step 5: Start service ────────────────────────────────────────────────────
info "Starting skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl start skyclaw"
ok "skyclaw is live on $REMOTE_DEST"

echo ""
echo -e "${GREEN}${BOLD}Deploy complete.${RESET}"
echo ""
echo -e "  Watch logs: ${BLUE}ssh $REMOTE_DEST 'sudo journalctl -fu skyclaw'${RESET}"
echo -e "  Status:     ${BLUE}ssh $REMOTE_DEST 'sudo systemctl status skyclaw'${RESET}"
echo ""
