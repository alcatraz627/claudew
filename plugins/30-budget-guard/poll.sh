#!/usr/bin/env bash
# 30-budget-guard: poll.sh
#
# Periodically check rate limit budget while claude is running.
# Emit warnings as HINT lines.

set -euo pipefail

EVENT=$(cat)
LIMITS_FILE="${HOME}/.claude/widgets/.limits.json"
STATE_DIR="${CLAUDEW_PLUGIN_STATE_DIR:-.}"

if [[ ! -f "$LIMITS_FILE" ]]; then
    exit 0
fi

PCT_5H=$(python3 -c "import json; d=json.load(open('$LIMITS_FILE')); print(d.get('5h',{}).get('pct',0))" 2>/dev/null || echo "0")

# Only warn once per threshold crossing — use state file to track
LAST_WARN_FILE="${STATE_DIR}/last-warn-pct"
LAST_WARN=$(cat "$LAST_WARN_FILE" 2>/dev/null || echo "0")

if [[ "$PCT_5H" -ge 95 && "$LAST_WARN" -lt 95 ]]; then
    echo "HINT: CRITICAL — 5h rate limit at ${PCT_5H}%. Imminent rate limiting."
    echo "95" > "$LAST_WARN_FILE"
elif [[ "$PCT_5H" -ge 80 && "$LAST_WARN" -lt 80 ]]; then
    echo "HINT: Rate limit at ${PCT_5H}% of 5h window."
    echo "80" > "$LAST_WARN_FILE"
fi
