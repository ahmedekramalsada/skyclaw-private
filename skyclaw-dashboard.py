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

# ── Tailscale IP ───────────────────────────────────────────────────────────

def get_tailscale_ip() -> str:
    try:
        r = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5)
        ip = r.stdout.strip()
        if ip:
            return ip
    except Exception:
        pass
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
        self.active.discard(ws) if hasattr(self.active, "discard") else None
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

            # Alert on critical lines
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
            # Fallback: check for PID file
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

def check_token(token: str = Query(default="")):
    if token != TOKEN:
        raise HTTPException(status_code=403, detail="Invalid token")

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
                "modified": (time.time() - mtime) < 300,  # modified in last 5 min
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
    if token != TOKEN:
        await websocket.close(code=4003)
        return
    await mgr.connect(websocket)
    # Send initial status on connect
    try:
        r = subprocess.run(["systemctl", "is-active", SERVICE_NAME], capture_output=True, text=True)
        alive = r.stdout.strip() == "active"
    except Exception:
        alive = False
    await websocket.send_json({"type": "status", "alive": alive})
    try:
        while True:
            await websocket.receive_text()  # keep alive / ping
    except WebSocketDisconnect:
        mgr.disconnect(websocket)

@app.get("/api/tree")
async def api_tree(token: str = Query(default="")):
    check_token(token)
    recent: set = set()
    # Find recently modified files from activity log
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
        # Send "stop" as a Telegram message to the bot (bot already handles it)
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
    # Serve an iframe pointing to ttyd
    host = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "localhost"
    ttyd_url = f"http://{host}:{TTYD_PORT}"
    html = f"""<!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{{margin:0;background:#0d1117}} iframe{{width:100%;height:100vh;border:none}}</style>
    </head><body>
    <iframe src="{ttyd_url}" allowfullscreen></iframe>
    </body></html>"""
    return HTMLResponse(html)

# ── Startup ─────────────────────────────────────────────────────────────────

