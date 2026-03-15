# batabeto Heartbeat Checklist
# Runs every 15 minutes automatically.
# SILENT when everything is healthy — only message X on failures or reminders.
# ─────────────────────────────────────────────────────────────────────────────

## RULES
- Run ALL checks every time, even if one fails
- Only message X if something needs attention OR a reminder fires (see CHECK 8)
- If everything is healthy and no reminders: respond with exactly: ✅ All systems healthy
- Cairo time: TZ=Africa/Cairo date +"%H:%M %Z" — use this for all timestamps
- Group all alerts into ONE message — never send separate messages per alert
- Alert format:
    🚨 ALERT: <title>
    Server: <hostname or "host">
    Issue: <what is wrong, with actual values>
    Action: <specific fix — include the exact command if there is one>

---

## CHECK 1 — DISK USAGE (host + remote servers)

```bash
df -h --output=target,pcent / /var /tmp /home 2>/dev/null | grep -v Use
```

For each remote server in memory (recall tags=["servers"]):
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> \
  "df -h --output=target,pcent / /var /tmp 2>/dev/null | grep -v Use" 2>/dev/null
```

ALERT if: any partition > 80%
CRITICAL ALERT if: any partition > 90% — include top 5 dirs eating space:
```bash
du -sh /* 2>/dev/null | sort -rh | head -5
```

---

## CHECK 2 — DOCKER CONTAINER HEALTH

```bash
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null
```

ALERT if any container is: Exited, Restarting, Dead, OOM Killed
For each unhealthy container, include last 10 log lines:
```bash
docker logs --tail=10 <container_name> 2>&1
```

Check for containers restarting too often:
```bash
docker ps --format "{{.Names}} {{.Status}}" | grep "Restarting"
```

ALERT if: any container has restarted more than 3 times in its status line.

---

## CHECK 3 — KUBERNETES / K3S POD HEALTH

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -A --no-headers 2>/dev/null
```

ALERT if any pod is: CrashLoopBackOff, Error, OOMKilled, Evicted, Unknown, Pending (>5 min)
Ignore: Completed (normal for jobs)

For crashlooping pods, also get:
```bash
kubectl describe pod <n> -n <namespace> | tail -20
kubectl logs <n> -n <namespace> --previous --tail=20 2>/dev/null
```
Include last 5 log lines in the alert.

Check node health:
```bash
kubectl get nodes --no-headers 2>/dev/null
```
ALERT if any node is: NotReady, SchedulingDisabled

---

## CHECK 4 — RAM & CPU (host)

```bash
free -m | awk '/Mem:/ {used=$3; total=$2; pct=int(used*100/total); print "RAM: " used "MB / " total "MB (" pct "%)"}'
```

CPU — read /proc/stat twice 200ms apart for accuracy:
```bash
read cpu a b c idle1 rest < /proc/stat; sleep 0.2
read cpu a b c idle2 rest < /proc/stat
echo "CPU: $((100 - (idle2-idle1) * 100 / ( (idle2-idle1) + (a+b+c - (idle2-idle1)) ) ))% used" 2>/dev/null || \
  top -bn1 | grep "Cpu(s)" | awk '{print "CPU: " $2 "%"}'
```

ALERT if: RAM > 85%
ALERT if: CPU > 90% — include top 5 processes:
```bash
ps aux --sort=-%cpu | head -6 | tail -5
```

---

## CHECK 5 — CRITICAL SERVICES

```bash
for svc in nginx docker ssh skyclaw; do
  systemctl is-active $svc > /dev/null 2>&1 && echo "$svc: ✅" || echo "$svc: ❌ STOPPED"
done
```

ALERT if: nginx, docker, ssh, or skyclaw is stopped.
For skyclaw specifically: if stopped, include last 20 log lines:
```bash
journalctl -u skyclaw --since "5 minutes ago" --no-pager | tail -20
```

---

## CHECK 6 — SSH REACHABILITY OF REMOTE SERVERS

For each known server (recall tags=["servers"]):
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> "echo ok" 2>/dev/null
```

ALERT if a previously reachable server does not respond.
Include: server name/IP, last seen time from memory.

---

## CHECK 7 — SELF-BACKUP

```bash
bash ~/.skyclaw/workspace/backup.sh
```

ALERT if backup exits with error:
```
🚨 ALERT: Backup failed
Issue: backup.sh returned non-zero exit
Action: Check GITHUB_TOKEN, GITHUB_USERNAME, GITHUB_BACKUP_REPO in ~/.skyclaw/.env
Command: cat ~/.skyclaw/.env | grep GITHUB
```

"No changes since last backup" = healthy, do NOT alert.

---

## CHECK 8 — STUDY & PROJECT REMINDERS (runs every 4th heartbeat = ~1 hour)

Track heartbeat count in a temp file:
```bash
HB_COUNT_FILE=~/.skyclaw/.hb_count
count=$(cat $HB_COUNT_FILE 2>/dev/null || echo 0)
count=$((count + 1))
echo $count > $HB_COUNT_FILE
```

Only run this check when count % 4 == 0 (every ~1 hour).

Recall active goals and study progress:
```
memory_manage: action=recall, query="current goals projects study", tags=["projects","study"], scope=global
```

If memory has active items AND the last reminder was more than 4 hours ago:
Send a reminder message to X:

```
📌 Hourly check-in

🎯 Active projects:
• <project 1 — current status from memory>
• <project 2 — current status from memory>

📚 Study progress:
• <what X is learning — last covered topic from memory>
• Next: <what's next from memory>

Need me to continue anything?
BUTTONS: 🚀 Continue project | 📚 Study session | ❌ Not now
```

Rules:
- Only send reminder if memory has active projects or study items
- If memory is empty: skip silently
- If X responded to last reminder with "Not now" — wait 2 hours before next reminder
- Never send reminder between 23:00 and 08:00 Cairo time

---

## HEALTHY RESPONSE FORMAT

If ALL checks pass and no reminders fire:
```
✅ All systems healthy
```

Nothing else. Silent is healthy.

---

## ALERT RESPONSE FORMAT

```
🕐 14:23 EET — batabeto heartbeat

🚨 ALERT: Container down
Server: host
Issue: my-api container Exited (1) 3 minutes ago
Logs: Error: ECONNREFUSED connecting to postgres:5432
Action: docker start my-api — but check postgres first: docker ps | grep postgres

🚨 ALERT: Disk usage critical
Server: host
Issue: / is at 91% (threshold: 90%)
Action: du -sh /* 2>/dev/null | sort -rh | head -10

2 issues found. Waiting for your instructions.
BUTTONS: 🔧 Fix automatically | 👁 Show more details | ✏️ Other
```
