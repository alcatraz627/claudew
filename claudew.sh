#!/usr/bin/env bash
# claudew — claude CLI wrapper with plugin-based lifecycle hooks
#
# Usage: claudew [claude args...]
#        claudew list                — list installed plugins
#        claudew enable  <name>      — enable a plugin
#        claudew disable <name>      — disable a plugin
#        claudew new-plugin <name>   — scaffold a new plugin
#
# Lifecycle:
#   pre_spawn → spawn claude → post_spawn → poll (every 30s) → on_exit
#   If a plugin requests recovery → on_recover → loop back to spawn
#
# Plugins live in ~/.claude/claudew/plugins/<name>/.
# See ~/.claude/claudew/PLUGIN-CONTRACT.md for the full contract.

set -euo pipefail

CLAUDEW_HOME="${HOME}/.claude/claudew"
CLAUDEW_CONFIG="${CLAUDEW_HOME}/config.toml"
CLAUDEW_LOG_DIR="${CLAUDEW_HOME}/logs"
CLAUDEW_STATE_DIR="${CLAUDEW_HOME}/state"
CLAUDEW_PLUGINS_DIR="${CLAUDEW_HOME}/plugins"

export CLAUDEW_HOME CLAUDEW_LOG_DIR CLAUDEW_STATE_DIR

mkdir -p "$CLAUDEW_LOG_DIR" "$CLAUDEW_STATE_DIR"

# Source the plugin runner library
source "${CLAUDEW_HOME}/pluginlib.sh"

# ─── CLI subcommands ─────────────────────────────────────────────────────

_cmd_list() {
    echo "claudew plugins:"
    echo ""
    local enabled_list=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && enabled_list+=("$name")
    done < <(parse_toml_array "$CLAUDEW_CONFIG" "enabled" "plugins")

    for dir in "$CLAUDEW_PLUGINS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name toml_file pname desc enabled hooks
        name=$(basename "$dir")
        toml_file="${dir}plugin.toml"
        [[ ! -f "$toml_file" ]] && continue

        pname=$(parse_toml_value "$toml_file" "name")
        desc=$(parse_toml_value "$toml_file" "description")
        hooks=$(parse_toml_value "$toml_file" "hooks")
        enabled="disabled"
        for en in "${enabled_list[@]}"; do
            [[ "$en" == "$name" ]] && enabled="enabled" && break
        done

        local marker="  "
        [[ "$enabled" == "enabled" ]] && marker="✓ "

        printf "  %s%-28s %s\n" "$marker" "$name" "${desc:-no description}"
        printf "    hooks: %s\n" "${hooks:-none}"
        echo ""
    done
}

_cmd_enable() {
    local target="$1"
    if [[ ! -d "$CLAUDEW_PLUGINS_DIR/$target" ]]; then
        echo "claudew: plugin '$target' not found in $CLAUDEW_PLUGINS_DIR/" >&2
        exit 1
    fi
    local current
    current=$(parse_toml_value "$CLAUDEW_CONFIG" "enabled" "plugins")
    if echo "$current" | grep -qF "$target"; then
        echo "claudew: '$target' is already enabled." >&2
        return 0
    fi
    # Append to enabled list — rewrite the line
    local new_list
    if [[ -z "$current" || "$current" == "[]" ]]; then
        new_list="[\"$target\"]"
    else
        # Strip trailing ] and add new entry
        new_list="${current%]}, \"$target\"]"
    fi
    # Use sed to replace the enabled line
    sed -i '' "s|^enabled = .*|enabled = $new_list|" "$CLAUDEW_CONFIG"
    echo "claudew: Enabled '$target'."
}

_cmd_disable() {
    local target="$1"
    # Remove from the enabled array in config.toml
    # Read current, filter out target, rewrite
    local items=()
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$target" ]] && items+=("$name")
    done < <(parse_toml_array "$CLAUDEW_CONFIG" "enabled" "plugins")

    local new_list="["
    local first=true
    for item in "${items[@]}"; do
        $first || new_list+=", "
        new_list+="\"$item\""
        first=false
    done
    new_list+="]"

    sed -i '' "s|^enabled = .*|enabled = $new_list|" "$CLAUDEW_CONFIG"
    echo "claudew: Disabled '$target'."
}

_cmd_new_plugin() {
    local name="$1"
    local plugin_dir="${CLAUDEW_PLUGINS_DIR}/${name}"
    if [[ -d "$plugin_dir" ]]; then
        echo "claudew: Plugin '$name' already exists at $plugin_dir" >&2
        exit 1
    fi
    mkdir -p "$plugin_dir"

    # Strip numeric prefix for human-readable name
    local human_name
    human_name=$(echo "$name" | sed 's/^[0-9]*-//')

    cat > "${plugin_dir}/plugin.toml" << TOML
name        = "$human_name"
hooks       = ["on_exit"]
enabled     = true
version     = "0.1.0"
description = "Custom plugin: $human_name"
author      = "user"
TOML

    cat > "${plugin_dir}/on_exit.sh" << 'HOOKSH'
#!/usr/bin/env bash
# on_exit.sh — runs when the claude process exits
#
# Stdin:  JSON event blob (phase, exit_code, stderr_tail, session_id, cwd, pid, retry, class)
# Stdout: Lines prefixed with "HINT:" are injected as additionalContext
# Exit 0: continue pipeline

EVENT=$(cat)
EXIT_CODE=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',0))" 2>/dev/null || echo "0")

echo "HINT: Custom plugin saw exit code $EXIT_CODE"
HOOKSH

    chmod +x "${plugin_dir}/on_exit.sh"
    echo "claudew: Scaffolded plugin at $plugin_dir"
    echo "  Edit plugin.toml to configure hooks, then run: claudew enable $name"
}

