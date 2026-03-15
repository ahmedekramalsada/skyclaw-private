#!/usr/bin/env python3
"""
skyclaw-dashboard — live monitoring dashboard for batabeto.

Serves a mobile-optimized web UI over your Tailscale network.
The bot sends you the URL on every startup.

Install:
    pip3 install fastapi uvicorn watchdog requests
    cp skyclaw-dashboard.service /etc/systemd/system/
    systemctl daemon-reload && systemctl enable --now skyclaw-dashboard
"""

import asyncio
import json
import logging
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

import requests
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Query
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse, Response
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# ── Config ─────────────────────────────────────────────────────────────────

HOME         = Path.home()
SKYCLAW_DIR  = Path(os.environ.get("SKYCLAW_DIR",  str(HOME / ".skyclaw")))
WATCH_DIR    = Path(os.environ.get("WATCH_DIR",    str(SKYCLAW_DIR)))
PROJECT_DIR  = Path(os.environ.get("PROJECT_DIR",  str(HOME / "skyclaw-private")))
SERVICE_NAME = os.environ.get("SKYCLAW_SERVICE",   "skyclaw")
BOT_TOKEN    = os.environ.get("TELEGRAM_BOT_TOKEN", "")
OWNER_CHAT   = os.environ.get("OWNER_CHAT_ID",      "")
PORT         = int(os.environ.get("DASHBOARD_PORT",  "8888"))
TTYD_PORT    = int(os.environ.get("TTYD_PORT",       "8889"))

TOKEN_FILE    = SKYCLAW_DIR / "dashboard-token"
ACTIVITY_FILE = SKYCLAW_DIR / "activity.jsonl"
PAUSE_FILE    = SKYCLAW_DIR / "dashboard-pause"

# Files/dirs to skip in the file watcher
IGNORE_NAMES = {
    ".git", "__pycache__", "memory.db", "memory.db-wal",
    "memory.db-shm", "skyclaw.pid", "activity.jsonl",
    "target", "node_modules", ".pytest_cache"
}
IGNORE_EXTS = {".swp", ".tmp", ".pyc"}

# Log lines with these tokens trigger instant alerts to Telegram
ALERT_KEYWORDS = ["PANIC", "panic!", "thread '", "ERROR", "FATAL"]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [dashboard] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("dashboard")

# ── Token ──────────────────────────────────────────────────────────────────

def get_or_create_token() -> str:
    SKYCLAW_DIR.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    token = secrets.token_hex(16)
    TOKEN_FILE.write_text(token)
    TOKEN_FILE.chmod(0o600)
    return token

TOKEN = get_or_create_token()

# ── Tailscale IP (with retry) ───────────────────────────────────────────────
# BUG FIX #5: retry up to 12 times with 5s delay so Tailscale has time to
# come up before we bind — avoids sending 0.0.0.0 URL to Telegram.

def get_tailscale_ip(retries: int = 12, delay: float = 5.0) -> str:
    for attempt in range(retries):
        try:
            r = subprocess.run(
                ["tailscale", "ip", "-4"],
                capture_output=True, text=True, timeout=5
            )
            ip = r.stdout.strip()
            if ip and ip != "0.0.0.0":
                return ip
        except Exception:
            pass
        if attempt < retries - 1:
            log.info("Tailscale not ready yet (attempt %d/%d), retrying in %.0fs...", attempt + 1, retries, delay)
            time.sleep(delay)
    log.warning("Tailscale IP not available after %d attempts — binding to 0.0.0.0", retries)
    return "0.0.0.0"

TAILSCALE_IP = get_tailscale_ip()
BIND_HOST    = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "0.0.0.0"

# ── Telegram helpers ────────────────────────────────────────────────────────

def tg_send(text: str) -> None:
    if not BOT_TOKEN or not OWNER_CHAT:
        return
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            json={"chat_id": OWNER_CHAT, "text": text},
            timeout=10,
        )
    except Exception as e:
        log.warning("Telegram send failed: %s", e)

# ── WebSocket connection manager ────────────────────────────────────────────

class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)

    async def broadcast(self, data: dict):
        dead = []
        for ws in self.active:
            try:
                await ws.send_json(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)

mgr = ConnectionManager()

# ── File watcher ────────────────────────────────────────────────────────────

class SkyclawFileHandler(FileSystemEventHandler):
    def __init__(self, loop: asyncio.AbstractEventLoop):
        self.loop = loop
        self._last: dict[str, float] = {}

    def _should_ignore(self, path: str) -> bool:
        p = Path(path)
        if any(part in IGNORE_NAMES for part in p.parts):
            return True
        if p.suffix in IGNORE_EXTS:
            return True
        return False

    def _debounce(self, path: str) -> bool:
        now = time.time()
        last = self._last.get(path, 0)
        if now - last < 1.5:
            return True
        self._last[path] = now
        return False

    def _emit(self, event_type: str, path: str):
        if self._should_ignore(path) or self._debounce(path):
            return
        rel = self._rel(path)
        payload = {"type": "file_change", "event": event_type, "path": rel, "ts": int(time.time())}
        asyncio.run_coroutine_threadsafe(mgr.broadcast(payload), self.loop)

    def _rel(self, path: str) -> str:
        try:
            return str(Path(path).relative_to(HOME))
        except ValueError:
            return path

    def on_modified(self, event):
        if not event.is_directory:
            self._emit("modified", event.src_path)

    def on_created(self, event):
        if not event.is_directory:
            self._emit("created", event.src_path)

    def on_deleted(self, event):
        if not event.is_directory:
            self._emit("deleted", event.src_path)

    def on_moved(self, event):
        self._emit("moved", event.dest_path)

# ── Activity file tailer ────────────────────────────────────────────────────

async def tail_activity():
    """Tail ~/.skyclaw/activity.jsonl written by the Rust bot on each tool call."""
    ACTIVITY_FILE.touch(exist_ok=True)
    last_size = ACTIVITY_FILE.stat().st_size
    while True:
        await asyncio.sleep(0.3)
        try:
            size = ACTIVITY_FILE.stat().st_size
            if size < last_size:
                last_size = 0  # file was rotated/truncated
            if size == last_size:
                continue
            with open(ACTIVITY_FILE, "r") as f:
                f.seek(last_size)
                new = f.read()
            last_size = size
            for line in new.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    await _activity_to_ws(entry)
                except json.JSONDecodeError:
                    pass
        except Exception as e:
            log.debug("Activity tail error: %s", e)
            await asyncio.sleep(2)

