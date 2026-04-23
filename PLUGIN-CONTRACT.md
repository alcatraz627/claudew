# claudew Plugin Contract

## Directory Structure

Each plugin lives in `~/.claude/claudew/plugins/<name>/` where `<name>` uses a
numeric prefix for priority ordering (lower = earlier in the pipeline):

```
plugins/
├── 00-auto-resume/
│   ├── plugin.toml       # REQUIRED — metadata and hook declarations
│   ├── on_exit.sh        # hook script — runs when claude process exits
│   └── on_recover.sh     # hook script — runs when API recovers
├── 10-session-rehydrate/
│   ├── plugin.toml
│   └── pre_spawn.sh
└── ...
```

## plugin.toml Schema

```toml
# REQUIRED fields
name    = "auto-resume"                    # human-readable name (no numeric prefix)
hooks   = ["on_exit", "on_recover"]        # lifecycle phases this plugin subscribes to
enabled = true                             # plugin-level kill switch (host config takes precedence)

# OPTIONAL fields
version     = "1.0.0"                      # semver for tracking
description = "Auto-resume on rate limit"  # shown by `claudew list`
author      = "system"                     # "system" for seed plugins, user name for custom
```

## Lifecycle Phases

| Phase        | When it fires                              | Typical use                          |
| ------------ | ------------------------------------------ | ------------------------------------ |
| `pre_spawn`  | Before `claude` process is started         | Inject context, check preconditions  |
| `post_spawn` | Immediately after `claude` process starts  | Record PID, start timers             |
| `poll`       | Every 30s while `claude` is running        | Budget checks, health monitoring     |
| `on_exit`    | After `claude` process exits (any reason)  | Classify exit, trigger recovery      |
| `on_recover` | When API health check passes after failure | Re-spawn session, send notification  |

## Hook Script Contract

Each hook is a bash script named `<phase>.sh` in the plugin directory.

### Input (stdin)

JSON event blob with these fields:

```json
{
  "ts": "2026-04-23T05:20:00Z",
  "phase": "on_exit",
  "exit_code": 1,
  "stderr_tail": "last 20 lines of stderr...",
  "session_id": "fix-auth-3b",
  "cwd": "/Users/you/project",
  "pid": 12345,
  "retry": 0,
  "class": "rate_limit"
}
```

### Environment Variables

| Variable                   | Description                              |
| -------------------------- | ---------------------------------------- |
| `CLAUDEW_PLUGIN_NAME`     | Plugin directory name (e.g., `00-auto-resume`) |
| `CLAUDEW_PLUGIN_STATE_DIR`| Writable per-plugin state dir            |
| `CLAUDEW_PHASE`           | Current lifecycle phase                  |
| `CLAUDEW_HOME`            | Plugin host root (`~/.claude/claudew`)   |

Plus any keys from `[plugin_override."<name>"]` in config.toml, uppercased
and prefixed with `CLAUDEW_` (e.g., `max_wait_min` → `CLAUDEW_MAX_WAIT_MIN`).

### Output (stdout)

Lines prefixed with `HINT:` are collected by the host and injected into the
next turn's `additionalContext`. All other stdout is discarded.

```bash
echo "HINT: Session was auto-resumed after rate limit (waited 3m42s)"
```

### Exit Code

- `0` — success, continue pipeline
- Non-zero — logged as failure, does NOT halt the host or other plugins

### Timeout

Each hook invocation is killed after `max_plugin_ms` (default 5000ms, set in
config.toml `[host]`). A timeout is logged but does not halt the pipeline.

## State Management

Each plugin gets a writable state directory at:
```
~/.claude/claudew/state/<plugin-name>/
```

Use it for:
- Retry counters, timestamps, session state
- Cache files (e.g., last API check result)
- Any persistent data the plugin needs across invocations

The host creates this directory automatically. Plugins should not write
outside their own state directory.
