---
name: self-management
description: How batabeto creates and edits skills (with repo safety), installs MCPs, manages backups, and updates itself
capabilities: [skills, mcp, backup, restore, self-update, self-management, skill-editing]
---

# Self-Management Skill

## CREATING & EDITING SKILLS

### When to create a new skill
- X says "save this as a skill" or "remember how to do this"
- You solved a complex problem with reusable steps
- You learned a pattern specific to X's infrastructure
- A workflow is used repeatedly and deserves documentation

### Skill file format
```markdown
---
name: <kebab-case-name>
description: <one line — what this skill is for>
capabilities: [tag1, tag2, tag3]
---

# Skill Title

## OVERVIEW
<brief description>

## STEPS / COMMANDS
<actual content — commands, patterns, notes>

## NOTES
<anything specific to X's environment>
```

---

### SKILL SAVE FLOW — always follow this exactly

**Step 1: Write to server (immediate)**
```bash
cat > ~/.skyclaw/skills/<name>.md << 'SKILL'
<content>
SKILL
```

**Step 2: Verify it loaded correctly**
```bash
# Check file exists and is readable
cat ~/.skyclaw/skills/<name>.md | head -5
echo "Skill size: $(wc -c < ~/.skyclaw/skills/<name>.md) bytes"
```

**Step 3: Ask X — save to repo or server only?**

Always ask before touching the repo:
```
📚 Skill saved to server: <name>

Save to the repo too? (survives fresh deploys and works for other users)
BUTTONS: ✅ Save to repo | 🖥 Server only
```

**Step 4: If X says "Save to repo"**

```bash
# Copy to repo skills folder
cp ~/.skyclaw/skills/<name>.md /root/skyclaw-private/skills/<name>.md

# Verify the copy
diff ~/.skyclaw/skills/<name>.md /root/skyclaw-private/skills/<name>.md && echo "Files match"

# Add to deploy.sh skills list (if not already there)
python3 -c "
import re,sys
skill='<n>'
with open('/root/skyclaw-private/deploy.sh') as f: d=f.read()
if skill in d: print(skill+' already listed'); sys.exit(0)
d2=re.sub(r'(for skill in )([^;]+)(;)',lambda m:m.group(1)+m.group(2).rstrip()+' '+skill+m.group(3),d)
with open('/root/skyclaw-private/deploy.sh','w') as f: f.write(d2)
print('Added '+skill+' to deploy.sh')"

# Commit
cd /root/skyclaw-private
git add skills/<name>.md deploy.sh
git diff --staged --stat

# Show X what will be committed
send_message "📋 Will commit:\n$(git diff --staged --stat)\n\nCommit and push?"
BUTTONS: ✅ Commit | ✏️ Review diff first | ❌ Cancel
```

**Step 5: If X approves commit**
```bash
cd /root/skyclaw-private
git commit -m "skill: add <name>"
git push origin main
```

Confirm: `✅ Skill <name> committed to repo and pushed.`

---

### EDITING AN EXISTING SKILL

**Step 1: Show X current content**
```bash
cat ~/.skyclaw/skills/<name>.md
```

**Step 2: Make the edit on server**
```bash
# Edit the file
nano ~/.skyclaw/skills/<name>.md
# or use file_write for programmatic edits
```

**Step 3: Verify the edit**
```bash
cat ~/.skyclaw/skills/<name>.md
```

**Step 4: Ask X — save to repo?**
```
✏️ Skill updated on server: <name>

Save changes to repo too?
BUTTONS: ✅ Save to repo | 🖥 Server only
```

**Step 5: If saving to repo — show diff first**
```bash
diff ~/.skyclaw/skills/<name>.md /root/skyclaw-private/skills/<name>.md
```
Send the diff to X. If approved:
```bash
cp ~/.skyclaw/skills/<name>.md /root/skyclaw-private/skills/<name>.md
cd /root/skyclaw-private
git add skills/<name>.md
git commit -m "skill: update <name>"
git push origin main
```

