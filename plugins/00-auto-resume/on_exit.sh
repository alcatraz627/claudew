#!/usr/bin/env bash
# 00-auto-resume: on_exit.sh
#
# Runs when claude exits. Logs the exit classification and emits
# a HINT line so the next turn (or resume prompt) has context about
# what happened.

set -euo pipefail

EVENT=$(cat)
STATE_DIR="${CLAUDEW_PLUGIN_STATE_DIR:-.}"

# Parse event fields
EXIT_CODE=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',0))" 2>/dev/null || echo "0")
CLASS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('class',''))" 2>/dev/null || echo "")
RETRY=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('retry',0))" 2>/dev/null || echo "0")
SESSION_ID=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
TS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")

# Record exit in plugin state
mkdir -p "$STATE_DIR"
echo "{\"ts\":\"$TS\",\"exit_code\":$EXIT_CODE,\"class\":\"$CLASS\",\"retry\":$RETRY,\"session_id\":\"$SESSION_ID\"}" \
    >> "$STATE_DIR/exits.jsonl" 2>/dev/null || true

# Emit hints based on classification
case "$CLASS" in
    RATE_LIMIT)
        echo "HINT: Session exited due to rate limit (exit $EXIT_CODE). Auto-resume will poll for API recovery."
        ;;
    API_ERROR)
        echo "HINT: Session exited due to API error (exit $EXIT_CODE, retry $RETRY). Transient — will retry."
        ;;
    CRASH)
        echo "HINT: Session crashed (exit $EXIT_CODE). Not a transient error — manual intervention may be needed."
        ;;
    USER_QUIT)
        # No hint needed for intentional exits
        ;;
    OK)
        # No hint needed for clean exits
        ;;
esac
