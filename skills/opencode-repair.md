---
name: opencode-repair
description: Fix OpenCode startup failures caused by invalid config by using environment variables instead
capabilities: [opencode, mcp, repair, configuration]
---

# OpenCode Repair Skill

## OVERVIEW

OpenCode MCP server may fail to start if `/root/.config/opencode/opencode.json` has an invalid schema. The schema is not well-documented and prone to errors. The reliable solution is to **remove the config file entirely** and set the provider/model via environment variables in the MCP configuration (`~/.skyclaw/mcp.toml`).

## SYMPTOMS

- OpenCode health endpoint returns 500 or unhealthy
- MCP server shows as `[failed]` in `mcp list`
- Logs show: `Unrecognized keys: providers, defaultProvider, defaultModel`
- `opencode_setup` reports "MCP server 'opencode' is not running"

## REPAIR STEPS

### Step 1 — Remove invalid config
```bash
rm -f /root/.config/opencode/opencode.json
```

### Step 2 — Set environment variables in MCP config

Edit `/root/.skyclaw/mcp.toml` (or the deploy template at `/root/skyclaw-private/deploy/mcp.toml` for persistent fix). Under the `opencode` server block, add:

```toml
env = { OPENCODE_DEFAULT_PROVIDER = "openrouter", OPENCODE_DEFAULT_MODEL = "stepfun/step-3.5-flash:free" }
```

Or replace the model with your preferred one (e.g., `anthropic/claude-sonnet-4-6`).

Full example:
```toml
[[servers]]
name = "opencode"
transport = "stdio"
command = "npx"
args = ["-y", "opencode-mcp@latest"]
env = { OPENCODE_DEFAULT_PROVIDER = "openrouter", OPENCODE_DEFAULT_MODEL = "stepfun/step-3.5-flash:free" }
```

### Step 3 — Restart the OpenCode MCP server
```bash
# Via batabeto tool
mcp_manage(action='restart', name='opencode')

# Or manually
pkill -f "opencode-mcp"
# It will auto-restart via MCP manager
```

### Step 4 — Verify health
```bash
curl -s http://127.0.0.1:4096/global/health
# Should return: {"healthy":true,"version":"1.2.26"}
```

## PREVENTION FOR NEW INSTALLS

The repository's `deploy/mcp.toml` should already contain the `env` line for OpenCode. When deploying via `deploy.sh`, this file is copied to `~/.skyclaw/mcp.toml`, ensuring correct configuration from the start.

Always check that the `opencode` server entry includes the `env` setting before first run.

## NOTES

- The environment variables are passed to the OpenCode server process by the MCP manager
- No separate `opencode.json` config file is needed
- The provider must be one of the configured providers in OpenCode (openrouter, anthropic, etc.)
- The model string must match exactly what the provider expects

## RELATED

- `self-management` skill — for MCP server management
- `deployment` skill — for deploy procedures
