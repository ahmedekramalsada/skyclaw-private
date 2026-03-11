# batabeto Heartbeat Checklist
# Runs every 15 minutes automatically.
# SILENT when everything is healthy — only send alerts on failures.
# All findings reported to Telegram with timestamps.
# ─────────────────────────────────────────────────────────────────────────────

## RULES
- Run ALL checks every time, even if one fails
- Only message the user if something needs attention
- If everything is healthy, respond with exactly: ✅ All systems healthy
- Format every alert as:
    🚨 ALERT: <title>
    Server: <hostname or "host">
    Issue: <what is wrong, with actual values>
    Action: <what you recommend>
- Group multiple alerts into one message — do not send separate messages per alert
- Include timestamp at the top of any alert message: 🕐 <time>

---

## CHECK 1 — DISK USAGE (host + remote servers)

Run on the host:
```
df -h --output=target,pcent / /var /tmp /home 2>/dev/null | grep -v Use
```

For each remote server you know about, run:
```
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> "df -h --output=target,pcent / /var /tmp 2>/dev/null | grep -v Use" 2>/dev/null
```

ALERT if: any partition is above 80% full
CRITICAL ALERT if: any partition is above 90% full

---

## CHECK 2 — KUBERNETES / K3S POD HEALTH

```
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -A --no-headers 2>/dev/null
```

ALERT if any pod is in state: CrashLoopBackOff, Error, OOMKilled, Evicted, Pending (>5 min), Unknown
Ignore: Completed (normal for jobs)

If a crashlooping pod is found, also run:
```
kubectl describe pod <name> -n <namespace> | tail -20
kubectl logs <name> -n <namespace> --previous --tail=20 2>/dev/null
```
Include last 5 lines of logs in the alert.

Check node health:
```
kubectl get nodes --no-headers 2>/dev/null
```
ALERT if any node is: NotReady, SchedulingDisabled

---

## CHECK 3 — RAM & CPU (host + remote servers)

Run on the host:
```
free -m | awk '/Mem:/ {used=$3; total=$2; pct=int(used*100/total); print "RAM: " used "MB used / " total "MB total (" pct "%)"}' 
top -bn1 | grep "Cpu(s)" | awk '{print "CPU: " $2 "% user, " $4 "% system"}'
```

For remote servers:
```
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> \
  "free -m | awk '/Mem:/ {used=\$3; total=\$2; pct=int(used*100/total); print \"RAM: \" used \"MB / \" total \"MB (\" pct \"%)\"}'  && top -bn1 | grep 'Cpu(s)' | awk '{print \"CPU: \" \$2 \"%\"}'" 2>/dev/null
```

ALERT if: RAM usage > 85% on any server
ALERT if: CPU usage > 90% sustained (check 3 times with 2s sleep before alerting)

---

## CHECK 4 — DOCKER CONTAINER HEALTH

```
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null
```

ALERT if any container status is: Exited, Restarting, Dead, OOM Killed
For a recently exited container, include last 10 log lines:
```
docker logs --tail=10 <container_name> 2>&1
```

Check for containers restarting too often:
```
docker ps --format "{{.Names}} {{.Status}}" | grep "Restarting"
```

---

## CHECK 5 — CRITICAL SERVICES

Check these services on the host:
```
for svc in nginx docker ssh; do
  systemctl is-active $svc > /dev/null 2>&1 && echo "$svc: running" || echo "$svc: STOPPED"
done
```

For remote servers, check their critical services via SSH:
```
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> \
  "systemctl is-active nginx 2>/dev/null || echo 'nginx: STOPPED'" 2>/dev/null
```

ALERT if: any critical service is stopped or inactive

---

## CHECK 6 — SSH REACHABILITY OF REMOTE SERVERS

For each known remote server:
```
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@<server> "echo ok" 2>/dev/null
```

ALERT if: a server that was previously reachable does not respond
Include: server name, last seen status

---

## HEALTHY RESPONSE FORMAT

If ALL checks pass with no issues:
```
✅ All systems healthy
```

Nothing else. No lists. No "I checked X". Silent is healthy.

---

## ALERT RESPONSE FORMAT

```
🕐 15:42 UTC — batabeto heartbeat

🚨 ALERT: High disk usage
Server: host
Issue: /var is at 87% (threshold: 80%)
Action: Run `du -sh /var/* | sort -rh | head -20` to find large files

🚨 ALERT: Pod crashlooping
Server: K3s cluster
Issue: api-deployment-7d9f8b-xkp2q in namespace production is CrashLoopBackOff
Logs: Error: cannot connect to database at postgres:5432
Action: Check postgres pod health and service endpoint

2 issues found. Waiting for your instructions.
```

---

## CHECK 7 — SELF-BACKUP

Run after every heartbeat check:
```bash
bash ~/.skyclaw/workspace/backup.sh
```

ALERT if backup script exits with error:
🚨 ALERT: Backup failed
Server: host
Issue: backup.sh returned non-zero exit
Action: Check GITHUB_TOKEN, GITHUB_USERNAME, GITHUB_BACKUP_REPO in ~/.skyclaw/.env

Do NOT alert if message is "No changes since last backup" — that is normal and healthy.
