#!/usr/bin/env bash
# 00-auto-resume: on_recover.sh
#
# Runs after the API health check passes and before the session is
# resumed. Emits context about the recovery for the resumed session.

set -euo pipefail

EVENT=$(cat)
STATE_DIR="${CLAUDEW_PLUGIN_STATE_DIR:-.}"

# Parse event
CLASS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('class',''))" 2>/dev/null || echo "")
RETRY=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('retry',0))" 2>/dev/null || echo "0")
TS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")

# Read last exit record to calculate downtime
LAST_EXIT_TS=""
if [[ -f "$STATE_DIR/exits.jsonl" ]]; then
    LAST_EXIT_TS=$(tail -1 "$STATE_DIR/exits.jsonl" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || true)
fi

# Emit recovery context
echo "HINT: API recovered after $CLASS. This is auto-resume attempt $RETRY."
if [[ -n "$LAST_EXIT_TS" ]]; then
    echo "HINT: Previous exit was at $LAST_EXIT_TS. Check WAL for what was in progress."
fi