async def _activity_to_ws(entry: dict):
    tool = entry.get("tool", "")
    detail = entry.get("detail", "")
    idx = entry.get("index", 0)
    total = entry.get("total", 0)
    ts = entry.get("ts", int(time.time()))
    entry_type = entry.get("type", "tool")

    if entry_type == "thinking":
        icon = "🤔"
        text = f"Thinking (round {entry.get('round', '?')})..."
    else:
        icon = {
            "shell": "⚙️", "file_write": "✏️", "file_read": "📂",
            "file_list": "📂", "web_fetch": "🌐", "browser": "🖥️",
            "git": "🔀", "memory_manage": "🧠", "send_message": "📨",
            "send_file": "📨", "self_create_tool": "🔧",
        }.get(tool, "🛠️")
        count = f"[{idx+1}/{total}] " if total else ""
        text = f"{count}{tool}{': ' + detail if detail else ''}"

    await mgr.broadcast({"type": "activity", "icon": icon, "text": text, "ts": ts})

# ── Journal log tailer ──────────────────────────────────────────────────────

async def tail_journal():
    """Stream bot logs from journald in real time."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "journalctl", "-fu", SERVICE_NAME,
            "--output=cat", "--no-pager",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception as e:
        log.warning("journalctl not available: %s", e)
        return

    while True:
        try:
            line_bytes = await proc.stdout.readline()
            if not line_bytes:
                break
            line = line_bytes.decode("utf-8", errors="replace").rstrip()
            if not line:
                continue

            level = "INFO"
            if any(k in line for k in ["ERROR", "error"]):
                level = "ERROR"
            elif any(k in line for k in ["WARN", "warn"]):
                level = "WARN"
            elif any(k in line for k in ["PANIC", "panic"]):
                level = "ERROR"

            await mgr.broadcast({"type": "log", "level": level, "text": line})

            if any(k in line for k in ALERT_KEYWORDS):
                tg_send(f"🚨 batabeto log alert:\n{line[:300]}")

        except Exception as e:
            log.debug("Journal tail error: %s", e)
            await asyncio.sleep(2)

# ── Bot status poller ───────────────────────────────────────────────────────

async def poll_status():
    """Check if the bot service is alive every 10 seconds."""
    was_alive = True
    while True:
        await asyncio.sleep(10)
        try:
            r = subprocess.run(
                ["systemctl", "is-active", SERVICE_NAME],
                capture_output=True, text=True
            )
            alive = r.stdout.strip() == "active"
        except Exception:
            pid_file = SKYCLAW_DIR / "skyclaw.pid"
            alive = False
            if pid_file.exists():
                try:
                    pid = int(pid_file.read_text().strip())
                    alive = (Path(f"/proc/{pid}").exists())
                except Exception:
                    pass

        await mgr.broadcast({"type": "status", "alive": alive})

        if was_alive and not alive:
            tg_send("🔴 batabeto has stopped.")
        elif not was_alive and alive:
            tg_send("🟢 batabeto is back online.")
        was_alive = alive

# ── Helpers ─────────────────────────────────────────────────────────────────

# BUG FIX #3: raise proper 403 with a message so the frontend can detect it
def check_token(token: str = Query(default="")):
    if token != TOKEN:
        raise HTTPException(status_code=403, detail="Invalid or missing token. Open the URL sent by the bot which includes ?token=...")

def safe_path(path: str) -> Optional[Path]:
    """Return an absolute path only if it's under HOME, SKYCLAW_DIR, or PROJECT_DIR."""
    p = (HOME / path).resolve()
    try:
        p.relative_to(HOME)
        return p
    except ValueError:
        pass
    try:
        p.relative_to(SKYCLAW_DIR.resolve())
        return p
    except ValueError:
        pass
    if PROJECT_DIR.exists():
        try:
            p.relative_to(PROJECT_DIR.resolve())
            return p
        except ValueError:
            pass
    return None

def fmt_size(n: int) -> str:
    for unit in ["B", "K", "M", "G"]:
        if n < 1024:
            return f"{n}{unit}"
        n //= 1024
    return f"{n}G"

def build_tree(root: Path, recent_files: set, prefix: str = "") -> list[dict]:
    items = []
    try:
        entries = sorted(root.iterdir(), key=lambda e: (e.is_file(), e.name))
    except PermissionError:
        return items
    for entry in entries:
        if entry.name in IGNORE_NAMES or entry.name.startswith(".git"):
            continue
        try:
            rel = str(entry.relative_to(HOME))
        except ValueError:
            rel = str(entry.resolve())
        if entry.is_dir():
            children = build_tree(entry, recent_files, prefix + "  ")
            if children:
                items.append({"type": "dir", "name": entry.name, "path": rel, "children": children})
        else:
            mtime = entry.stat().st_mtime
            items.append({
                "type": "file",
                "name": entry.name,
                "path": rel,
                "size": fmt_size(entry.stat().st_size),
                "modified": (time.time() - mtime) < 300,
            })
    return items

# ── FastAPI app ─────────────────────────────────────────────────────────────

app = FastAPI(docs_url=None, redoc_url=None)

@app.get("/")
async def root():
    return HTMLResponse(DASHBOARD_HTML)

@app.get("/dashboard")
async def dashboard(token: str = Query(default="")):
    check_token(token)
    return HTMLResponse(DASHBOARD_HTML)

@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket, token: str = Query(default="")):
    # BUG FIX #3: return clear close code on bad token
    if token != TOKEN:
        await websocket.close(code=4003, reason="Invalid token")
        return
    await mgr.connect(websocket)
    try:
        r = subprocess.run(["systemctl", "is-active", SERVICE_NAME], capture_output=True, text=True)
        alive = r.stdout.strip() == "active"
    except Exception:
        alive = False
    await websocket.send_json({"type": "status", "alive": alive})
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        mgr.disconnect(websocket)

@app.get("/api/tree")
async def api_tree(token: str = Query(default="")):
    check_token(token)
    recent: set = set()
    try:
        if ACTIVITY_FILE.exists():
            lines = ACTIVITY_FILE.read_text().splitlines()[-200:]
            for l in lines:
                try:
                    e = json.loads(l)
                    if "detail" in e and "/" in e.get("detail", ""):
                        recent.add(e["detail"])
                except Exception:
                    pass
    except Exception:
        pass

    dirs_to_scan = [SKYCLAW_DIR]
    if PROJECT_DIR.exists():
        dirs_to_scan.append(PROJECT_DIR)

    all_files = []
    for d in dirs_to_scan:
        all_files.extend(build_tree(d, recent))

    return {"files": all_files}

