#!/usr/bin/env bash
# batabeto self-backup — pushes to GitHub private repo every 15 min
# Called by heartbeat automatically. Run manually: bash ~/.skyclaw/workspace/backup.sh
set -euo pipefail

INSTALL_DIR="${HOME}/.skyclaw"
BACKUP_DIR="${INSTALL_DIR}/backup-repo"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
GITHUB_BACKUP_REPO="${GITHUB_BACKUP_REPO:-batabeto-backup}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname)

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$GITHUB_TOKEN" || -z "$GITHUB_USERNAME" ]]; then
  echo "ERROR: GITHUB_TOKEN and GITHUB_USERNAME must be set in ~/.skyclaw/.env"
  exit 1
fi

REPO_URL="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_BACKUP_REPO}.git"

# ── Clone or pull backup repo ─────────────────────────────────────────────────
if [[ ! -d "$BACKUP_DIR/.git" ]]; then
  # First time: try to clone, or init fresh if repo is empty
  rm -rf "$BACKUP_DIR"
  if git clone "$REPO_URL" "$BACKUP_DIR" 2>/dev/null; then
    echo "Cloned existing backup repo"
  else
    mkdir -p "$BACKUP_DIR"
    cd "$BACKUP_DIR"
    git init
    git remote add origin "$REPO_URL"
    echo "# batabeto backup" > README.md
    git add README.md
    git commit -m "init"
    git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || true
    echo "Initialized new backup repo"
  fi
else
  cd "$BACKUP_DIR"
  git pull --rebase origin main 2>/dev/null || git pull --rebase origin master 2>/dev/null || true
fi

cd "$BACKUP_DIR"

# ── Copy everything important ─────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR/data"

# Memory database
[[ -f "${INSTALL_DIR}/memory.db" ]] && \
  cp "${INSTALL_DIR}/memory.db" "$BACKUP_DIR/data/memory.db"

# Vault (encrypted — safe to push)
[[ -d "${INSTALL_DIR}/vault" ]] && \
  cp -r "${INSTALL_DIR}/vault" "$BACKUP_DIR/data/vault"

# Skills
[[ -d "${INSTALL_DIR}/skills" ]] && \
  cp -r "${INSTALL_DIR}/skills" "$BACKUP_DIR/data/skills"

# Config
[[ -f "${INSTALL_DIR}/skyclaw.toml" ]] && \
  cp "${INSTALL_DIR}/skyclaw.toml" "$BACKUP_DIR/data/skyclaw.toml"

# Allowlist (who is authorized)
[[ -f "${INSTALL_DIR}/allowlist.toml" ]] && \
  cp "${INSTALL_DIR}/allowlist.toml" "$BACKUP_DIR/data/allowlist.toml"

# Heartbeat and workspace files
[[ -d "${INSTALL_DIR}/workspace" ]] && \
  rsync -a --exclude="backup.sh" --exclude="restore.sh" \
    "${INSTALL_DIR}/workspace/" "$BACKUP_DIR/data/workspace/"

# Write metadata
cat > "$BACKUP_DIR/data/meta.json" << METAEOF
{
  "timestamp": "${TIMESTAMP}",
  "hostname": "${HOSTNAME}",
  "backup_version": "1"
}
METAEOF

# ── Commit and push ───────────────────────────────────────────────────────────
git config user.email "batabeto@backup" 2>/dev/null || true
git config user.name "batabeto" 2>/dev/null || true

git add -A

# Only commit if there are actual changes
if git diff --cached --quiet; then
  echo "No changes since last backup — skipping commit"
  exit 0
fi

git commit -m "backup: ${TIMESTAMP} from ${HOSTNAME}"

# Push with retry
for attempt in 1 2 3; do
  if git push origin HEAD:main 2>/dev/null || git push origin HEAD:master 2>/dev/null; then
    echo "✅ Backup pushed to GitHub at ${TIMESTAMP}"
    exit 0
  fi
  echo "Push attempt ${attempt} failed, retrying..."
  sleep 5
done

echo "ERROR: Failed to push backup after 3 attempts"
exit 1
