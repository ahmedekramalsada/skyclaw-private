---
name: deployment
description: Deployment patterns for web apps, databases, monitoring stack, CI/CD pipelines, and custom scripts
capabilities: [deployments, web-apps, databases, grafana, prometheus, ci-cd, cron, docker, kubernetes, helm]
---

# Deployment Patterns

## RULES BEFORE ANY DEPLOYMENT
1. Always show what will change before changing it
2. Always verify health AFTER deploying — never just say "done"
3. Always store deployment result in memory: what version, when, any issues
4. If a deployment fails — do NOT retry blindly. Investigate first, report, then ask
5. Send real-time progress via send_message during long deploys

---

## WEB APPS & APIs

### Docker Compose App
```bash
cd /opt/<app>

# 1. Show current version
docker compose ps
git log --oneline -3

# 2. Pull latest image or code
git pull origin main
# OR if image-based:
docker compose pull

# 3. Show what changed
git log --oneline ORIG_HEAD..HEAD

# 4. Deploy
docker compose up -d --remove-orphans

# 5. Verify — wait for healthy
sleep 5
docker compose ps
docker logs --tail=20 <app-container>

# 6. HTTP health check
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:<port>/health
```

---

### Kubernetes App (manifest-based)
```bash
# 1. Apply manifests
kubectl apply -f /opt/<app>/k8s/ -n <namespace>

# 2. Watch rollout
kubectl rollout status deployment/<app> -n <namespace> --timeout=120s

# 3. Verify pods
kubectl get pods -n <namespace> -l app=<app>

# 4. Check logs of new pods
kubectl logs -n <namespace> -l app=<app> --tail=30 --since=2m

# 5. Service reachability
kubectl exec -n <namespace> deploy/<app> -- \
  wget -qO- http://localhost:<port>/health 2>/dev/null || \
  curl -s http://localhost:<port>/health
```

---

### Kubernetes App (Helm-based)
```bash
# 1. Show current release
helm list -n <namespace>
helm get values <release> -n <namespace>

# 2. Dry run — show diff
helm upgrade <release> <chart> -n <namespace> \
  --reuse-values \
  --set image.tag=<new-tag> \
  --dry-run 2>&1

# 3. Send dry-run output to user, wait for approval

# 4. Deploy
helm upgrade <release> <chart> -n <namespace> \
  --reuse-values \
  --set image.tag=<new-tag> \
  --atomic \           # auto-rollback if fails
  --timeout=120s

# 5. Verify
helm status <release> -n <namespace>
kubectl rollout status deploy/<release> -n <namespace>
```

---

### Systemd Service App
```bash
cd /opt/<app>

# 1. Pull
git fetch origin
git log --oneline HEAD..origin/main   # show what's coming

# 2. Wait for approval if changes are significant

# 3. Deploy
git pull origin main

# 4. Rebuild if needed (e.g. Go/Rust/Node binary)
# make build  OR  cargo build --release  OR  npm run build

# 5. Restart
systemctl restart <app>
sleep 3

# 6. Verify
systemctl is-active <app>
journalctl -u <app> --since "30 seconds ago" --no-pager | tail -20
curl -sf http://localhost:<port>/health && echo "healthy" || echo "UNHEALTHY"
```

---

## DATABASES

### PostgreSQL

#### Deploy / Upgrade (Docker)
```bash
# 1. Backup first — ALWAYS
docker exec <postgres-container> pg_dumpall -U postgres > /root/backups/pg_$(date +%Y%m%d_%H%M).sql
echo "Backup size: $(du -sh /root/backups/pg_*.sql | tail -1)"

# 2. Show user backup location, wait for confirmation before proceeding

# 3. Pull new image
docker compose pull postgres
docker compose up -d postgres

# 4. Verify
sleep 5
docker exec <postgres-container> pg_isready -U postgres
docker logs --tail=20 <postgres-container>
```

#### Health Check
```bash
docker exec <postgres-container> psql -U postgres -c "
SELECT
  datname,
  numbackends AS connections,
  pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_stat_database
WHERE datname NOT IN ('template0','template1')
ORDER BY pg_database_size(datname) DESC;"
```

#### On High Connection Count
```bash
docker exec <postgres-container> psql -U postgres -c "
SELECT count(*), state, wait_event_type
FROM pg_stat_activity
GROUP BY state, wait_event_type
ORDER BY count DESC;"
```

---

### Redis

#### Deploy / Upgrade (Docker)
```bash
# 1. Check current data
docker exec <redis-container> redis-cli info keyspace

# 2. Backup
docker exec <redis-container> redis-cli BGSAVE
sleep 3
docker cp <redis-container>:/data/dump.rdb /root/backups/redis_$(date +%Y%m%d_%H%M).rdb

# 3. Update
docker compose pull redis
docker compose up -d redis

# 4. Verify
docker exec <redis-container> redis-cli ping   # should return PONG
docker exec <redis-container> redis-cli info server | head -5
```

---

## MONITORING STACK

### Deploy Full Stack (Docker Compose)
```bash
cd /opt/monitoring   # or wherever your compose file lives

# 1. Show current versions
docker compose ps
grep "image:" docker-compose.yml

# 2. Pull latest images
docker compose pull

# 3. Show what will update, wait for approval

# 4. Deploy
docker compose up -d

# 5. Verify each component
sleep 10
echo "=== Prometheus ===" && curl -sf http://localhost:9090/-/healthy && echo " OK" || echo " FAILED"
echo "=== Grafana ===" && curl -sf http://localhost:3000/api/health && echo " OK" || echo " FAILED"
echo "=== Alertmanager ===" && curl -sf http://localhost:9093/-/healthy && echo " OK" || echo " FAILED"
```

