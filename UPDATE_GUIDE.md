# batabeto Update Guide
# How to go from old bot → fully updated bot with dashboard

## What changed

| File | Change |
|------|--------|
| `src/main.rs` | Bug 1: model auto-select fix, Bug 3: system prompt reads real model, Bug 4: /status CPU, Patch 1: dashboard startup link, Patch 2: activity.jsonl writes, Patch 3: pause file polling |
| `crates/skyclaw-channels/src/telegram.rs` | Bug 2: poll_answer support |
| `deploy/mcp.toml` | Removed broken fetch server |
| `server-setup.sh` | Added Tailscale, Python, dashboard, ttyd |
| `server-update.sh` | Now also updates dashboard + restarts all services |
| `start.sh` | Now starts dashboard + ttyd |
| `deploy.sh` | Pushes dashboard script on every deploy |
| `skyclaw-dashboard.py` | NEW: the live dashboard |
| `deploy/skyclaw-dashboard.service` | NEW: systemd unit for dashboard |

---

## OPTION A — You build on your local PC (most common)

### Step 1 — Replace the project files

```bash
# On your local PC, unzip the new project
# Replace the old folder with the new one
# OR pull from git if you pushed these changes to your repo
```

### Step 2 — First time only: install new deps on server

```bash
bash deploy.sh <your-server-ip> --init
```

This installs Tailscale, Python, dashboard service, ttyd on the server.
It also pushes all config files and the binary.

### Step 3 — Normal updates after the first time

```bash
# Build locally and push
bash deploy.sh <your-server-ip>

# Or if you also changed skyclaw.toml
bash deploy.sh <your-server-ip> -c
```

### Step 4 — Connect Tailscale on your phone

1. On server: `tailscale up` (if not already connected)
2. On phone: install Tailscale app → sign in with same account
3. Now server and phone are on the same private network

### Step 5 — Start everything

```bash
ssh root@your-server
bash /root/start.sh
```

The bot will send you a Telegram message like:
```
🟢 batabeto online
📊 Dashboard: http://100.x.x.x:8888/dashboard?token=abc123

Activity · Files · Logs · Diff · Terminal
```

Open that link on your phone browser. Done.

---

## OPTION B — You build on the server

### Step 1 — Pull the new code on server

```bash
ssh root@your-server
cd /root/skyclaw-private   # your repo directory
git pull
# or manually replace files if not using git
```

### Step 2 — Run the new setup script

```bash
sudo bash server-setup.sh
```

This adds all missing pieces: Tailscale, Python, dashboard, ttyd.
It will NOT overwrite your existing .env or mcp.toml.

### Step 3 — Build and start

```bash
sudo bash server-update.sh
```

This builds the new binary, updates the dashboard script, restarts everything.

---

## Verify everything is working

```bash
# All three services should be active
systemctl status skyclaw
systemctl status skyclaw-dashboard
systemctl status ttyd

# Check dashboard generated a token
cat /root/.skyclaw/dashboard-token

# Check activity file is being written (after sending a message to bot)
tail -f /root/.skyclaw/activity.jsonl
```

---

## Dashboard tabs

| Tab | What it shows |
|-----|---------------|
| 📡 Activity | Every tool call the bot makes, live |
| 📁 Files | Project tree, tap to read, download button |
| 📋 Logs | Live journal stream, errors in red |
| ⇅ Diff | git diff HEAD, auto-refreshes |
| ⌨️ Terminal | Full bash shell via ttyd |

## Dashboard controls

| Button | What it does |
|--------|--------------|
| ⏸ Pause | Bot finishes current tool call then waits |
| ⏹ Stop | Sends interrupt to current task |
| ▶ Resume | Removes pause file, bot continues |
| 🔄 Restart | Restarts the skyclaw systemd service |

---

## Troubleshooting

**Dashboard not accessible on phone:**
- Make sure Tailscale is running on both server and phone
- `tailscale ip -4` on server — that's the IP to use
- Dashboard token is at `/root/.skyclaw/dashboard-token`

**Activity tab empty:**
- Bot needs to be doing something — send it a task
- Check: `tail -f /root/.skyclaw/activity.jsonl`

**Terminal tab blank:**
- Check ttyd is running: `systemctl status ttyd`
- Make sure ttyd is bound to Tailscale IP, not 0.0.0.0

**Bot not sending dashboard link on startup:**
- Requires OWNER_CHAT_ID to be set in .env
- Requires Tailscale to be connected: `tailscale ip -4`
- Requires dashboard to have run at least once (generates token)
- Start dashboard first, then restart bot