@app.get("/api/file")
async def api_file(path: str = Query(default=""), token: str = Query(default="")):
    check_token(token)
    p = safe_path(path)
    if not p or not p.exists() or not p.is_file():
        return {"error": f"File not found: {path}"}
    try:
        content = p.read_text(errors="replace")
        return {"content": content, "path": str(p)}
    except Exception as e:
        return {"error": str(e)}

@app.get("/api/download")
async def api_download(path: str = Query(default=""), token: str = Query(default="")):
    check_token(token)
    p = safe_path(path)
    if not p or not p.exists() or not p.is_file():
        raise HTTPException(status_code=404)
    return FileResponse(str(p), filename=p.name)

@app.get("/api/diff")
async def api_diff(token: str = Query(default="")):
    check_token(token)
    cwd = str(PROJECT_DIR) if PROJECT_DIR.exists() else str(SKYCLAW_DIR)
    try:
        r = subprocess.run(
            ["git", "diff", "HEAD"],
            cwd=cwd, capture_output=True, text=True, timeout=10
        )
        diff = r.stdout or r.stderr or "No changes."
    except Exception as e:
        diff = f"git diff failed: {e}"
    return {"diff": diff}

@app.get("/api/log")
async def api_log(n: int = Query(default=50), token: str = Query(default="")):
    check_token(token)
    try:
        r = subprocess.run(
            ["journalctl", "-u", SERVICE_NAME, f"-n{n}", "--output=cat", "--no-pager"],
            capture_output=True, text=True, timeout=10
        )
        lines = r.stdout.strip().splitlines()
    except Exception:
        lines = ["journalctl not available"]
    return {"lines": lines}

@app.get("/api/ps")
async def api_ps(token: str = Query(default="")):
    check_token(token)
    try:
        r = subprocess.run(
            ["ps", "aux", "--sort=-%cpu"],
            capture_output=True, text=True, timeout=5
        )
        return {"output": r.stdout}
    except Exception as e:
        return {"output": str(e)}

@app.get("/api/grep")
async def api_grep(q: str = Query(default=""), token: str = Query(default="")):
    check_token(token)
    if not q:
        return {"results": []}
    cwd = str(PROJECT_DIR) if PROJECT_DIR.exists() else str(SKYCLAW_DIR)
    try:
        r = subprocess.run(
            ["grep", "-rn", "--include=*.rs", "--include=*.py",
             "--include=*.toml", "--include=*.sh", "--include=*.md",
             "-m", "5", q, "."],
            cwd=cwd, capture_output=True, text=True, timeout=10
        )
        return {"results": r.stdout.splitlines()[:50]}
    except Exception as e:
        return {"results": [str(e)]}

@app.post("/api/control")
async def api_control(body: dict, token: str = Query(default="")):
    check_token(token)
    action = body.get("action", "")

    if action == "pause":
        PAUSE_FILE.touch()
        await mgr.broadcast({"type": "activity", "icon": "⏸", "text": "Dashboard: bot paused", "ts": int(time.time())})
        return {"ok": True}

    elif action == "resume":
        PAUSE_FILE.unlink(missing_ok=True)
        await mgr.broadcast({"type": "activity", "icon": "▶️", "text": "Dashboard: bot resumed", "ts": int(time.time())})
        return {"ok": True}

    elif action == "stop":
        if BOT_TOKEN and OWNER_CHAT:
            tg_send("stop")
        await mgr.broadcast({"type": "activity", "icon": "⏹", "text": "Dashboard: stop signal sent", "ts": int(time.time())})
        return {"ok": True}

    elif action == "restart":
        subprocess.Popen(["systemctl", "restart", SERVICE_NAME])
        await mgr.broadcast({"type": "activity", "icon": "🔄", "text": "Dashboard: restarting service...", "ts": int(time.time())})
        return {"ok": True}

    return {"ok": False, "error": "unknown action"}

@app.get("/terminal")
async def terminal(token: str = Query(default="")):
    check_token(token)
    host = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "localhost"
    ttyd_url = f"http://{host}:{TTYD_PORT}"
    html = f"""<!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{{margin:0;background:#080b10}} iframe{{width:100%;height:100vh;border:none}}</style>
    </head><body>
    <iframe src="{ttyd_url}" allowfullscreen></iframe>
    </body></html>"""
    return HTMLResponse(html)

# ── Startup ─────────────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup():
    loop = asyncio.get_event_loop()

    handler = SkyclawFileHandler(loop)
    observer = Observer()
    observer.schedule(handler, str(SKYCLAW_DIR), recursive=True)
    if PROJECT_DIR.exists():
        observer.schedule(handler, str(PROJECT_DIR), recursive=True)
    observer.start()
    log.info("File watcher started on %s", SKYCLAW_DIR)

    asyncio.create_task(tail_activity())
    asyncio.create_task(tail_journal())
    asyncio.create_task(poll_status())

    host = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "your-server"
    url = f"http://{host}:{PORT}/dashboard?token={TOKEN}"
    log.info("Dashboard: %s", url)

    if BOT_TOKEN and OWNER_CHAT:
        tg_send(
            f"📊 Dashboard online\n"
            f"{url}\n\n"
            f"Tabs: Activity · Files · Logs · Diff · Terminal\n"
            f"Controls: ⏸ Pause  ⏹ Stop  ▶ Resume  🔄 Restart"
        )

# ── Embedded HTML ────────────────────────────────────────────────────────────

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#080b10">
<title>batabeto</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@400;500;600&display=swap" rel="stylesheet">
<style>
/* ── Reset & Base ──────────────────────────────────────────── */
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
:root{
  --bg:          #080b10;
  --surface:     #0e1219;
  --surface2:    #141922;
  --border:      #1e2535;
  --border2:     #252d3f;
  --text:        #cdd6f4;
  --text-dim:    #6c7a99;
  --text-faint:  #3d4a66;
  --accent:      #7aa2f7;
  --accent-dim:  #1a2340;
  --green:       #9ece6a;
  --green-dim:   #1a2e12;
  --red:         #f7768e;
  --red-dim:     #2e1219;
  --yellow:      #e0af68;
  --yellow-dim:  #2e2412;
  --cyan:        #7dcfff;
  --purple:      #bb9af7;
  --mono:        'JetBrains Mono', monospace;
  --sans:        'Space Grotesk', sans-serif;
  --radius:      10px;
  --radius-sm:   6px;
}
html,body{height:100%;overflow:hidden;background:var(--bg);color:var(--text);font-family:var(--sans)}

