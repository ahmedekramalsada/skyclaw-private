#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Push Binary to Server
# Usage: bash push.sh <target>
#
# <target> can be an IP address (e.g. 1.2.3.4) or an SSH alias (e.g. x).
# This script builds the binary locally and uploads it to the server.
# Use this to skip the long compilation time on the server itself.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo -e "Usage: bash push.sh <target>"
  echo -e "Example: bash push.sh 1.2.3.4"
  echo -e "Example: bash push.sh x"
  exit 1
fi

REMOTE_DEST="$TARGET"
# If no user is specified (no @), default to root@ for deployment
if [[ "$TARGET" != *"@"* ]]; then
  REMOTE_DEST="root@$TARGET"
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

# ── Step 2: Stop Service & Upload ────────────────────────────────────────────
info "Stopping skyclaw on $REMOTE_DEST to avoid 'text file busy'..."
ssh "$REMOTE_DEST" "systemctl stop skyclaw" || true

info "Uploading binary to $REMOTE_DEST:$REMOTE_PATH..."
scp "$LOCAL_BINARY" "$REMOTE_DEST:$REMOTE_PATH"
ok "Upload complete"

# ── Step 3: Restart ──────────────────────────────────────────────────────────
info "Restarting skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "chmod +x $REMOTE_PATH && systemctl start skyclaw"
ok "skyclaw is live on $REMOTE_DEST. Watch logs: ssh $REMOTE_DEST 'journalctl -fu skyclaw'"
