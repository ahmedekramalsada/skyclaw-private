#!/usr/bin/env bash
# batabeto self-restore — pulls latest backup from GitHub and restores
# Called automatically on fresh install. Run manually: bash ~/.skyclaw/workspace/restore.sh
set -euo pipefail

INSTALL_DIR="${HOME}/.skyclaw"
BACKUP_DIR="${INSTALL_DIR}/backup-repo"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
GITHUB_BACKUP_REPO="${GITHUB_BACKUP_REPO:-batabeto-backup}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$GITHUB_TOKEN" || -z "$GITHUB_USERNAME" ]]; then
  echo "GITHUB_TOKEN and GITHUB_USERNAME not set — skipping restore"
  exit 0
fi

REPO_URL="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_BACKUP_REPO}.git"

echo "→ Checking for backup at ${GITHUB_USERNAME}/${GITHUB_BACKUP_REPO}..."

# ── Clone backup repo ─────────────────────────────────────────────────────────
rm -rf "$BACKUP_DIR"
if ! git clone "$REPO_URL" "$BACKUP_DIR" 2>/dev/null; then
  echo "No backup found or repo does not exist yet — starting fresh"
  exit 0
fi

DATA_DIR="$BACKUP_DIR/data"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "Backup repo exists but has no data dir — starting fresh"
  exit 0
fi

# ── Show backup metadata ──────────────────────────────────────────────────────
if [[ -f "$DATA_DIR/meta.json" ]]; then
  echo "Found backup:"
  cat "$DATA_DIR/meta.json"
  echo ""
fi

# ── Restore files ─────────────────────────────────────────────────────────────
echo "→ Restoring memory database..."
[[ -f "$DATA_DIR/memory.db" ]] && \
  cp "$DATA_DIR/memory.db" "${INSTALL_DIR}/memory.db" && \
  echo "  ✓ memory.db restored"

echo "→ Restoring vault..."
[[ -d "$DATA_DIR/vault" ]] && \
  cp -r "$DATA_DIR/vault" "${INSTALL_DIR}/vault" && \
  echo "  ✓ vault restored"

echo "→ Restoring skills..."
[[ -d "$DATA_DIR/skills" ]] && \
  cp -r "$DATA_DIR/skills" "${INSTALL_DIR}/skills" && \
  echo "  ✓ skills restored"

echo "→ Restoring config..."
[[ -f "$DATA_DIR/skyclaw.toml" && ! -f "${INSTALL_DIR}/skyclaw.toml" ]] && \
  cp "$DATA_DIR/skyclaw.toml" "${INSTALL_DIR}/skyclaw.toml" && \
  echo "  ✓ skyclaw.toml restored"

echo "→ Restoring allowlist..."
[[ -f "$DATA_DIR/allowlist.toml" ]] && \
  cp "$DATA_DIR/allowlist.toml" "${INSTALL_DIR}/allowlist.toml" && \
  echo "  ✓ allowlist.toml restored (you are still the owner)"

echo "→ Restoring workspace files..."
[[ -d "$DATA_DIR/workspace" ]] && \
  rsync -a "$DATA_DIR/workspace/" "${INSTALL_DIR}/workspace/" && \
  echo "  ✓ workspace restored"

echo ""
echo "✅ Restore complete — batabeto has your full memory, skills, and history"