/* ── Layout Shell ──────────────────────────────────────────── */
.app{display:flex;flex-direction:column;height:100vh;height:100dvh}
.content{flex:1;overflow:hidden;position:relative;display:flex;flex-direction:column}
.panel{display:none;flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;flex-direction:column}
.panel.active{display:flex}

/* ── Header ────────────────────────────────────────────────── */
.header{
  display:flex;align-items:center;gap:10px;
  padding:0 16px;height:52px;
  background:var(--surface);
  border-bottom:1px solid var(--border);
  flex-shrink:0;
  position:relative;
}
.header::after{
  content:'';position:absolute;bottom:-1px;left:0;right:0;height:1px;
  background:linear-gradient(90deg,transparent,var(--accent-dim),transparent);
}

/* Status indicator */
.status-pill{
  display:flex;align-items:center;gap:6px;
  padding:4px 10px;border-radius:20px;
  background:var(--surface2);border:1px solid var(--border);
  font-size:11px;font-weight:600;letter-spacing:.03em;
  font-family:var(--mono);transition:all .3s;flex-shrink:0;
}
.status-pill .dot{
  width:7px;height:7px;border-radius:50%;
  background:var(--green);
  box-shadow:0 0 8px var(--green);
  animation:pulse 2s infinite;
}
.status-pill.dead .dot{
  background:var(--red);box-shadow:0 0 8px var(--red);animation:none;
}
.status-pill.dead{border-color:rgba(247,118,142,.2)}
.status-pill .pill-label{color:var(--text-dim)}
.status-pill.dead .pill-label{color:var(--red)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}

.h-title{font-size:14px;font-weight:600;flex:1;color:var(--text);letter-spacing:-.01em}

/* Control buttons */
.ctrl-group{display:flex;gap:6px;align-items:center}
.ctrl-btn{
  display:flex;align-items:center;justify-content:center;
  width:32px;height:32px;border-radius:var(--radius-sm);
  border:1px solid var(--border);background:var(--surface2);
  color:var(--text-dim);cursor:pointer;font-size:14px;
  transition:all .15s;-webkit-user-select:none;user-select:none;touch-action:manipulation;
  position:relative;overflow:hidden;
}
.ctrl-btn:active{transform:scale(.92)}
.ctrl-btn:hover{border-color:var(--border2);color:var(--text)}
.ctrl-btn.warn{border-color:rgba(224,175,104,.3);color:var(--yellow)}
.ctrl-btn.warn:hover{background:var(--yellow-dim);border-color:var(--yellow)}
.ctrl-btn.danger{border-color:rgba(247,118,142,.3);color:var(--red)}
.ctrl-btn.danger:hover{background:var(--red-dim);border-color:var(--red)}
.ctrl-btn.success{border-color:rgba(158,206,106,.3);color:var(--green)}
.ctrl-btn.success:hover{background:var(--green-dim);border-color:var(--green)}
.ctrl-btn.loading{pointer-events:none;opacity:.5}
.ctrl-btn::after{
  content:'';position:absolute;inset:0;background:white;
  opacity:0;border-radius:inherit;transition:opacity .1s;
}
.ctrl-btn:active::after{opacity:.05}

/* ── Reconnect Banner ──────────────────────────────────────── */
.banner{
  display:none;align-items:center;justify-content:center;gap:8px;
  padding:8px 16px;background:var(--yellow-dim);
  border-bottom:1px solid rgba(224,175,104,.3);
  font-size:12px;color:var(--yellow);font-family:var(--mono);
  flex-shrink:0;
}
.banner.show{display:flex}
.banner-dot{width:6px;height:6px;border-radius:50%;background:var(--yellow);animation:pulse 1s infinite}

/* ── Auth Error Screen ─────────────────────────────────────── */
/* BUG FIX #3: show clear error if token is missing/invalid */
.auth-error{
  display:flex;flex-direction:column;align-items:center;justify-content:center;
  height:100%;gap:16px;padding:32px;text-align:center;
}
.auth-error-icon{font-size:48px;margin-bottom:8px}
.auth-error h2{font-size:18px;color:var(--red)}
.auth-error p{font-size:13px;color:var(--text-dim);line-height:1.6;max-width:320px;font-family:var(--mono)}

/* ── Toast ─────────────────────────────────────────────────── */
.toast{
  position:fixed;bottom:80px;left:50%;transform:translateX(-50%) translateY(10px);
  background:var(--surface2);border:1px solid var(--border2);
  color:var(--text);padding:8px 16px;border-radius:20px;
  font-size:12px;font-family:var(--mono);font-weight:500;
  z-index:200;opacity:0;transition:opacity .2s,transform .2s;
  pointer-events:none;white-space:nowrap;
  box-shadow:0 4px 24px rgba(0,0,0,.4);
}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.toast.error{border-color:rgba(247,118,142,.4);color:var(--red)}
.toast.success{border-color:rgba(158,206,106,.4);color:var(--green)}

/* ── Tab Bar ───────────────────────────────────────────────── */
.tabbar{
  display:flex;background:var(--surface);
  border-top:1px solid var(--border);
  flex-shrink:0;padding-bottom:env(safe-area-inset-bottom);
  position:relative;
}
.tabbar::before{
  content:'';position:absolute;top:-1px;left:0;right:0;height:1px;
  background:linear-gradient(90deg,transparent,var(--accent-dim),transparent);
}
.tab{
  flex:1;display:flex;flex-direction:column;align-items:center;
  justify-content:center;padding:8px 4px;font-size:9px;font-weight:600;
  color:var(--text-faint);cursor:pointer;gap:3px;min-height:52px;
  letter-spacing:.06em;text-transform:uppercase;
  border-top:2px solid transparent;transition:all .15s;
  -webkit-user-select:none;user-select:none;
}
.tab-icon{font-size:17px;line-height:1;transition:transform .15s}
.tab:active .tab-icon{transform:scale(.88)}
.tab.active{color:var(--accent);border-top-color:var(--accent)}
.tab-badge{
  position:absolute;top:6px;right:calc(50% - 14px);
  min-width:16px;height:16px;border-radius:8px;
  background:var(--red);color:#fff;
  font-size:9px;font-weight:700;display:flex;align-items:center;justify-content:center;
  padding:0 4px;display:none;
}
.tab-badge.show{display:flex}