# Route subcommands
if [[ ${1:-} == "list" ]]; then _cmd_list; exit 0; fi
if [[ ${1:-} == "enable" ]]; then _cmd_enable "${2:?Usage: claudew enable <name>}"; exit 0; fi
if [[ ${1:-} == "disable" ]]; then _cmd_disable "${2:?Usage: claudew disable <name>}"; exit 0; fi
if [[ ${1:-} == "new-plugin" ]]; then _cmd_new_plugin "${2:?Usage: claudew new-plugin <name>}"; exit 0; fi

# ─── Host helpers ────────────────────────────────────────────────────────

# Rate-limit / transient error strings to detect
RATELIMIT_PATTERNS=(
    "You've hit your limit"
    "rate_limit_error"
    "overloaded_error"
    "API quota"
    "429"
    "usage limit"
)
API_ERROR_PATTERNS=(
    "500"
    "502"
    "503"
    "timeout"
    "ECONNRESET"
    "ECONNREFUSED"
    "socket hang up"
)

is_rate_limited() {
    local output="$1"
    for pattern in "${RATELIMIT_PATTERNS[@]}"; do
        echo "$output" | grep -qiF "$pattern" && return 0
    done
    return 1
}

is_api_error() {
    local output="$1"
    for pattern in "${API_ERROR_PATTERNS[@]}"; do
        echo "$output" | grep -qiF "$pattern" && return 0
    done
    return 1
}

classify_exit() {
    local exit_code="$1" output="$2"
    if [[ $exit_code -eq 0 ]]; then echo "OK"; return; fi
    if [[ $exit_code -eq 130 ]]; then echo "USER_QUIT"; return; fi
    if is_rate_limited "$output"; then echo "RATE_LIMIT"; return; fi
    if is_api_error "$output"; then echo "API_ERROR"; return; fi
    echo "CRASH"
}

notify() {
    local title="$1" message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null &
}

get_session_id() {
    local state_json="${HOME}/.claude/subconscious/state.json"
    if [[ -f "$state_json" ]]; then
        local sid
        sid=$(python3 -c "import json,sys; d=json.load(open('$state_json')); print(d.get('session_id',''))" 2>/dev/null || true)
        [[ -n "$sid" ]] && echo "$sid" && return
    fi
    local last_session="${CLAUDEW_HOME}/last-session"
    if [[ -f "$last_session" ]]; then
        cat "$last_session"
        return
    fi
    echo ""
}

save_session_id() {
    local output="$1"
    local sid
    sid=$(echo "$output" | grep -oE 'Session ID: [a-zA-Z0-9_-]+' | awk '{print $3}' | head -1 || true)
    if [[ -n "$sid" ]]; then
        echo "$sid" > "${CLAUDEW_HOME}/last-session"
    fi
}

# ─── Main lifecycle loop ────────────────────────────────────────────────

