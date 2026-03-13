#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# batabeto — Push Binary to Server
# Usage: bash push.sh <target> [-c]
#
# <target> can be an IP address (e.g. 1.2.3.4) or an SSH alias (e.g. x).
# Use -c to also push the skyclaw.toml configuration file.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET="${1:-}"
SYNC_CONFIG=false

# Simple flag detection
if [[ "${2:-}" == "-c" ]]; then
  SYNC_CONFIG=true
fi

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
cargo build --release

if [[ ! -f "$LOCAL_BINARY" ]]; then
  echo -e "Error: Local binary not found at $LOCAL_BINARY"
  exit 1
fi
ok "Local build complete: $(du -sh "$LOCAL_BINARY" | cut -f1)"

# ── Step 2: Stop Service & Upload ────────────────────────────────────────────
info "Stopping skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl stop skyclaw" || true

info "Uploading binary to $REMOTE_DEST:$(env -S "echo /tmp/$BINARY_NAME")..."
scp "$LOCAL_BINARY" "$REMOTE_DEST:/tmp/$BINARY_NAME"
ok "Staging complete"

# ── Step 3: Deployment & Restart ─────────────────────────────────────────────
info "Moving binary to $REMOTE_PATH and fixing permissions..."
ssh "$REMOTE_DEST" "sudo mv /tmp/$BINARY_NAME $REMOTE_PATH && sudo chown root:root $REMOTE_PATH && sudo chmod +x $REMOTE_PATH"

if [[ "$SYNC_CONFIG" == "true" ]]; then
  info "Syncing skyclaw.toml to $REMOTE_DEST..."
  scp "$REPO_DIR/skyclaw.toml" "$REMOTE_DEST:/tmp/skyclaw.toml"
  ssh "$REMOTE_DEST" "sudo mv /tmp/skyclaw.toml /root/.skyclaw/skyclaw.toml && sudo chown root:root /root/.skyclaw/skyclaw.toml"
  ok "Config synced"
fi

info "Starting skyclaw on $REMOTE_DEST..."
ssh "$REMOTE_DEST" "sudo systemctl start skyclaw"
ok "skyclaw is live on $REMOTE_DEST. Watch logs: ssh $REMOTE_DEST 'sudo journalctl -fu skyclaw'"