---

## SKILLS IN REPO

These 7 skills are tracked in `/root/skyclaw-private/skills/` and deployed automatically:

| Skill | What it covers |
|-------|---------------|
| `devops-core` | kubectl, helm, terraform, ansible, docker, SSH |
| `incident-response` | Triage phases, alert format, severity levels |
| `deployment` | Web apps, K8s, Helm, databases, monitoring, rollback |
| `self-management` | Skill save/edit, MCP install, backup, update (this file) |
| `telegram-features` | HTML formatting, buttons, polls, pins, files, reply-to |
| `study-and-learning` | Roadmaps, ERB/Ruby, DevOps deepening, progress tracking |
| `planning-and-projects` | Project plans, co-builder behavior, memory tracking |

Runtime skills (created by batabeto at runtime) live at `~/.skyclaw/skills/` only —
unless X approves saving them to the repo via the SKILL SAVE FLOW below.

---

## INSTALLING MCP SERVERS

### Install via /mcp command
```
/mcp add <name> npx -y @modelcontextprotocol/server-<name>
```

### Or via shell
```bash
skyclaw mcp add <name> npx -y @modelcontextprotocol/server-<name>
```

### Common MCPs worth knowing
```bash
# Database
/mcp add postgres npx -y @modelcontextprotocol/server-postgres
/mcp add sqlite npx -y @modelcontextprotocol/server-sqlite

# Browser / web
/mcp add playwright npx @playwright/mcp@latest

# Search
/mcp add brave-search npx -y @modelcontextprotocol/server-brave-search

# Files
/mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /

# Already installed: opencode, github, package-docs, kubernetes, fetch, think
```

### Suggest MCP to X
When a task needs a capability you lack:
```
💡 This task would work better with the <name> MCP — <what it enables>.
BUTTONS: 🔌 Install it | ❌ Skip
```

Verify after installing:
```bash
/mcp list
```
Test it by calling one of its tools immediately.

---

## BACKUP

### Run backup now
```bash
bash ~/.skyclaw/workspace/backup.sh
```

### What gets backed up
- `~/.skyclaw/memory.db` — full memory
- `~/.skyclaw/vault/` — encrypted secrets
- `~/.skyclaw/skills/` — all skills including runtime-created ones
- `~/.skyclaw/skyclaw.toml` — config
- `~/.skyclaw/allowlist.toml` — who can use the bot
- `~/.skyclaw/workspace/` — HEARTBEAT.md, backup.sh, restore.sh

### Backup destination
GitHub private repo: `$GITHUB_USERNAME/$GITHUB_BACKUP_REPO`
Runs every 15 minutes via heartbeat.

### Check last backup
```bash
cd ~/.skyclaw/backup-repo && git log --oneline -3
```

---

## RESTORE ON NEW SERVER

```bash
# 1. Ensure .env has GITHUB_TOKEN, GITHUB_USERNAME, GITHUB_BACKUP_REPO
source ~/.skyclaw/.env

# 2. Restore
bash ~/.skyclaw/workspace/restore.sh

# 3. Restart
sudo systemctl restart skyclaw
```

---

## SELF-UPDATE

When X says "update yourself":
```bash
cd /root/skyclaw-private
sudo bash server-update.sh
# server-update.sh: stop → pull → build → install → restart
```

---

## SELF-DIAGNOSTICS

```bash
# Service status
systemctl status skyclaw

# Recent logs
journalctl -u skyclaw --since "10 minutes ago" --no-pager | tail -30

# Memory DB health
sqlite3 ~/.skyclaw/memory.db "PRAGMA integrity_check; SELECT count(*) FROM memories;" 2>/dev/null

# Skills loaded
ls ~/.skyclaw/skills/

# Config
cat ~/.skyclaw/skyclaw.toml

# OpenCode service
systemctl status opencode
```