/* ── Section Headers ───────────────────────────────────────── */
.section-header{
  display:flex;align-items:center;justify-content:space-between;
  padding:10px 16px;background:var(--surface);
  border-bottom:1px solid var(--border);
  position:sticky;top:0;z-index:10;flex-shrink:0;
}
.section-label{font-size:11px;font-weight:600;color:var(--text-dim);letter-spacing:.06em;text-transform:uppercase;font-family:var(--mono)}
.section-actions{display:flex;gap:6px}
.icon-btn{
  display:flex;align-items:center;gap:5px;
  padding:4px 10px;border-radius:var(--radius-sm);
  border:1px solid var(--border);background:transparent;
  color:var(--text-dim);font-size:11px;font-family:var(--mono);
  cursor:pointer;transition:all .15s;white-space:nowrap;
}
.icon-btn:hover{border-color:var(--border2);color:var(--text)}
.icon-btn:active{transform:scale(.95)}

/* ── Activity Feed ─────────────────────────────────────────── */
#panel-activity{flex-direction:column}
#feed{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch}
.feed-item{
  display:grid;grid-template-columns:28px 1fr auto;
  align-items:start;gap:10px;
  padding:10px 16px;
  border-bottom:1px solid var(--border);
  animation:slideIn .2s ease;
  transition:background .1s;
}
.feed-item:hover{background:var(--surface)}
@keyframes slideIn{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}
.feed-icon{
  width:28px;height:28px;border-radius:8px;
  background:var(--surface2);border:1px solid var(--border);
  display:flex;align-items:center;justify-content:center;
  font-size:13px;flex-shrink:0;margin-top:1px;
}
.feed-text{
  font-size:12px;font-family:var(--mono);
  color:var(--text);line-height:1.6;word-break:break-all;
  padding-top:1px;
}
.feed-time{font-size:10px;color:var(--text-faint);font-family:var(--mono);white-space:nowrap;padding-top:3px}

/* ── Files Panel ───────────────────────────────────────────── */
.search-row{
  display:flex;gap:8px;padding:10px 16px;
  background:var(--surface);border-bottom:1px solid var(--border);
  position:sticky;top:0;z-index:10;flex-shrink:0;
}
.search-input{
  flex:1;background:var(--bg);border:1px solid var(--border);
  color:var(--text);padding:8px 12px;border-radius:var(--radius-sm);
  font-size:13px;font-family:var(--mono);outline:none;
  transition:border-color .15s;
}
.search-input:focus{border-color:var(--accent)}
.search-input::placeholder{color:var(--text-faint)}
.search-go{
  padding:8px 14px;background:var(--accent-dim);border:1px solid rgba(122,162,247,.3);
  color:var(--accent);border-radius:var(--radius-sm);font-size:13px;
  cursor:pointer;font-family:var(--mono);font-weight:600;
  transition:all .15s;white-space:nowrap;
}
.search-go:hover{background:rgba(122,162,247,.15);border-color:var(--accent)}
.search-go:active{transform:scale(.96)}

/* File tree */
.tree-group-label{
  padding:8px 16px;font-size:10px;font-weight:600;
  color:var(--text-faint);text-transform:uppercase;letter-spacing:.08em;
  background:var(--bg);border-bottom:1px solid var(--border);font-family:var(--mono);
}
.tree-item{
  display:flex;align-items:center;gap:10px;
  padding:9px 16px;border-bottom:1px solid var(--border);
  cursor:pointer;transition:background .1s;
}
.tree-item:hover{background:var(--surface)}
.tree-item:active{background:var(--surface2)}
.tree-item-icon{font-size:13px;flex-shrink:0;color:var(--text-dim)}
.tree-item-name{
  font-size:12px;font-family:var(--mono);flex:1;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text);
}
.tree-item-modified{
  font-size:9px;font-weight:700;letter-spacing:.04em;
  color:var(--yellow);background:var(--yellow-dim);
  border:1px solid rgba(224,175,104,.3);padding:2px 6px;border-radius:10px;
  flex-shrink:0;text-transform:uppercase;
}
.tree-item-size{font-size:10px;color:var(--text-faint);font-family:var(--mono);flex-shrink:0}
.tree-dir{
  padding:6px 16px;font-size:10px;font-family:var(--mono);
  color:var(--text-faint);letter-spacing:.04em;
  display:flex;align-items:center;gap:6px;
  background:var(--bg);border-bottom:1px solid var(--border);
}