---

### Grafana

#### Deploy / Update
```bash
# Docker
docker compose pull grafana
docker compose up -d grafana
sleep 5
curl -sf http://localhost:3000/api/health | python3 -m json.tool

# Systemd
systemctl restart grafana-server
systemctl is-active grafana-server
journalctl -u grafana-server --since "30 seconds ago" --no-pager
```

#### Add a Dashboard via API
```bash
curl -X POST http://admin:admin@localhost:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d @/opt/monitoring/dashboards/<dashboard>.json
```

---

### Prometheus

#### Deploy / Update
```bash
# Validate config FIRST
docker exec <prometheus-container> promtool check config /etc/prometheus/prometheus.yml
# OR systemd:
promtool check config /etc/prometheus/prometheus.yml

# Then restart
docker compose up -d prometheus
# OR
systemctl restart prometheus

# Verify targets
curl -s "http://localhost:9090/api/v1/targets" | \
  python3 -c "import sys,json; t=json.load(sys.stdin)['data']['activeTargets']; \
  [print(x['labels']['job'], x['health']) for x in t]"
```

---

## CI/CD PIPELINES

### GitHub Actions — Check & Trigger
```bash
# Check latest runs (requires gh CLI)
gh run list --limit=10
gh run view <run-id> --log

# Check workflow files
ls .github/workflows/
cat .github/workflows/<workflow>.yml

# Trigger manually
gh workflow run <workflow>.yml --ref main

# Watch run in real time
gh run watch <run-id>
```

---

### Self-hosted Runner — Health Check
```bash
# Check runner service
systemctl status actions.runner.*

# Runner logs
journalctl -u actions.runner.* --since "1 hour ago" --no-pager | tail -30

# List active jobs
ls /opt/actions-runner/_work/
```

---

### Deploy via Git Hook / Webhook
```bash
# Typical pattern on target server:
cd /opt/<app>
git pull origin main
systemctl restart <app>
curl -sf http://localhost:<port>/health

# Check webhook delivery (if using GitHub)
# gh api /repos/<owner>/<repo>/hooks/<hook-id>/deliveries --limit=5
```

---

## CUSTOM SCRIPTS & CRON JOBS

### Deploy a Script
```bash
# 1. Copy to scripts directory
cp /tmp/<script>.sh /opt/scripts/<script>.sh
chmod +x /opt/scripts/<script>.sh

# 2. Test run first
/opt/scripts/<script>.sh --dry-run 2>&1 | head -30

# 3. Add to cron (show user what will be added before adding)
echo "*/15 * * * * root /opt/scripts/<script>.sh >> /var/log/<script>.log 2>&1" \
  | tee /etc/cron.d/<script>

# 4. Verify cron entry
cat /etc/cron.d/<script>
```

### Check Cron Health
```bash
# Recent cron executions
grep CRON /var/log/syslog | tail -20
# OR
journalctl -u cron --since "1 hour ago" --no-pager | tail -20

# List all cron jobs
crontab -l
ls /etc/cron.d/
ls /etc/cron.daily/ /etc/cron.hourly/
```

### Script Log Rotation
```bash
cat > /etc/logrotate.d/<script> << 'EOF'
/var/log/<script>.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
EOF
```

---

## POST-DEPLOYMENT CHECKLIST

Run this after EVERY deployment and report results:

```bash
APP=<app-name>
PORT=<port>
NAMESPACE=<namespace>   # if K8s

echo "=== POST-DEPLOY HEALTH CHECK: $APP ==="

# 1. Process/Pod running?
systemctl is-active $APP 2>/dev/null || \
  kubectl get pods -n $NAMESPACE -l app=$APP --no-headers 2>/dev/null || \
  docker ps --filter name=$APP --format "{{.Status}}" 2>/dev/null

# 2. HTTP health endpoint
curl -sf -o /dev/null -w "Health endpoint: HTTP %{http_code}\n" \
  http://localhost:$PORT/health 2>/dev/null || echo "Health endpoint: not reachable"

# 3. No errors in recent logs?
journalctl -u $APP --since "1 minute ago" --no-pager 2>/dev/null | grep -i "error\|fatal\|panic" | head -5

# 4. Resource usage normal?
ps aux | grep $APP | grep -v grep | awk '{print "CPU: " $3 "% MEM: " $4 "%"}'

echo "=== CHECK COMPLETE ==="
```

---

## ROLLBACK PATTERNS

### Helm Rollback
```bash
helm history <release> -n <namespace>          # find last good revision
helm rollback <release> <revision> -n <namespace>
kubectl rollout status deploy/<release> -n <namespace>
```

### kubectl Rollback
```bash
kubectl rollout history deploy/<app> -n <namespace>
kubectl rollout undo deploy/<app> -n <namespace>
# OR to specific revision:
kubectl rollout undo deploy/<app> -n <namespace> --to-revision=<n>
```

### Git Rollback (systemd app)
```bash
git log --oneline -10                          # find last good commit
git checkout <commit-hash>
systemctl restart <app>
curl -sf http://localhost:<port>/health
```

### Docker Image Rollback
```bash
# Find previous image tag
docker image ls <image-name>
# Update compose to previous tag, redeploy
sed -i 's|image:.*|image: <image>:<previous-tag>|' docker-compose.yml
docker compose up -d
```
