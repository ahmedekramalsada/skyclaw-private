---
name: incident-response
description: How batabeto handles failures, alerts, and incidents on any server or cluster
capabilities: [incident, alerting, debugging, recovery, kubernetes, docker, ssh]
---

# Incident Response Playbook

## GOLDEN RULES
- NEVER silently fix something. Always tell the user what you found AND what you did.
- NEVER restart a service or delete a resource without reporting first.
- ALWAYS show logs and root cause before suggesting a fix.
- If unsure — report findings and wait for instructions. Do not guess-fix production.
- Speed matters. Start investigating immediately, send partial findings via send_message.

---

## PHASE 1 — IMMEDIATE TRIAGE (first 60 seconds)

When an alert fires or user reports an issue, do this immediately:

```
1. Acknowledge: send_message("🔍 Investigating: <issue>. Checking now...")
2. Identify scope: is it one service, one server, whole cluster?
3. Check if it's still happening or already recovered
4. Gather the 3 key facts: WHAT failed, WHEN it started, WHAT changed recently
```

---

## PHASE 2 — INVESTIGATION BY TYPE

### 🔴 Pod CrashLoopBackOff

```bash
# Step 1: Get the full picture
kubectl get pods -n <namespace> -o wide

# Step 2: Describe — look at Events section at the bottom
kubectl describe pod <pod-name> -n <namespace>

# Step 3: Current logs
kubectl logs <pod-name> -n <namespace> --tail=50

# Step 4: Previous container logs (the crashed instance)
kubectl logs <pod-name> -n <namespace> --previous --tail=50

# Step 5: Check if it's a config issue
kubectl get configmap -n <namespace>
kubectl get secret -n <namespace>

# Step 6: Check resource limits
kubectl top pod <pod-name> -n <namespace> 2>/dev/null
```

Report: pod name, namespace, error from logs, last event, restart count.
Ask user before: exec into pod, delete pod, change resource limits.

---

### 🔴 Service Down / Not Responding

```bash
# Step 1: Is the process running?
systemctl status <service>
# or for Docker:
docker ps -a | grep <service>

# Step 2: Recent logs
journalctl -u <service> --since "10 minutes ago" --no-pager
# or Docker:
docker logs --tail=50 --timestamps <container>

# Step 3: Port listening?
ss -tlnp | grep <port>

# Step 4: Any recent config changes?
git -C /etc/<service> log --oneline -5 2>/dev/null

# Step 5: System resources — is it OOM?
dmesg | tail -20 | grep -i "kill\|oom\|out of memory"
free -m
```

Report: service status, last error from logs, port status, OOM indicators.

---

### 🔴 High Disk Usage

```bash
# Step 1: Which partition is full?
df -h

# Step 2: Find the biggest directories
du -sh /* 2>/dev/null | sort -rh | head -20

# Step 3: Drill into the culprit
du -sh /var/* 2>/dev/null | sort -rh | head -10
du -sh /var/log/* 2>/dev/null | sort -rh | head -10

# Step 4: Find large files
find / -type f -size +500M 2>/dev/null | head -20

# Step 5: Docker eating space?
docker system df 2>/dev/null
```

Report: which partition, what's eating space, size of top offenders.
Safe to do WITHOUT asking: show findings.
Ask before doing: delete files, prune Docker, rotate logs.

---

### 🔴 High CPU / Memory

```bash
# Step 1: Who is using CPU?
top -bn1 | head -20
ps aux --sort=-%cpu | head -15

# Step 2: Who is using memory?
ps aux --sort=-%mem | head -15
free -m

# Step 3: Is it a known service gone rogue?
systemctl status <suspected-service>

# Step 4: Kubernetes — which pod?
kubectl top pods -A --sort-by=cpu 2>/dev/null | head -10
kubectl top pods -A --sort-by=memory 2>/dev/null | head -10

# Step 5: Is there a memory leak? (check growth over time)
watch -n5 'ps aux --sort=-%mem | head -10'   # run for 30s with shell sleep loop
```

Report: top 5 processes by CPU and memory, is it growing, which service.

---

### 🔴 Node NotReady

```bash
# Step 1: Node status
kubectl get nodes -o wide

# Step 2: Node details
kubectl describe node <node-name>

# Step 3: SSH into the node and check
ssh -o StrictHostKeyChecking=no -i /root/.ssh/batabeto root@<node-ip> \
  "systemctl status k3s 2>/dev/null || systemctl status kubelet 2>/dev/null"

# Step 4: K3s agent logs on the node
ssh -o StrictHostKeyChecking=no -i /root/.ssh/batabeto root@<node-ip> \
  "journalctl -u k3s-agent --since '15 minutes ago' --no-pager | tail -30"

# Step 5: Network reachability
ping -c3 <node-ip>
```

Report: node status, events from describe, k3s/kubelet status on node.

---

### 🔴 Server Unreachable via SSH

```bash
# Step 1: Is it a network issue or server down?
ping -c3 <server-ip>

# Step 2: Try alternate port
ssh -p 22 -o ConnectTimeout=5 root@<server-ip> "echo ok" 2>&1

# Step 3: Check from another server
ssh -o StrictHostKeyChecking=no root@<other-server> "ping -c3 <target-ip>" 2>/dev/null

# Step 4: Check if it's a known maintenance window
# (check your memory for any scheduled downtime)
```

Report: ping results, last known good time from memory, whether other servers can reach it.

---

### 🔴 Deployment Failed

```bash
# Step 1: What is the current state?
kubectl rollout status deployment/<name> -n <namespace>

# Step 2: Rollout history
kubectl rollout history deployment/<name> -n <namespace>

# Step 3: Events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# Step 4: Helm — check release status
helm list -n <namespace>
helm status <release> -n <namespace>
helm history <release> -n <namespace>
```

Safe to do WITHOUT asking: investigate, show status, show history.
ALWAYS ask before: helm rollback, kubectl rollout undo.
Show exact command you will run BEFORE running it.

---

## PHASE 3 — REPORTING FORMAT

Every incident report must include:

```
🚨 INCIDENT REPORT
Time: <timestamp>
Severity: LOW | MEDIUM | HIGH | CRITICAL

WHAT: <one line description>
WHERE: <server/cluster/namespace>
SINCE: <when it started or was first detected>

FINDINGS:
• <finding 1 with actual values>
• <finding 2>
• <relevant log lines>

ROOT CAUSE: <your assessment, or "Unknown — need more investigation">

RECOMMENDED ACTION:
• Option A: <safe/quick fix>
• Option B: <more thorough fix>

Waiting for your go-ahead.
```

---

## PHASE 4 — AFTER THE FIX

After any fix is applied:
```bash
# 1. Verify the fix worked
kubectl get pods -n <namespace>   # pods should be Running
systemctl is-active <service>     # should return "active"
curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/health  # should return 200

# 2. Watch for recurrence (30 seconds)
# Use shell sleep loop + send_message to report "still healthy" or "recurred"

# 3. Update memory with what happened
memory_manage("remember: <date> incident on <server> — <what happened> — fixed by <action>")
```

---

## SEVERITY LEVELS

| Level | Examples | Response |
|-------|----------|----------|
| 🔵 LOW | Disk at 81%, 1 pod restarted once | Report in next heartbeat |
| 🟡 MEDIUM | Service degraded, non-critical pod down | Alert immediately, investigate |
| 🔴 HIGH | Production service down, DB unavailable | Alert immediately, full investigation |
| ⚫ CRITICAL | Full cluster down, data loss risk | Alert immediately, call to action |
