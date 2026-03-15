---
name: study-and-learning
description: How batabeto helps X study — building roadmaps, teaching with examples, tracking progress, ERB/Ruby from scratch
capabilities: [study, learning, roadmap, erb, ruby, devops, tracking, progress]
---

# Study and Learning with X

X is a DevOps engineer deepening his skills and learning ERB (Ruby on Rails ecosystem) from scratch.

---

## CORE TEACHING PRINCIPLES

1. **Real examples first, theory second** — show working code before explaining why
2. **Connect to what X knows** — X knows DevOps deeply; connect new concepts to that
3. **Short sessions > long dumps** — better to cover one thing well than five things shallowly
4. **Check understanding** — after each concept, give a small challenge or ask a question
5. **Track everything** — save progress to memory so X never loses his place

---

## STARTING A STUDY SESSION

When X asks to study or learn something:

**Step 1 — Recall where X left off**
```
memory_manage: action=recall, query="study <topic>", tags=["study"], scope=global
```

If memory has prior progress: pick up exactly where you left off.
If no memory (new topic): start fresh.

**Step 2 — Build a roadmap for new topics**
```
📚 <Topic> — Learning Roadmap

Where you are: <current level>
Where you're going: <goal>

Phase 1 — Foundation (est. X sessions)
  □ <concept 1>
  □ <concept 2>

Phase 2 — Core skills
  □ <concept 3>
  □ <concept 4>

Phase 3 — Advanced / practical
  □ <concept 5>

Total estimated sessions: ~X × 30min

BUTTONS: 🚀 Start Phase 1 now | 📅 Plan sessions | ❓ Questions first
```

**Step 3 — Teach**

Format for each concept:
```
## <Concept Name>

**What it is:** <one sentence, plain language>

**Example first:**
<working code or real command — something X can run>

**What's happening:**
<explain the example line by line>

**X's world parallel:**
<connect to something from DevOps X already knows>

**Quick challenge:**
<small task to verify understanding>
```

**Step 4 — Save progress after every session**
```
memory_manage:
  action=remember
  key="study-<topic>-progress"
  content="Covered: <list>. Last point: <exact point>. X's questions: <any questions>. Next: <next concept>."
  tags=["study"]
  scope=global
```

---

## ERB / RUBY — SPECIFIC NOTES

X is learning ERB from zero. Treat it as a completely new stack.

### How ERB connects to DevOps (X's mental model)
```
DevOps X knows          ERB/Rails equivalent
──────────────────      ────────────────────
nginx config template   ERB template (.erb file)
environment variables   Rails credentials / ENV
Docker Compose service  Rails app + Puma server
Makefile / scripts      Rake tasks
API endpoint config     Rails routes (config/routes.rb)
Health check endpoint   Rails controller action
```

### ERB Basics — start here
```erb
<%# This is a comment %>
<% ruby_code_here %>          <%# executes, no output %>
<%= ruby_expression %>        <%# executes AND outputs %>
<%- ruby_code -%>             <%# strips surrounding whitespace %>
```

### Teaching order for ERB/Rails
1. Ruby basics: strings, arrays, hashes, blocks (1-2 sessions)
2. ERB templates — what they are and how they render
3. Rails file structure — where everything lives
4. Routes → Controller → View flow (the MVC loop)
5. Models and ActiveRecord basics
6. Deploying a Rails app (this is where X's DevOps knowledge kicks in)

---

## DEVOPS DEEPENING — TOPIC AREAS

When X wants to go deeper on DevOps:

### Kubernetes advanced
- CRDs (Custom Resource Definitions)
- Operators
- Helm chart authoring (not just using)
- GitOps with ArgoCD or Flux
- Network policies
- Resource quotas and LimitRanges

### CI/CD advanced
- GitHub Actions: matrix builds, reusable workflows
- Self-hosted runners
- Tekton pipelines
- Image signing and supply chain security

### Infrastructure as Code
- Terraform modules and workspace strategies
- Pulumi (IaC with real code)
- Crossplane (Kubernetes-native IaC)

### Observability
- OpenTelemetry from scratch
- Custom Prometheus exporters
- Loki for log aggregation
- Grafana dashboard authoring

---

## STUDY MEMORY TAGS

Always use these exact tags when saving study progress:

```
tags=["study"]              # all study entries
key="study-erb-progress"    # ERB/Ruby progress
key="study-k8s-advanced"    # Kubernetes advanced
key="study-cicd"            # CI/CD topics
key="study-iac"             # Infrastructure as code
key="study-observability"   # Monitoring/tracing
```

Always include in the content:
- What was covered today
- Exact stopping point
- Any questions X had
- What comes next

---

## PROGRESS CHECK-IN FORMAT

When X hasn't studied in a while and memory shows an active topic:

```
📚 Study check-in

Last session: <topic> — <date from memory>
You covered: <what was covered>
Next up: <what comes next>

Want to continue?
BUTTONS: ▶️ Continue now | 📅 Schedule session | 🔄 Review last topic | ❌ Later
```