@app.on_event("startup")
async def startup():
    loop = asyncio.get_event_loop()

    # File watcher
    handler = SkyclawFileHandler(loop)
    observer = Observer()
    observer.schedule(handler, str(SKYCLAW_DIR), recursive=True)
    if PROJECT_DIR.exists():
        observer.schedule(handler, str(PROJECT_DIR), recursive=True)
    observer.start()
    log.info("File watcher started on %s", SKYCLAW_DIR)

    # Background coroutines
    asyncio.create_task(tail_activity())
    asyncio.create_task(tail_journal())
    asyncio.create_task(poll_status())

    host = TAILSCALE_IP if TAILSCALE_IP != "0.0.0.0" else "your-server"
    url = f"http://{host}:{PORT}/dashboard?token={TOKEN}"
    log.info("Dashboard: %s", url)

    # Notify on Telegram
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
<meta name="theme-color" content="#0d1117">
<title>batabeto</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
html,body{height:100%;overflow:hidden;background:#0d1117;color:#e6edf3;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif}
/* Layout */
.app{display:flex;flex-direction:column;height:100vh;height:100dvh}
.header{display:flex;align-items:center;gap:8px;padding:10px 14px;background:#161b22;border-bottom:1px solid #30363d;flex-shrink:0;min-height:48px}
.content{flex:1;overflow:hidden;position:relative}
.tabbar{display:flex;background:#161b22;border-top:1px solid #30363d;flex-shrink:0;padding-bottom:env(safe-area-inset-bottom)}
/* Header */
.status-dot{width:9px;height:9px;border-radius:50%;background:#3fb950;flex-shrink:0;transition:background .3s}
.status-dot.dead{background:#f85149}
.h-title{font-size:15px;font-weight:600;flex:1}
.h-btn{background:#21262d;border:1px solid #30363d;color:#e6edf3;padding:6px 11px;border-radius:8px;font-size:13px;cursor:pointer;transition:background .15s;-webkit-user-select:none;user-select:none;touch-action:manipulation}
.h-btn:active{background:#30363d;transform:scale(.95)}
.h-btn.warn{border-color:#d29922;color:#d29922}
.h-btn.danger{border-color:#f85149;color:#f85149}
.h-btn.success{border-color:#3fb950;color:#3fb950}
.h-btn.busy{opacity:.5;pointer-events:none}
/* Toast */
.toast{position:fixed;top:60px;left:50%;transform:translateX(-50%);background:#21262d;border:1px solid #30363d;color:#e6edf3;padding:8px 18px;border-radius:8px;font-size:13px;z-index:100;opacity:0;transition:opacity .3s;pointer-events:none}
.toast.show{opacity:1}
/* Banner */
.banner{background:#f85149;color:#fff;text-align:center;padding:7px;font-size:13px;display:none;flex-shrink:0}
.banner.show{display:block}
/* Tab panels */
.panel{display:none;height:100%;overflow-y:auto;-webkit-overflow-scrolling:touch}
.panel.active{display:block}
/* Tab bar */
.tab{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:8px 4px;font-size:10px;color:#8b949e;cursor:pointer;border-top:2px solid transparent;gap:2px;min-height:52px}
.tab.active{color:#58a6ff;border-top-color:#58a6ff}
.tab-icon{font-size:20px;line-height:1}
/* Activity */
.a-item{display:flex;align-items:flex-start;gap:10px;padding:11px 14px;border-bottom:1px solid #1a1f27}
.a-icon{font-size:15px;flex-shrink:0;margin-top:1px}
.a-text{font-size:12px;font-family:'SF Mono',Monaco,Menlo,monospace;word-break:break-all;flex:1;color:#c9d1d9;line-height:1.5}
.a-time{font-size:10px;color:#8b949e;flex-shrink:0;margin-top:2px}
/* File tree */
.f-item{display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid #1a1f27;cursor:pointer;transition:background .1s}
.f-item:active{background:#21262d}
.f-name{font-size:13px;font-family:monospace;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.f-badge{font-size:10px;color:#f0883e;background:rgba(240,136,62,.1);border:1px solid rgba(240,136,62,.3);padding:1px 6px;border-radius:10px;flex-shrink:0}
.f-size{font-size:10px;color:#8b949e;flex-shrink:0}
.f-section{padding:8px 14px;font-size:10px;color:#8b949e;text-transform:uppercase;letter-spacing:.06em;background:#0d1117;position:sticky;top:0}
/* Code viewer */
.viewer{position:absolute;inset:0;background:#0d1117;z-index:10;flex-direction:column;display:none}
.viewer.open{display:flex}
.viewer-hdr{display:flex;align-items:center;gap:10px;padding:10px 14px;background:#161b22;border-bottom:1px solid #30363d;flex-shrink:0}
.viewer-back{font-size:22px;cursor:pointer;color:#58a6ff}
.viewer-fn{font-size:12px;font-family:monospace;flex:1;color:#8b949e;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.viewer-body{flex:1;overflow:auto;-webkit-overflow-scrolling:touch;padding:14px;font-family:'SF Mono',Monaco,Menlo,monospace;font-size:12px;line-height:1.7;white-space:pre;color:#e6edf3;tab-size:2}
/* Logs */
.log-line{padding:4px 14px;font-size:11px;font-family:monospace;border-bottom:1px solid #0f131a;word-break:break-all;line-height:1.5}
.log-line.error{color:#f85149;background:rgba(248,81,73,.06)}
.log-line.warn{color:#d29922;background:rgba(210,153,34,.04)}
/* Diff */
.diff-hunk{padding:8px 14px;font-size:12px;font-family:monospace;color:#58a6ff;border-bottom:1px solid #1a1f27}
.diff-add{padding:2px 14px;font-size:12px;font-family:monospace;background:rgba(63,185,80,.1);color:#3fb950;white-space:pre-wrap;word-break:break-all}
.diff-del{padding:2px 14px;font-size:12px;font-family:monospace;background:rgba(248,81,73,.1);color:#f85149;white-space:pre-wrap;word-break:break-all}
.diff-ctx{padding:2px 14px;font-size:12px;font-family:monospace;color:#8b949e;white-space:pre-wrap;word-break:break-all}
.diff-file{padding:10px 14px;font-size:12px;font-family:monospace;color:#e6edf3;background:#161b22;border-bottom:1px solid #30363d;font-weight:600}
/* Grep bar */
.search-bar{display:flex;gap:8px;padding:10px 14px;background:#161b22;border-bottom:1px solid #30363d;position:sticky;top:0;z-index:5}
.search-input{flex:1;background:#0d1117;border:1px solid #30363d;color:#e6edf3;padding:8px 10px;border-radius:8px;font-size:14px;outline:none}
.search-input:focus{border-color:#58a6ff}
.search-btn{background:#21262d;border:1px solid #30363d;color:#e6edf3;padding:8px 12px;border-radius:8px;font-size:13px;cursor:pointer}
/* Misc */
.empty{padding:40px 14px;text-align:center;color:#8b949e;font-size:14px}
.diff-toolbar{display:flex;gap:8px;padding:10px 14px;background:#161b22;border-bottom:1px solid #30363d}
</style>
</head>
<body>
<div class="app">

<!-- Reconnect banner -->
<div class="banner" id="banner">⚡ Reconnecting to server...</div>

<!-- Header -->
<div class="header">
  <div class="status-dot" id="dot"></div>
  <div class="h-title" id="h-title">batabeto</div>
  <button class="h-btn warn" id="btn-pause" onclick="ctrl('pause')">⏸</button>
  <button class="h-btn success" id="btn-resume" style="display:none" onclick="ctrl('resume')">▶</button>
  <button class="h-btn danger" onclick="ctrl('stop')">⏹</button>
  <button class="h-btn" onclick="ctrl('restart')" title="Restart service">🔄</button>
</div>

<!-- Content panels -->
<div class="content">

  <!-- Activity -->
  <div class="panel active" id="panel-activity">
    <div id="feed"><div class="empty">Waiting for bot activity...</div></div>
  </div>

  <!-- Files -->
  <div class="panel" id="panel-files">
    <div class="search-bar">
      <input class="search-input" id="grep-input" placeholder="Search in files..." onkeydown="if(event.key==='Enter')doGrep()">
      <button class="search-btn" onclick="doGrep()">⌕</button>
    </div>
    <div id="file-tree"><div class="empty">Loading...</div></div>
    <!-- File viewer overlay -->
    <div class="viewer" id="viewer">
      <div class="viewer-hdr">
        <span class="viewer-back" onclick="closeViewer()">←</span>
        <span class="viewer-fn" id="viewer-fn"></span>
        <button class="h-btn" onclick="dlFile()" style="font-size:11px;padding:5px 9px">⬇ Save</button>
      </div>
      <div class="viewer-body" id="viewer-body">Loading...</div>
    </div>
  </div>

  <!-- Logs -->
  <div class="panel" id="panel-logs">
    <div class="search-bar" style="gap:6px">
      <span style="font-size:12px;color:#8b949e;flex:1;padding:8px 2px">Live journal · errors highlighted</span>
      <button class="search-btn" onclick="loadLog()">↻</button>
      <button class="search-btn" onclick="clearLogs()">✕</button>
    </div>
    <div id="log-feed"><div class="empty">Waiting for logs...</div></div>
  </div>

  <!-- Diff -->
  <div class="panel" id="panel-diff">
    <div class="diff-toolbar">
      <button class="h-btn" onclick="loadDiff()" style="font-size:12px">↻ Refresh</button>
      <span style="font-size:12px;color:#8b949e;align-self:center">git diff HEAD</span>
    </div>
    <div id="diff-body"><div class="empty">Loading diff...</div></div>
  </div>

  <!-- Terminal -->
  <div class="panel" id="panel-terminal">
    <iframe id="term-frame" src="" style="width:100%;height:100%;border:none" title="Terminal"></iframe>
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
    <span class="tab-icon">⌨️</span>Terminal
  </div>
</div>

</div>

<script>
const TOKEN = new URLSearchParams(location.search).get('token')||'';
const api = p => `${location.origin}${p}?token=${TOKEN}`;
const wsProto = location.protocol==='https:'?'wss:':'ws:';
const wsUrl = `${wsProto}//${location.host}/ws?token=${TOKEN}`;

let ws, reconnTimer;
let feedCount=0, logCount=0;
let paused=false, currentFile=null;

// ── Toast helper ───────────────────────────────────────────────
let toastEl;
function showToast(msg, ms){
  if(!toastEl){toastEl=document.createElement('div');toastEl.className='toast';document.body.appendChild(toastEl);}
  toastEl.textContent=msg; toastEl.classList.add('show');
  clearTimeout(toastEl._t);
  toastEl._t=setTimeout(()=>toastEl.classList.remove('show'), ms||2500);
}

// ── WebSocket ──────────────────────────────────────────────────
function connect(){
  if(ws && (ws.readyState===WebSocket.CONNECTING||ws.readyState===WebSocket.OPEN)) return;
  try{ ws = new WebSocket(wsUrl); } catch(e){ scheduleReconnect(); return; }
  ws.onopen = ()=>{
    document.getElementById('banner').classList.remove('show');
    // Refresh all panels on reconnect
    loadTree(); loadDiff(); loadLog();
  };
  ws.onclose = ()=>{
    document.getElementById('banner').classList.add('show');
    scheduleReconnect();
  };
  ws.onerror = ()=>{}; // onclose will fire after onerror
  ws.onmessage = e => { try{handle(JSON.parse(e.data));}catch(err){} };
}
function scheduleReconnect(){
  clearTimeout(reconnTimer);
  reconnTimer = setTimeout(connect, 3000);
}
// Single keepalive interval (never duplicated)
setInterval(()=>{ if(ws && ws.readyState===1) ws.send('ping'); }, 25000);

function handle(m){
  if(m.type==='activity') addActivity(m);
  else if(m.type==='log') addLogLine(m);
  else if(m.type==='file_change') onFileChange(m);
  else if(m.type==='status') updateStatus(m);
}

// ── Status ─────────────────────────────────────────────────────
function updateStatus(m){
  const dot = document.getElementById('dot');
  const title = document.getElementById('h-title');
  dot.className = 'status-dot'+(m.alive?'':' dead');
  title.textContent = m.alive ? 'batabeto 🟢' : 'batabeto 🔴';
}

// ── Activity ───────────────────────────────────────────────────
function addActivity(m){
  const feed = document.getElementById('feed');
  if(feedCount===0) feed.innerHTML='';
  feedCount++;
  const t = new Date(m.ts*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  const d = document.createElement('div');
  d.className='a-item';
  d.innerHTML=`<span class="a-icon">${m.icon||'🔹'}</span><span class="a-text">${esc(m.text)}</span><span class="a-time">${t}</span>`;
  feed.insertBefore(d, feed.firstChild);
  while(feed.children.length>300) feed.removeChild(feed.lastChild);
}

// ── Log ────────────────────────────────────────────────────────
let logInit=false;
function addLogLine(m){
  const el = document.getElementById('log-feed');
  if(!logInit){ el.innerHTML=''; logInit=true; }
  logCount++;
  const d = document.createElement('div');
  const lvl = m.level||'';
  d.className='log-line'+(lvl==='ERROR'?' error':lvl==='WARN'?' warn':'');
  d.textContent = m.text;
  el.appendChild(d);
  if(document.getElementById('panel-logs').classList.contains('active'))
    el.scrollTop=el.scrollHeight;
  while(el.children.length>600) el.removeChild(el.firstChild);
}

function clearLogs(){ document.getElementById('log-feed').innerHTML=''; logInit=false; logCount=0; }

async function loadLog(){
  const r = await fetch(api('/api/log')+'&n=80');
  const data = await r.json();
  const el = document.getElementById('log-feed');
  el.innerHTML=''; logInit=true;
  (data.lines||[]).forEach(line=>{
    const d=document.createElement('div');
    const lvl = line.includes('ERROR')?'error':line.includes('WARN')?'warn':'';
    d.className='log-line'+(lvl?' '+lvl:'');
    d.textContent=line;
    el.appendChild(d);
  });
  el.scrollTop=el.scrollHeight;
}

// ── File change ────────────────────────────────────────────────
function onFileChange(m){
  addActivity({type:'activity',
    icon: m.event==='created'?'🆕':m.event==='deleted'?'🗑️':'✏️',
    text:`${m.event}: ${m.path}`, ts:m.ts});
  if(document.getElementById('panel-files').classList.contains('active')) loadTree();
  if(currentFile && m.path.endsWith(currentFile.split('/').pop())) loadFile(currentFile);
  if(document.getElementById('panel-diff').classList.contains('active')) loadDiff();
}

// ── File tree ──────────────────────────────────────────────────
async function loadTree(){
  const r = await fetch(api('/api/tree'));
  const data = await r.json();
  renderTree(data.files||[]);
}

function renderTree(files, depth=0){
  const el=document.getElementById('file-tree');
  el.innerHTML='';
  renderItems(files, el, depth);
}

function renderItems(items, container, depth){
  items.forEach(f=>{
    if(f.type==='dir'){
      const sec=document.createElement('div');
      sec.className='f-section';
      sec.style.paddingLeft=(14+depth*12)+'px';
      sec.textContent='📁 '+f.name;
      container.appendChild(sec);
      if(f.children) renderItems(f.children, container, depth+1);
    } else {
      const d=document.createElement('div');
      d.className='f-item';
      d.style.paddingLeft=(14+depth*12)+'px';
      d.onclick=()=>loadFile(f.path);
      d.innerHTML=`<span>📄</span><span class="f-name">${esc(f.name)}</span>${f.modified?'<span class="f-badge">modified</span>':''}<span class="f-size">${f.size||''}</span>`;
      container.appendChild(d);
    }
  });
}

// ── File viewer ────────────────────────────────────────────────
async function loadFile(path){
  currentFile=path;
  document.getElementById('viewer-fn').textContent=path;
  document.getElementById('viewer-body').textContent='Loading...';
  document.getElementById('viewer').classList.add('open');
  const r=await fetch(api('/api/file')+'&path='+encodeURIComponent(path));
  const d=await r.json();
  document.getElementById('viewer-body').textContent=d.content||d.error||'(empty)';
}
function closeViewer(){ currentFile=null; document.getElementById('viewer').classList.remove('open'); }
async function dlFile(){
  if(!currentFile)return;
  const r=await fetch(api('/api/download')+'&path='+encodeURIComponent(currentFile));
  const blob=await r.blob();
  const a=document.createElement('a');
  a.href=URL.createObjectURL(blob);
  a.download=currentFile.split('/').pop();
  a.click();
}

// ── Grep ───────────────────────────────────────────────────────
async function doGrep(){
  const q=document.getElementById('grep-input').value.trim();
  if(!q)return;
  const r=await fetch(api('/api/grep')+'&q='+encodeURIComponent(q));
  const d=await r.json();
  const el=document.getElementById('file-tree');
  if(!(d.results||[]).length){el.innerHTML='<div class="empty">No results for: '+esc(q)+'</div>';return;}
  el.innerHTML=d.results.map(l=>`<div class="f-item" style="cursor:default"><span class="f-name" style="font-family:monospace;font-size:12px">${esc(l)}</span></div>`).join('');
}

// ── Diff ───────────────────────────────────────────────────────
async function loadDiff(){
  const r=await fetch(api('/api/diff'));
  const d=await r.json();
  renderDiff(d.diff||'No changes.');
}
function renderDiff(diff){
  const el=document.getElementById('diff-body');
  const lines=diff.split('\n');
  el.innerHTML=lines.map(l=>{
    if(l.startsWith('diff --git')||l.startsWith('index ')||l.startsWith('--- ')||l.startsWith('+++ '))
      return `<div class="diff-file">${esc(l)}</div>`;
    if(l.startsWith('@@')) return `<div class="diff-hunk">${esc(l)}</div>`;
    if(l.startsWith('+')) return `<div class="diff-add">${esc(l)}</div>`;
    if(l.startsWith('-')) return `<div class="diff-del">${esc(l)}</div>`;
    return `<div class="diff-ctx">${esc(l)}</div>`;
  }).join('');
}

// ── Control ────────────────────────────────────────────────────
async function ctrl(action){
  // Visual feedback: disable button briefly
  const btns=document.querySelectorAll('.h-btn');
  btns.forEach(b=>b.classList.add('busy'));
  try{
    const r=await fetch(api('/api/control'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action})});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const data=await r.json();
    if(data.ok){
      showToast({pause:'⏸ Paused',resume:'▶ Resumed',stop:'⏹ Stop sent',restart:'🔄 Restarting...'}[action]||('✓ '+action));
    } else {
      showToast('⚠ '+( data.error||'Unknown error'));
    }
    if(action==='pause'){
      paused=true;
      document.getElementById('btn-pause').style.display='none';
      document.getElementById('btn-resume').style.display='';
    } else if(action==='resume'){
      paused=false;
      document.getElementById('btn-resume').style.display='none';
      document.getElementById('btn-pause').style.display='';
    }
  }catch(e){
    showToast('❌ Failed: '+e.message);
  }finally{
    setTimeout(()=>btns.forEach(b=>b.classList.remove('busy')),400);
  }
}

// ── Tabs ───────────────────────────────────────────────────────
function switchTab(name){
  document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  document.getElementById('panel-'+name).classList.add('active');
  document.getElementById('tab-'+name).classList.add('active');
  if(name==='diff') loadDiff();
  if(name==='files') loadTree();
  if(name==='logs') loadLog();
  if(name==='terminal'){
    const f=document.getElementById('term-frame');
    if(!f.src||f.src==='about:blank') f.src=api('/terminal');
  }
}

function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

// ── Init: load data immediately via REST, then connect WS for live updates ──
(function init(){
  loadTree(); loadLog(); loadDiff();
  connect();
})();
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
