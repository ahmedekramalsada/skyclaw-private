---
name: self-management
description: How batabeto creates skills, installs MCP servers, manages backups, and maintains itself
capabilities: [skills, mcp, backup, restore, self-update, self-management]
---

# Self-Management Skill

## CREATING SKILLS

When to create a new skill:
- Owner says "save this as a skill" or "remember how to do this"
- You solved a complex problem and the steps should be reusable
- You learned something specific about the owner's infrastructure
- You found an effective pattern for a recurring task

Skill file format:
```markdown
---
name: <kebab-case-name>
description: <one line — what this skill is for>
capabilities: [tag1, tag2, tag3]
---

# <Skill Title>

## OVERVIEW
<brief description>

## STEPS / COMMANDS
<the actual content — commands, patterns, notes>

## NOTES
<anything specific to this environment>
```

Create it:
```bash
cat > ~/.skyclaw/skills/<name>.md << 'EOF'
<content>
EOF
```

Confirm to owner: "📚 Created skill: <name> — <what it does>"

---

## INSTALLING MCP SERVERS

MCP servers give batabeto new capabilities — GitHub API, database access, browser automation, etc.

### Install via skyclaw CLI
```bash
skyclaw mcp add <name> <command> [args...]

# Examples:
skyclaw mcp add github npx -y @modelcontextprotocol/server-github
skyclaw mcp add postgres npx -y @modelcontextprotocol/server-postgres
skyclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /
skyclaw mcp add brave-search npx -y @modelcontextprotocol/server-brave-search
skyclaw mcp add memory npx -y @modelcontextprotocol/server-memory
```

### Check installed MCP servers
```bash
skyclaw mcp list
```

### Remove an MCP server
```bash
skyclaw mcp remove <name>
```

### Suggest MCP to owner
When a task would benefit from an MCP you do not have:
- Name the MCP and what it enables
- Use inline buttons: BUTTONS: Install <name> MCP | Skip | ✏️ Other
- If approved: install, verify it responds, then continue the task

### Verify MCP installed correctly
After installing, test it by using one of its tools immediately.
If it fails, check: node/npx installed, internet access, token set for auth-required MCPs.

---

## BACKUP

### Run backup now
```bash
bash ~/.skyclaw/workspace/backup.sh
```

### What gets backed up
- `~/.skyclaw/memory.db` — full conversation and task memory
- `~/.skyclaw/vault/` — encrypted secrets (safe to push — encrypted at rest)
- `~/.skyclaw/skills/` — all skill files including ones you created
- `~/.skyclaw/skyclaw.toml` — runtime config
- `~/.skyclaw/allowlist.toml` — who is authorized (owner stays owner)
- `~/.skyclaw/workspace/` — HEARTBEAT.md and other workspace files

### Backup destination
GitHub private repo: `$GITHUB_USERNAME/$GITHUB_BACKUP_REPO`
Push happens every 15 minutes via heartbeat.

### Check last backup time
```bash
cd ~/.skyclaw/backup-repo && git log --oneline -3
```

### Force backup and confirm
```bash
bash ~/.skyclaw/workspace/backup.sh && echo "Backup successful"
```

---

## RESTORE ON NEW SERVER

When installed fresh on a new server, ALWAYS restore first:

```bash
# 1. Make sure .env has GITHUB_TOKEN, GITHUB_USERNAME, GITHUB_BACKUP_REPO
source ~/.skyclaw/.env

# 2. Run restore
bash ~/.skyclaw/workspace/restore.sh

# 3. Restart to pick up restored memory and vault
sudo systemctl restart skyclaw
```

What restore does:
- Pulls latest backup from GitHub
- Restores memory DB (full conversation history)
- Restores vault (all your stored secrets)
- Restores all skills (including ones you created yourself)
- Restores allowlist (you remain the owner)
- Does NOT overwrite .env (your new server's tokens stay)

---

## SELF-UPDATE

When owner says "update yourself", "pull latest", or "upgrade batabeto":

```bash
# Find the repo dir
REPO=$(find /root /home /opt -name "Cargo.toml" -path "*/skyclaw*" 2>/dev/null | head -1 | xargs dirname)

cd $REPO

# Pull latest
git pull origin main

# Build
cargo build --release

# Install
sudo cp target/release/skyclaw /usr/local/bin/skyclaw

# Restart
sudo systemctl restart skyclaw

echo "Updated and restarted"
```

Note: After restart, batabeto will reload from the updated binary.
The Telegram conversation will resume normally — memory is in SQLite, not in the binary.

---

## SELF-DIAGNOSTICS

When something is wrong with batabeto itself:

```bash
# Is the service running?
systemctl status skyclaw

# Recent logs
journalctl -u skyclaw --since "10 minutes ago" --no-pager | tail -30

# Memory DB health
sqlite3 ~/.skyclaw/memory.db "PRAGMA integrity_check; SELECT count(*) FROM memories;" 2>/dev/null

# Vault accessible?
ls -la ~/.skyclaw/vault/

# Skills loaded?
ls ~/.skyclaw/skills/

# Config valid?
cat ~/.skyclaw/skyclaw.toml
```