/* ── File Viewer Overlay ───────────────────────────────────── */
.viewer{
  position:absolute;inset:0;background:var(--bg);
  z-index:50;flex-direction:column;display:none;
  animation:fadeIn .15s ease;
}
.viewer.open{display:flex}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.viewer-header{
  display:flex;align-items:center;gap:10px;
  padding:0 16px;height:52px;
  background:var(--surface);border-bottom:1px solid var(--border);
  flex-shrink:0;
}
.viewer-back{
  font-size:18px;cursor:pointer;color:var(--accent);
  padding:6px;border-radius:var(--radius-sm);
  transition:background .1s;line-height:1;
}
.viewer-back:hover{background:var(--accent-dim)}
.viewer-filename{
  font-size:12px;font-family:var(--mono);flex:1;
  color:var(--text-dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
}
.viewer-body{
  flex:1;overflow:auto;-webkit-overflow-scrolling:touch;
  padding:16px;font-family:var(--mono);font-size:12px;
  line-height:1.75;white-space:pre;color:var(--text);tab-size:2;
}

/* ── Logs Panel ────────────────────────────────────────────── */
#log-feed{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;font-family:var(--mono)}
.log-line{
  padding:4px 16px;font-size:11px;line-height:1.6;
  border-bottom:1px solid rgba(30,37,53,.6);
  word-break:break-all;
}
.log-line.error{color:var(--red);background:rgba(247,118,142,.04)}
.log-line.warn{color:var(--yellow);background:rgba(224,175,104,.03)}
.log-line.info{color:var(--text-dim)}

/* ── Diff Panel ────────────────────────────────────────────── */
#diff-body{font-family:var(--mono)}
.diff-file-header{
  padding:10px 16px;font-size:11px;font-weight:600;
  color:var(--cyan);background:var(--surface);
  border-bottom:1px solid var(--border);
  border-top:2px solid var(--border2);
  margin-top:8px;
}
.diff-file-header:first-child{margin-top:0;border-top:none}
.diff-hunk{
  padding:5px 16px;font-size:11px;color:var(--purple);
  background:rgba(187,154,247,.04);border-bottom:1px solid rgba(187,154,247,.1);
}
.diff-add{
  padding:2px 16px;font-size:11px;
  background:rgba(158,206,106,.08);color:var(--green);
  white-space:pre-wrap;word-break:break-all;
}
.diff-del{
  padding:2px 16px;font-size:11px;
  background:rgba(247,118,142,.08);color:var(--red);
  white-space:pre-wrap;word-break:break-all;
}
.diff-ctx{
  padding:2px 16px;font-size:11px;
  color:var(--text-faint);white-space:pre-wrap;word-break:break-all;
}
.diff-empty{
  padding:48px 16px;text-align:center;
  font-size:13px;color:var(--text-faint);font-family:var(--mono);
}

/* ── Empty States ──────────────────────────────────────────── */
.empty-state{
  display:flex;flex-direction:column;align-items:center;justify-content:center;
  padding:64px 32px;gap:12px;color:var(--text-faint);text-align:center;
  flex:1;
}
.empty-icon{font-size:32px;opacity:.4}
.empty-label{font-size:13px;font-family:var(--mono)}

/* ── Scrollbar Styling ─────────────────────────────────────── */
::-webkit-scrollbar{width:4px;height:4px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
::-webkit-scrollbar-thumb:hover{background:var(--text-faint)}
</style>
</head>
<body>
<div class="app">

<!-- Reconnect banner -->
<div class="banner" id="banner">
  <div class="banner-dot"></div>
  Reconnecting...
</div>

<!-- Header -->
<div class="header">
  <div class="status-pill" id="status-pill">
    <div class="dot"></div>
    <span class="pill-label" id="pill-label">online</span>
  </div>
  <div class="h-title" id="h-title">batabeto</div>
  <div class="ctrl-group">
    <button class="ctrl-btn warn"    id="btn-pause"  onclick="ctrl('pause')"   title="Pause">⏸</button>
    <button class="ctrl-btn success" id="btn-resume" onclick="ctrl('resume')"  title="Resume" style="display:none">▶</button>
    <button class="ctrl-btn danger"  onclick="ctrl('stop')"                    title="Stop">⏹</button>
    <button class="ctrl-btn"         onclick="ctrl('restart')"                 title="Restart">↺</button>
  </div>
</div>

<!-- Content panels -->
<div class="content">

  <!-- Activity -->
  <div class="panel active" id="panel-activity">
    <div class="section-header">
      <span class="section-label">Live Activity</span>
      <div class="section-actions">
        <button class="icon-btn" onclick="clearFeed()">✕ Clear</button>
      </div>
    </div>
    <div id="feed">
      <div class="empty-state">
        <div class="empty-icon">📡</div>
        <div class="empty-label">Waiting for bot activity...</div>
      </div>
    </div>
  </div>

  <!-- Files -->
  <div class="panel" id="panel-files">
    <div class="search-row">
      <input class="search-input" id="grep-input" placeholder="Search in files..." onkeydown="if(event.key==='Enter')doGrep()">
      <button class="search-go" onclick="doGrep()">Search</button>
    </div>
    <div id="file-tree">
      <div class="empty-state"><div class="empty-icon">📁</div><div class="empty-label">Loading...</div></div>
    </div>
    <!-- File viewer overlay -->
    <div class="viewer" id="viewer">
      <div class="viewer-header">
        <div class="viewer-back" onclick="closeViewer()">←</div>
        <div class="viewer-filename" id="viewer-fn"></div>
        <button class="icon-btn" onclick="dlFile()">⬇ Save</button>
      </div>
      <div class="viewer-body" id="viewer-body">Loading...</div>
    </div>
  </div>

  <!-- Logs -->
  <div class="panel" id="panel-logs">
    <div class="section-header">
      <span class="section-label">Journal Logs</span>
      <div class="section-actions">
        <button class="icon-btn" onclick="loadLog()">↻ Refresh</button>
        <button class="icon-btn" onclick="clearLogs()">✕ Clear</button>
      </div>
    </div>
    <div id="log-feed">
      <div class="empty-state"><div class="empty-icon">📋</div><div class="empty-label">Waiting for logs...</div></div>
    </div>
  </div>

  <!-- Diff -->
  <div class="panel" id="panel-diff">
    <div class="section-header">
      <span class="section-label">git diff HEAD</span>
      <div class="section-actions">
        <button class="icon-btn" onclick="loadDiff()">↻ Refresh</button>
      </div>
    </div>
    <div id="diff-body"></div>
  </div>

  <!-- Terminal -->
  <div class="panel" id="panel-terminal">
    <iframe id="term-frame" src="" style="width:100%;flex:1;border:none" title="Terminal"></iframe>
  </div>

</div>

<!-- Tab bar -->
<div class="tabbar">
  <div class="tab active" id="tab-activity" onclick="switchTab('activity')">
    <span class="tab-icon">📡</span>Activity
  </div>
  <div class="tab" id="tab-files" onclick="switchTab('files')">
    <span class="tab-icon">📁</span>Files
  </div>
  <div class="tab" id="tab-logs" onclick="switchTab('logs')">
    <span class="tab-icon">📋</span>Logs
  </div>
  <div class="tab" id="tab-diff" onclick="switchTab('diff')">
    <span class="tab-icon">⇅</span>Diff
  </div>
  <div class="tab" id="tab-terminal" onclick="switchTab('terminal')">
    <span class="tab-icon">⌨️</span>Shell
  </div>
</div>

</div><!-- .app -->

<script>
// ── BUG FIX #3: detect missing token immediately ───────────────
const TOKEN = new URLSearchParams(location.search).get('token') || '';

if (!TOKEN) {
  document.querySelector('.content').innerHTML = `
    <div class="auth-error">
      <div class="auth-error-icon">🔒</div>
      <h2>Token required</h2>
      <p>Open the URL sent by the bot — it includes a <code>?token=...</code> parameter.<br><br>
      Or check the server:<br><code>cat ~/.skyclaw/dashboard-token</code></p>
    </div>`;
  document.querySelector('.tabbar').style.display = 'none';
  document.querySelector('.ctrl-group').style.pointerEvents = 'none';
  document.querySelector('.ctrl-group').style.opacity = '.3';
}

const api = (p, extra='') => `${location.origin}${p}?token=${TOKEN}${extra}`;
const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
const wsUrl = `${wsProto}//${location.host}/ws?token=${TOKEN}`;

let ws, reconnTimer;
let feedCount = 0, logCount = 0;
let paused = false, currentFile = null;
let errorCount = 0;

// ── Toast ──────────────────────────────────────────────────────
let toastEl, toastTimer;
function showToast(msg, type='', ms=2800) {
  if (!toastEl) {
    toastEl = document.createElement('div');
    toastEl.className = 'toast';
    document.body.appendChild(toastEl);
  }
  toastEl.textContent = msg;
  toastEl.className = 'toast show' + (type ? ' ' + type : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('show'), ms);
}

// ── WebSocket ──────────────────────────────────────────────────
function connect() {
  if (!TOKEN) return;
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
  try { ws = new WebSocket(wsUrl); } catch(e) { scheduleReconnect(); return; }
  ws.onopen = () => {
    document.getElementById('banner').classList.remove('show');
    loadTree(); loadDiff(); loadLog();
  };
  ws.onclose = (e) => {
    document.getElementById('banner').classList.add('show');
    // BUG FIX #3: if closed due to bad token, show error
    if (e.code === 4003) {
      showToast('❌ Invalid token — refresh with correct URL', 'error', 6000);
      return;
    }
    scheduleReconnect();
  };
  ws.onerror = () => {};
  ws.onmessage = e => { try { handle(JSON.parse(e.data)); } catch(err) {} };
}
function scheduleReconnect() {
  clearTimeout(reconnTimer);
  reconnTimer = setTimeout(connect, 3000);
}
setInterval(() => { if (ws && ws.readyState === 1) ws.send('ping'); }, 25000);

function handle(m) {
  if (m.type === 'activity') addActivity(m);
  else if (m.type === 'log') addLogLine(m);
  else if (m.type === 'file_change') onFileChange(m);
  else if (m.type === 'status') updateStatus(m);
}

// ── Status ─────────────────────────────────────────────────────
function updateStatus(m) {
  const pill = document.getElementById('status-pill');
  const label = document.getElementById('pill-label');
  const title = document.getElementById('h-title');
  if (m.alive) {
    pill.className = 'status-pill';
    label.textContent = 'online';
    title.textContent = 'batabeto';
  } else {
    pill.className = 'status-pill dead';
    label.textContent = 'offline';
    title.textContent = 'batabeto';
  }
}

// ── Activity ───────────────────────────────────────────────────
function addActivity(m) {
  const feed = document.getElementById('feed');
  if (feedCount === 0) feed.innerHTML = '';
  feedCount++;
  const t = new Date(m.ts * 1000).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit', second:'2-digit'});
  const d = document.createElement('div');
  d.className = 'feed-item';
  d.innerHTML = `
    <div class="feed-icon">${m.icon || '🔹'}</div>
    <div class="feed-text">${esc(m.text)}</div>
    <div class="feed-time">${t}</div>`;
  feed.insertBefore(d, feed.firstChild);
  while (feed.children.length > 300) feed.removeChild(feed.lastChild);
}
function clearFeed() { document.getElementById('feed').innerHTML = `<div class="empty-state"><div class="empty-icon">📡</div><div class="empty-label">Feed cleared</div></div>`; feedCount = 0; }

// ── Logs ───────────────────────────────────────────────────────
let logInit = false;
function addLogLine(m) {
  const el = document.getElementById('log-feed');
  if (!logInit) { el.innerHTML = ''; logInit = true; }
  logCount++;
  const d = document.createElement('div');
  const lvl = m.level || '';
  d.className = 'log-line' + (lvl === 'ERROR' ? ' error' : lvl === 'WARN' ? ' warn' : ' info');
  d.textContent = m.text;
  el.appendChild(d);
  if (document.getElementById('panel-logs').classList.contains('active'))
    el.scrollTop = el.scrollHeight;
  while (el.children.length > 600) el.removeChild(el.firstChild);
}
function clearLogs() { document.getElementById('log-feed').innerHTML = `<div class="empty-state"><div class="empty-icon">📋</div><div class="empty-label">Logs cleared</div></div>`; logInit = false; logCount = 0; }
async function loadLog() {
  const r = await fetch(api('/api/log', '&n=80'));
  if (!r.ok) { handleHttpError(r.status, 'logs'); return; }
  const data = await r.json();
  const el = document.getElementById('log-feed');
  el.innerHTML = ''; logInit = true;
  if (!data.lines || data.lines.length === 0) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">📋</div><div class="empty-label">No log entries found for service "${location.hostname}"</div></div>`;
    return;
  }
  data.lines.forEach(line => {
    const d = document.createElement('div');
    const lvl = line.includes('ERROR') ? 'error' : line.includes('WARN') ? 'warn' : 'info';
    d.className = 'log-line ' + lvl;
    d.textContent = line;
    el.appendChild(d);
  });
  el.scrollTop = el.scrollHeight;
}

// ── File change ────────────────────────────────────────────────
function onFileChange(m) {
  addActivity({
    icon: m.event === 'created' ? '🆕' : m.event === 'deleted' ? '🗑️' : '✏️',
    text: `${m.event}: ${m.path}`, ts: m.ts
  });
  if (document.getElementById('panel-files').classList.contains('active')) loadTree();
  if (currentFile && m.path.endsWith(currentFile.split('/').pop())) loadFile(currentFile);
  if (document.getElementById('panel-diff').classList.contains('active')) loadDiff();
}

// ── File tree ──────────────────────────────────────────────────
async function loadTree() {
  const r = await fetch(api('/api/tree'));
  if (!r.ok) { handleHttpError(r.status, 'file tree'); return; }
  const data = await r.json();
  renderTree(data.files || []);
}
function renderTree(files) {
  const el = document.getElementById('file-tree');
  if (!files.length) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">📁</div><div class="empty-label">No files found</div></div>`;
    return;
  }
  el.innerHTML = '';
  renderItems(files, el, 0);
}
function renderItems(items, container, depth) {
  items.forEach(f => {
    if (f.type === 'dir') {
      const sec = document.createElement('div');
      sec.className = 'tree-dir';
      sec.style.paddingLeft = (16 + depth * 14) + 'px';
      sec.innerHTML = `<span>📁</span><span style="font-family:var(--mono);font-size:11px">${esc(f.name)}</span>`;
      container.appendChild(sec);
      if (f.children) renderItems(f.children, container, depth + 1);
    } else {
      const d = document.createElement('div');
      d.className = 'tree-item';
      d.style.paddingLeft = (16 + depth * 14) + 'px';
      d.onclick = () => loadFile(f.path);
      d.innerHTML = `
        <span class="tree-item-icon">📄</span>
        <span class="tree-item-name">${esc(f.name)}</span>
        ${f.modified ? '<span class="tree-item-modified">modified</span>' : ''}
        <span class="tree-item-size">${f.size || ''}</span>`;
      container.appendChild(d);
    }
  });
}

