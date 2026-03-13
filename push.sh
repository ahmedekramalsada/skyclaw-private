#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Push Binary to Server
# Usage: bash push.sh <server-ip>
#
# This script builds the binary locally and uploads it to the server.
# Use this to skip the long compilation time on the server itself.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SERVER_IP="${1:-}"

if [[ -z "$SERVER_IP" ]]; then
  echo -e "Usage: bash push.sh <server-ip>"
  echo -e "Example: bash push.sh 1.2.3.4"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="skyclaw"
LOCAL_BINARY="$REPO_DIR/target/release/$BINARY_NAME"
REMOTE_PATH="/usr/local/bin/$BINARY_NAME"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }

# ── Step 1: Build locally ────────────────────────────────────────────────────
info "Building $BINARY_NAME locally in release mode..."
cargo build --release -j1

if [[ ! -f "$LOCAL_BINARY" ]]; then
  echo -e "Error: Local binary not found at $LOCAL_BINARY"
  exit 1
fi
ok "Local build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"

# ── Step 2: Upload ───────────────────────────────────────────────────────────
info "Uploading binary to root@$SERVER_IP:$REMOTE_PATH..."
scp "$LOCAL_BINARY" "root@$SERVER_IP:$REMOTE_PATH"
ok "Upload complete"

# ── Step 3: Restart ──────────────────────────────────────────────────────────
info "Restarting $BINARY_NAME service on server..."
ssh "root@$SERVER_IP" "chmod +x $REMOTE_PATH && systemctl restart skyclaw"
ok "$BINARY_NAME is restarting on server. Watch logs with: ssh root@$SERVER_IP 'journalctl -fu skyclaw'"
