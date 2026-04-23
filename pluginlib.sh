#!/usr/bin/env bash
# pluginlib.sh — Plugin runner library for claudew host
#
# Source this from the main claudew script. Provides:
#   load_plugins        — discover and validate plugins from plugins/ dir
#   run_hook_phase      — execute a lifecycle phase across all enabled plugins
#   build_event_json    — build the JSON event blob passed to plugin stdin
#   parse_toml_value    — minimal TOML value reader
#
# Plugin contract:
#   - Each plugin lives in plugins/<name>/ with a plugin.toml
#   - Hook scripts: pre_spawn.sh, post_spawn.sh, poll.sh, on_exit.sh, on_recover.sh
#   - Stdin: JSON event blob
#   - Stdout: lines prefixed HINT: get injected into next turn's additionalContext
#   - Exit 0: continue pipeline; non-zero: halt (logged, does not kill host)
#   - Timeout: configurable per-host (default 5s)

# ─── TOML parser (minimal — handles key = "value" and key = value) ────────

# Parse a single value from a TOML file.
# Usage: parse_toml_value <file> <key> [section]
# Returns the value (stripped of quotes) or empty string.
parse_toml_value() {
    local file="$1" key="$2" section="${3:-}"
    [[ ! -f "$file" ]] && return

    local in_section=true
    [[ -n "$section" ]] && in_section=false

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[([^]]+)\] ]]; then
            if [[ -n "$section" ]]; then
                [[ "${BASH_REMATCH[1]}" == "$section" ]] && in_section=true || in_section=false
            fi
            continue
        fi

        $in_section || continue

        # Key = value
        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            # Strip quotes
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            # Trim trailing whitespace/comments
            val="${val%%#*}"
            val="${val%"${val##*[! ]}"}"
            echo "$val"
            return
        fi
    done < "$file"
}

# Parse a TOML array value like ["a", "b", "c"]
# Returns newline-separated values
parse_toml_array() {
    local file="$1" key="$2" section="${3:-}"
    local raw
    raw=$(parse_toml_value "$file" "$key" "$section")
    [[ -z "$raw" ]] && return

    # Strip brackets
    raw="${raw#\[}"
    raw="${raw%\]}"

    # Split on commas, strip quotes and whitespace
    local IFS=','
    for item in $raw; do
        item="${item## }"
        item="${item%% }"
        item="${item#\"}"
        item="${item%\"}"
        [[ -n "$item" ]] && echo "$item"
    done
}

# ─── Plugin discovery ─────────────────────────────────────────────────────

# Globals populated by load_plugins
declare -a CLAUDEW_PLUGIN_NAMES=()
declare -a CLAUDEW_PLUGIN_DIRS=()
declare -a CLAUDEW_PLUGIN_HOOKS=()