// ── File viewer ────────────────────────────────────────────────
async function loadFile(path) {
  currentFile = path;
  document.getElementById('viewer-fn').textContent = path;
  document.getElementById('viewer-body').textContent = 'Loading...';
  document.getElementById('viewer').classList.add('open');
  const r = await fetch(api('/api/file', '&path=' + encodeURIComponent(path)));
  if (!r.ok) { document.getElementById('viewer-body').textContent = `Error: HTTP ${r.status}`; return; }
  const d = await r.json();
  document.getElementById('viewer-body').textContent = d.content || d.error || '(empty)';
}
function closeViewer() { currentFile = null; document.getElementById('viewer').classList.remove('open'); }
async function dlFile() {
  if (!currentFile) return;
  const r = await fetch(api('/api/download', '&path=' + encodeURIComponent(currentFile)));
  const blob = await r.blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = currentFile.split('/').pop();
  a.click();
}

// ── Grep ───────────────────────────────────────────────────────
async function doGrep() {
  const q = document.getElementById('grep-input').value.trim();
  if (!q) { loadTree(); return; }
  const r = await fetch(api('/api/grep', '&q=' + encodeURIComponent(q)));
  if (!r.ok) { handleHttpError(r.status, 'search'); return; }
  const d = await r.json();
  const el = document.getElementById('file-tree');
  if (!(d.results || []).length) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">🔍</div><div class="empty-label">No results for "${esc(q)}"</div></div>`;
    return;
  }
  el.innerHTML = d.results.map(l =>
    `<div class="tree-item" style="cursor:default"><span class="tree-item-name" style="font-size:11px">${esc(l)}</span></div>`
  ).join('');
}