main() {
    local original_args=("$@")
    local tmpfile
    tmpfile=$(mktemp /tmp/claudew-output.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" EXIT

    # Check for --print mode
    local print_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--print" ]] && print_mode=true && break
    done

    # Read host config
    local plugin_timeout
    plugin_timeout=$(parse_toml_value "$CLAUDEW_CONFIG" "max_plugin_ms" "host")
    plugin_timeout=$(( ${plugin_timeout:-5000} / 1000 ))  # convert ms → seconds
    export CLAUDEW_PLUGIN_TIMEOUT="$plugin_timeout"

    # Load plugins
    load_plugins "$CLAUDEW_PLUGINS_DIR" "$CLAUDEW_CONFIG"

    local exit_code=0
    local retry=0
    local max_retries=3
    local session_id=""

    while true; do
        # ── PRE_SPAWN ──
        local event_json
        event_json=$(build_event_json "pre_spawn" 0 "" "$session_id" "$(pwd)" 0 "$retry")
        run_hook_phase "pre_spawn" "$event_json" "$plugin_timeout"
        local pre_hints="$CLAUDEW_HINTS"

        # ── SPAWN ──
        set +e
        claude "$@" 2>&1 | tee "$tmpfile"
        exit_code=${PIPESTATUS[0]}
        set -e

        local output
        output=$(cat "$tmpfile")
        local child_pid=$$  # approximate — the real child is gone

        # Save session ID if present
        save_session_id "$output"
        session_id=$(get_session_id)

        # ── POST_SPAWN ──
        event_json=$(build_event_json "post_spawn" "$exit_code" "" "$session_id" "$(pwd)" "$child_pid" "$retry")
        run_hook_phase "post_spawn" "$event_json" "$plugin_timeout"

        # Classify exit
        local stderr_tail
        stderr_tail=$(tail -20 "$tmpfile" 2>/dev/null || true)
        local class
        class=$(classify_exit "$exit_code" "$output")

        # ── ON_EXIT ──
        event_json=$(build_event_json "on_exit" "$exit_code" "$stderr_tail" "$session_id" "$(pwd)" "$child_pid" "$retry" "$class")
        run_hook_phase "on_exit" "$event_json" "$plugin_timeout"
        local exit_hints="$CLAUDEW_HINTS"

        # Log event
        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        printf '%s\n' "{\"ts\":\"$ts\",\"event\":\"exit\",\"class\":\"$class\",\"exit_code\":$exit_code,\"retry\":$retry,\"hints\":\"$(echo "$exit_hints" | head -1)\"}" \
            >> "${CLAUDEW_HOME}/events.jsonl" 2>/dev/null || true

        # Handle exit classification
        case "$class" in
            OK)        exit 0 ;;
            USER_QUIT) exit 130 ;;
            CRASH)
                echo "claudew: Non-transient failure (exit $exit_code). Not retrying." >&2
                exit "$exit_code"
                ;;
        esac

        # RATE_LIMIT or API_ERROR — check retry budget
        retry=$((retry + 1))
        if [[ $retry -ge $max_retries ]]; then
            echo "claudew: Max retries ($max_retries) reached. Giving up." >&2
            exit "$exit_code"
        fi

        # ── RECOVERY (built-in — 00-auto-resume enhances via hints) ──
        local reset_info max_wait_secs poll_interval
        reset_info=$(echo "$output" | grep -oE 'resets [0-9]+:[0-9]+(am|pm)( \([A-Z]+\))?' | head -1 || true)
        max_wait_secs=$((2 * 60 * 60))
        poll_interval=60

        # Read per-plugin overrides for auto-resume if configured
        local cfg_max_wait cfg_poll
        cfg_max_wait=$(parse_toml_value "$CLAUDEW_CONFIG" "max_wait_min" 'plugin_override."00-auto-resume"')
        cfg_poll=$(parse_toml_value "$CLAUDEW_CONFIG" "poll_sec" 'plugin_override."00-auto-resume"')
        [[ -n "$cfg_max_wait" ]] && max_wait_secs=$((cfg_max_wait * 60))
        [[ -n "$cfg_poll" ]] && poll_interval="$cfg_poll"

        notify "claudew" "Paused — ${class}. Waiting for API recovery..."
        echo "claudew: ${class}. Polling (every ${poll_interval}s, max ${max_wait_secs}s)..." >&2
        [[ -n "$reset_info" ]] && echo "claudew: $reset_info" >&2

        local attempt=0 total_waited=0 interval="$poll_interval"
        local recovered=false
        while [[ $total_waited -lt $max_wait_secs ]]; do
            sleep "$interval"
            total_waited=$((total_waited + interval))
            attempt=$((attempt + 1))
            echo "claudew: Checking API (attempt ${attempt}, waited ${total_waited}s)..." >&2

            local probe_out
            probe_out=$(claude --print "ping" 2>&1 || true)
            if ! is_rate_limited "$probe_out" && ! is_api_error "$probe_out"; then
                echo "claudew: API available (after ${total_waited}s)." >&2
                notify "claudew" "API recovered! Resuming session..."
                recovered=true
                break
            fi
            echo "claudew: Still unavailable..." >&2

            # Exponential backoff: capped at 300s
            interval=$((interval * 2))
            [[ $interval -gt 300 ]] && interval=300
        done

        if ! $recovered; then
            echo "claudew: Max wait (${max_wait_secs}s) reached. Giving up." >&2
            notify "claudew" "Gave up — API did not recover."
            exit "$exit_code"
        fi

        # ── ON_RECOVER ──
        event_json=$(build_event_json "on_recover" 0 "" "$session_id" "$(pwd)" 0 "$retry" "$class")
        run_hook_phase "on_recover" "$event_json" "$plugin_timeout"
        local recover_hints="$CLAUDEW_HINTS"

        # Attempt session resume
        if [[ "$print_mode" == "true" ]]; then
            echo "claudew: Re-running original command (attempt $retry)..." >&2
        else
            if [[ -n "$session_id" ]]; then
                echo "claudew: Resuming session ${session_id}..." >&2
                local resume_context="[auto-resume @ ${ts}] Previous turn interrupted by ${class}. Continue where you left off."
                # Append any plugin hints to the resume prompt
                if [[ -n "$recover_hints" ]]; then
                    resume_context+=$'\n'"Plugin context: ${recover_hints}"
                fi
                set +e
                claude --resume "$session_id" --print "$resume_context"
                exit_code=$?
                set -e
                if [[ $exit_code -eq 0 ]]; then exit 0; fi
                # Resume failed — fall through to retry original command
            else
                echo "claudew: No session ID found. Re-running original command (attempt $retry)..." >&2
            fi
        fi

        # Reset args for next loop iteration
        set -- "${original_args[@]}"
    done
}

main "$@"
