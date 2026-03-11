---
name: devops-core
description: Core DevOps knowledge — SSH multi-server control, kubectl, helm, terraform, ansible, docker workflows
capabilities: [kubernetes, helm, terraform, ansible, docker, ssh, deployments, infrastructure]
---

# DevOps Core Skill

## SERVER INVENTORY
<!-- batabeto auto-populates this from memory as you tell it about your servers -->
<!-- Send: "Remember: server1 is at 10.0.0.5, root user, runs Nginx + my-api" -->
<!-- batabeto will store it and use it automatically in every task -->

When user mentions a server, ALWAYS store it in memory immediately:
```
memory_manage("remember: server <name> — IP: <ip> — user: <ssh_user> — runs: <services>")
```

SSH connection pattern for all remote commands:
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    -i /root/.ssh/batabeto <user>@<host> '<command>'
```

Run commands on ALL known servers in parallel:
```bash
for server in server1 server2 server3; do
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /root/.ssh/batabeto root@$server \
    '<command>' 2>/dev/null &
done
wait
```

---

## KUBECTL / K3S

### Setup
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # K3s default
# Multi-cluster: export KUBECONFIG=/root/.kube/config
```

### Daily Operations
```bash
# Overview
kubectl get pods -A                             # all pods all namespaces
kubectl get nodes -o wide                       # node status + IPs
kubectl get svc -A                              # all services
kubectl get ingress -A                          # all ingresses
kubectl top pods -A --sort-by=cpu              # resource usage

# Pod debugging
kubectl describe pod <name> -n <ns>            # full details + events
kubectl logs <name> -n <ns> --tail=100         # current logs
kubectl logs <name> -n <ns> --previous         # crashed container logs
kubectl logs <name> -n <ns> -f                 # follow logs
kubectl exec -it <name> -n <ns> -- /bin/sh     # shell into pod

# Deployments
kubectl get deploy -A                           # all deployments
kubectl rollout status deploy/<n> -n <ns>       # rollout progress
kubectl rollout history deploy/<n> -n <ns>      # revision history
kubectl rollout restart deploy/<n> -n <ns>      # safe rolling restart
kubectl rollout undo deploy/<n> -n <ns>         # rollback to previous

# Scaling
kubectl scale deploy/<n> --replicas=3 -n <ns>  # scale deployment

# Events — most useful for debugging
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -30
kubectl get events -A --sort-by='.lastTimestamp' | grep -i "warning\|error" | tail -20

# Resource cleanup
kubectl delete pod <name> -n <ns>              # force reschedule
```

### ALWAYS ask before:
- `kubectl delete` anything other than a crashed pod
- `kubectl apply` changes to production
- Editing configmaps or secrets in production

---

## HELM

### Discovery
```bash
helm list -A                                    # all releases all namespaces
helm list -n <namespace>                        # releases in namespace
helm history <release> -n <ns>                 # full upgrade history
helm status <release> -n <ns>                  # current status
helm get values <release> -n <ns>              # current values
helm get manifest <release> -n <ns>            # rendered manifests
```

### Safe Upgrade Workflow
```bash
# 1. Show current values FIRST
helm get values <release> -n <ns>

# 2. Dry run — show what will change
helm upgrade <release> <chart> -n <ns> --reuse-values --dry-run --debug

# 3. Send diff to user, wait for confirmation

# 4. Apply
helm upgrade <release> <chart> -n <ns> --reuse-values

# 5. Watch rollout
kubectl rollout status deploy/<release> -n <ns>
```

### Rollback
```bash
helm history <release> -n <ns>                 # find target revision
helm rollback <release> <revision> -n <ns>     # rollback
kubectl rollout status deploy/<release> -n <ns> # verify
```

### Install new chart
```bash
helm repo add <name> <url>
helm repo update
helm search repo <name>
helm show values <chart>                        # inspect defaults
helm install <release> <chart> -n <ns> --create-namespace -f values.yaml
```

---

## TERRAFORM

### MANDATORY WORKFLOW — never skip any step
```bash
# 1. Navigate to workspace
cd $TERRAFORM_ROOT/<workspace>

# 2. Init (first time or after provider changes)
terraform init

# 3. ALWAYS plan first — send full output to user
terraform plan -out=tfplan

# 4. STOP — send plan to user and WAIT for explicit approval
#    Valid approvals: "yes", "apply", "go ahead", "do it"
#    If user says anything else — do NOT apply

# 5. Only after approval:
terraform apply tfplan

# 6. Report outputs
terraform output
```

### Inspection (safe — read only)
```bash
terraform show                                  # current state
terraform state list                            # all resources
terraform state show <resource>                 # specific resource
terraform plan                                  # what would change
```

### NEVER run without explicit user confirmation:
- `terraform apply`
- `terraform destroy`
- `terraform state rm`
- `terraform import`

For `terraform destroy` — require the user to say "destroy" AND confirm a second time.

---

## ANSIBLE

### Ad-hoc Commands
```bash
# Ping all hosts
ansible all -i $ANSIBLE_INVENTORY -m ping

# Run shell command on all hosts
ansible all -i $ANSIBLE_INVENTORY -m shell -a 'uptime'

# Run on specific group
ansible webservers -i $ANSIBLE_INVENTORY -m shell -a 'systemctl status nginx'

# Copy a file
ansible all -i $ANSIBLE_INVENTORY -m copy -a 'src=/local/file dest=/remote/path'

# Gather facts
ansible <host> -i $ANSIBLE_INVENTORY -m setup
```