// ── Diff ───────────────────────────────────────────────────────
async function loadDiff() {
  const r = await fetch(api('/api/diff'));
  if (!r.ok) { handleHttpError(r.status, 'diff'); return; }
  const d = await r.json();
  renderDiff(d.diff || 'No changes.');
}
function renderDiff(diff) {
  const el = document.getElementById('diff-body');
  const lines = diff.split('\n');
  if (diff === 'No changes.' || !diff.trim()) {
    el.innerHTML = '<div class="diff-empty">✓ No uncommitted changes</div>';
    return;
  }
  el.innerHTML = lines.map(l => {
    if (l.startsWith('diff --git')) return `<div class="diff-file-header">${esc(l)}</div>`;
    if (l.startsWith('index ') || l.startsWith('--- ') || l.startsWith('+++ ')) return `<div class="diff-ctx" style="color:var(--text-faint)">${esc(l)}</div>`;
    if (l.startsWith('@@')) return `<div class="diff-hunk">${esc(l)}</div>`;
    if (l.startsWith('+')) return `<div class="diff-add">${esc(l)}</div>`;
    if (l.startsWith('-')) return `<div class="diff-del">${esc(l)}</div>`;
    return `<div class="diff-ctx">${esc(l)}</div>`;
  }).join('');
}

// ── Control ────────────────────────────────────────────────────
// BUG FIX #3: handle 403 explicitly with a clear toast
async function ctrl(action) {
  const btns = document.querySelectorAll('.ctrl-btn');
  btns.forEach(b => b.classList.add('loading'));
  try {
    const r = await fetch(api('/api/control'), {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action})
    });
    if (r.status === 403) {
      showToast('🔒 Invalid token — open the URL from the bot', 'error', 5000);
      return;
    }
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    if (data.ok) {
      const labels = {pause:'⏸ Paused', resume:'▶ Resumed', stop:'⏹ Stop sent', restart:'↺ Restarting...'};
      showToast(labels[action] || '✓ ' + action, 'success');
      if (action === 'pause') {
        paused = true;
        document.getElementById('btn-pause').style.display = 'none';
        document.getElementById('btn-resume').style.display = '';
      } else if (action === 'resume') {
        paused = false;
        document.getElementById('btn-resume').style.display = 'none';
        document.getElementById('btn-pause').style.display = '';
      }
    } else {
      showToast('⚠ ' + (data.error || 'Unknown error'), 'error');
    }
  } catch(e) {
    showToast('❌ ' + e.message, 'error');
  } finally {
    setTimeout(() => btns.forEach(b => b.classList.remove('loading')), 400);
  }
}

// ── HTTP error helper ──────────────────────────────────────────
function handleHttpError(status, context) {
  if (status === 403) {
    showToast(`🔒 Token invalid — open URL from bot (${context})`, 'error', 5000);
  } else {
    showToast(`❌ HTTP ${status} loading ${context}`, 'error');
  }
}

// ── Tabs ───────────────────────────────────────────────────────
function switchTab(name) {
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.getElementById('panel-' + name).classList.add('active');
  document.getElementById('tab-' + name).classList.add('active');
  if (name === 'diff') loadDiff();
  if (name === 'files') loadTree();
  if (name === 'logs') loadLog();
  if (name === 'terminal') {
    const f = document.getElementById('term-frame');
    if (!f.src || f.src === 'about:blank') f.src = api('/terminal');
  }
}

// ── Escape ─────────────────────────────────────────────────────
function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Init ───────────────────────────────────────────────────────
if (TOKEN) {
  loadTree(); loadLog(); loadDiff();
  connect();
}
</script>
</body>
</html>"""

# ── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not TOKEN:
        log.error("Could not generate token")
        sys.exit(1)

    host = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "0.0.0.0"
    log.info("Starting on %s:%s", host, PORT)
    log.info("Token: %s", TOKEN)

    uvicorn.run(
        app,
        host=host,
        port=PORT,
        log_level="warning",
        access_log=False,
    )