# Load all enabled plugins in priority order.
# Args: $1 = plugins directory, $2 = config.toml path
load_plugins() {
    local plugins_dir="$1" config_file="$2"
    CLAUDEW_PLUGIN_NAMES=()
    CLAUDEW_PLUGIN_DIRS=()
    CLAUDEW_PLUGIN_HOOKS=()

    # Read enabled list from config
    local enabled_list=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && enabled_list+=("$name")
    done < <(parse_toml_array "$config_file" "enabled" "plugins")

    # If no enabled list in config, enable nothing
    [[ ${#enabled_list[@]} -eq 0 ]] && return 0

    # Discover plugin dirs sorted by name (numeric prefix = priority)
    local dir
    for dir in "$plugins_dir"/*/; do
        [[ ! -d "$dir" ]] && continue
        local plugin_name
        plugin_name=$(basename "$dir")
        local toml_file="${dir}plugin.toml"

        # Must have plugin.toml
        if [[ ! -f "$toml_file" ]]; then
            _pluglog "WARN" "Skipping $plugin_name — no plugin.toml"
            continue
        fi

        # Must be in enabled list
        local is_enabled=false
        for en in "${enabled_list[@]}"; do
            [[ "$en" == "$plugin_name" ]] && is_enabled=true && break
        done
        $is_enabled || continue

        # Check plugin-level enabled flag (defaults to true)
        local plugin_enabled
        plugin_enabled=$(parse_toml_value "$toml_file" "enabled")
        [[ "$plugin_enabled" == "false" ]] && continue

        # Read hooks
        local hooks
        hooks=$(parse_toml_value "$toml_file" "hooks")

        CLAUDEW_PLUGIN_NAMES+=("$plugin_name")
        CLAUDEW_PLUGIN_DIRS+=("$dir")
        CLAUDEW_PLUGIN_HOOKS+=("$hooks")
    done

    _pluglog "INFO" "Loaded ${#CLAUDEW_PLUGIN_NAMES[@]} plugin(s): ${CLAUDEW_PLUGIN_NAMES[*]:-none}"
    return 0
}

# ─── Hook execution ───────────────────────────────────────────────────────

# Run a lifecycle phase across all plugins that subscribe to it.
# Args: $1 = phase name (pre_spawn, post_spawn, poll, on_exit, on_recover)
#        $2 = JSON event blob (piped to plugin stdin)
#        $3 = timeout in seconds (default: from CLAUDEW_PLUGIN_TIMEOUT or 5)
# Returns: collected HINT lines in $CLAUDEW_HINTS (newline-separated)
CLAUDEW_HINTS=""

run_hook_phase() {
    local phase="$1" event_json="$2" timeout="${3:-${CLAUDEW_PLUGIN_TIMEOUT:-5}}"
    CLAUDEW_HINTS=""
    local hints=""

    local i
    for i in "${!CLAUDEW_PLUGIN_NAMES[@]}"; do
        local name="${CLAUDEW_PLUGIN_NAMES[$i]}"
        local dir="${CLAUDEW_PLUGIN_DIRS[$i]}"
        local hooks="${CLAUDEW_PLUGIN_HOOKS[$i]}"

        # Check if this plugin subscribes to this phase
        if ! echo "$hooks" | grep -qF "$phase"; then
            continue
        fi

        local script="${dir}${phase}.sh"
        if [[ ! -f "$script" ]]; then
            _pluglog "WARN" "Plugin $name subscribes to $phase but ${phase}.sh not found"
            continue
        fi
        [[ ! -x "$script" ]] && chmod +x "$script"

        _pluglog "RUN" "$name:$phase"

        # Set plugin environment
        local state_dir="${CLAUDEW_STATE_DIR:-$HOME/.claude/claudew/state}/${name}"
        mkdir -p "$state_dir" 2>/dev/null || true

        local plugin_out=""
        local plugin_exit=0

        # Run with bash-native timeout (macOS has no coreutils timeout)
        local _out_file
        _out_file=$(mktemp /tmp/claudew-plug.XXXXXX)

        (
            CLAUDEW_PLUGIN_NAME="$name" \
            CLAUDEW_PLUGIN_STATE_DIR="$state_dir" \
            CLAUDEW_PHASE="$phase" \
            bash "$script" <<< "$event_json" > "$_out_file" 2>/dev/null
        ) &
        local _bg_pid=$!

        # Wait up to $timeout seconds
        local _waited=0
        while kill -0 "$_bg_pid" 2>/dev/null; do
            if [[ $_waited -ge $timeout ]]; then
                kill -9 "$_bg_pid" 2>/dev/null || true
                wait "$_bg_pid" 2>/dev/null || true
                plugin_exit=124
                break
            fi
            sleep 0.5
            _waited=$(( _waited + 1 ))  # ~0.5s granularity, close enough
            [[ $(( _waited % 2 )) -eq 0 ]] || continue
        done
        if [[ $plugin_exit -ne 124 ]]; then
            wait "$_bg_pid" 2>/dev/null || plugin_exit=$?
        fi
        plugin_out=$(cat "$_out_file" 2>/dev/null || true)
        rm -f "$_out_file"

        if [[ $plugin_exit -eq 124 ]]; then
            _pluglog "TIMEOUT" "$name:$phase (killed after ${timeout}s)"
        elif [[ $plugin_exit -ne 0 ]]; then
            _pluglog "FAIL" "$name:$phase exited $plugin_exit"
        fi

        # Collect HINT: lines
        if [[ -n "$plugin_out" ]]; then
            local hint_lines
            hint_lines=$(echo "$plugin_out" | grep '^HINT:' | sed 's/^HINT: *//' || true)
            if [[ -n "$hint_lines" ]]; then
                hints+="${hint_lines}"$'\n'
            fi
        fi
    done

    CLAUDEW_HINTS="${hints%$'\n'}"
}

# ─── Event JSON builder ──────────────────────────────────────────────────

# Build the JSON event blob passed to plugin stdin.
# All args are optional; missing values become empty strings or 0.
build_event_json() {
    local phase="${1:-}" exit_code="${2:-0}" stderr_tail="${3:-}" \
          session_id="${4:-}" cwd="${5:-$(pwd)}" pid="${6:-0}" \
          retry="${7:-0}" classification="${8:-}"

    # Escape strings for JSON (backslash, double-quote, newlines)
    _json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/}"
        s="${s//$'\t'/\\t}"
        echo "$s"
    }

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cat <<ENDJSON
{"ts":"$ts","phase":"$(_json_escape "$phase")","exit_code":$exit_code,"stderr_tail":"$(_json_escape "$stderr_tail")","session_id":"$(_json_escape "$session_id")","cwd":"$(_json_escape "$cwd")","pid":$pid,"retry":$retry,"class":"$(_json_escape "$classification")"}
ENDJSON
}

# ─── Logging ──────────────────────────────────────────────────────────────

_pluglog() {
    local level="$1" msg="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    echo "claudew [$ts] $level: $msg" >&2

    # Also append to daily log
    local log_dir="${CLAUDEW_LOG_DIR:-$HOME/.claude/claudew/logs}"
    local log_file="${log_dir}/$(date '+%Y-%m-%d').log"
    echo "[$ts] $level: $msg" >> "$log_file" 2>/dev/null || true
}