### Playbook Execution
```bash
# Always use -v for output visibility
ansible-playbook -v -i $ANSIBLE_INVENTORY $ANSIBLE_PLAYBOOKS_DIR/<playbook>.yml

# Dry run first (check mode)
ansible-playbook --check -i $ANSIBLE_INVENTORY $ANSIBLE_PLAYBOOKS_DIR/<playbook>.yml

# Limit to specific host
ansible-playbook -v -i $ANSIBLE_INVENTORY <playbook>.yml --limit server1

# Pass extra variables
ansible-playbook -v -i $ANSIBLE_INVENTORY <playbook>.yml -e "version=1.2.3"

# Step through tasks interactively
ansible-playbook -v -i $ANSIBLE_INVENTORY <playbook>.yml --step
```

### Before any destructive playbook:
1. Run with `--check` first and show output to user
2. Confirm with user before running for real
3. Send progress updates via send_message during long runs

---

## DOCKER

### Container Management
```bash
# Status
docker ps -a                                    # all containers
docker stats --no-stream                        # resource usage snapshot
docker system df                                # disk usage

# Logs
docker logs --tail=100 --timestamps <name>      # recent logs
docker logs --since=1h <name>                   # last 1 hour
docker logs -f <name>                           # follow

# Control
docker restart <name>                           # graceful restart
docker stop <name> && docker start <name>       # stop then start

# Inspect
docker inspect <name>                           # full config
docker exec -it <name> /bin/sh                 # shell into container
docker exec <name> env                          # check environment vars
```

### Docker Compose
```bash
# Navigate to compose file location first
cd /path/to/compose

docker compose ps                               # service status
docker compose logs --tail=50 <service>        # service logs
docker compose up -d                            # start all services
docker compose up -d <service>                 # restart specific service
docker compose down                             # stop all
docker compose pull && docker compose up -d    # update images

# Check compose config
docker compose config                           # validate and show merged config
```

### Cleanup (ALWAYS ask before running these)
```bash
docker system prune -f                          # remove stopped containers + dangling images
docker volume prune -f                          # remove unused volumes
docker image prune -a -f                        # remove all unused images
```

---

## DEPLOYMENT WORKFLOWS

### Standard App Deployment
```bash
# 1. Pull latest
cd /opt/<app>
git fetch origin
git log --oneline HEAD..origin/main             # show what will change

# 2. Show changes to user, wait for go-ahead

# 3. Pull and restart
git pull origin main
systemctl restart <app-service>

# 4. Verify
sleep 3
systemctl is-active <app-service>
curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/health
```

### K8s Rolling Deployment
```bash
# 1. Update image
kubectl set image deploy/<n> <container>=<image>:<tag> -n <ns>

# 2. Watch rollout
kubectl rollout status deploy/<n> -n <ns>

# 3. Verify pods
kubectl get pods -n <ns> -l app=<n>

# 4. Quick smoke test
kubectl exec -n <ns> deploy/<n> -- curl -s localhost:<port>/health
```

### Helm Chart Deployment
```bash
# 1. Show current values
helm get values <release> -n <ns>

# 2. Upgrade with new values
helm upgrade <release> <chart> -n <ns> -f values.yaml --reuse-values

# 3. Watch
kubectl rollout status deploy/<release> -n <ns>

# 4. Verify
helm status <release> -n <ns>
```

---

## MONITORING STACK

### Grafana
```bash
# Check status
systemctl status grafana-server
# or Docker:
docker ps | grep grafana
docker logs --tail=30 grafana

# Access logs
journalctl -u grafana-server --since "1 hour ago" --no-pager
```

### Prometheus
```bash
# Check status
systemctl status prometheus
# or Docker:
docker ps | grep prometheus
docker logs --tail=30 prometheus

# Query via CLI
curl -s "http://localhost:9090/api/v1/query?query=up" | python3 -m json.tool
curl -s "http://localhost:9090/-/healthy"
curl -s "http://localhost:9090/-/ready"
```

### Check all monitoring services at once
```bash
for svc in grafana prometheus alertmanager node-exporter; do
  status=$(systemctl is-active $svc 2>/dev/null || docker inspect --format='{{.State.Status}}' $svc 2>/dev/null || echo "not found")
  echo "$svc: $status"
done
```

---

## CI/CD PATTERNS

### GitHub Actions Triggered Deploy
When user says "deploy from GitHub" or "run the pipeline":
```bash
# Check latest pipeline status via gh CLI (if installed)
gh run list --limit=5
gh run view <run-id>

# Or check via git
git fetch origin
git log --oneline origin/main | head -10
```

### Check if deploy is needed
```bash
cd /opt/<app>
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
  echo "Update available: $LOCAL -> $REMOTE"
  git log --oneline $LOCAL..$REMOTE
fi
```

---

## QUICK REFERENCE — MOST USED COMMANDS

```bash
# Full cluster health in one shot
kubectl get pods -A | grep -v "Running\|Completed"   # unhealthy pods
kubectl get nodes                                      # node status
helm list -A                                           # helm releases
docker ps -a | grep -v "Up"                           # stopped containers
df -h | awk '$5+0 > 75'                               # partitions >75% full
free -m                                                # memory
```
