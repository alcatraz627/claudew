#!/usr/bin/env bash
# 50-post-turn-diff: on_exit.sh
#
# After claude exits, run git diff --stat and write a one-line summary.

set -euo pipefail

EVENT=$(cat)
CWD=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
TS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")

[[ -z "$CWD" ]] && exit 0
cd "$CWD" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Get uncommitted changes summary
DIFF_STAT=$(git diff --stat 2>/dev/null | tail -1 || true)
STAGED_STAT=$(git diff --cached --stat 2>/dev/null | tail -1 || true)

SUMMARY=""
[[ -n "$DIFF_STAT" ]] && SUMMARY="unstaged: $DIFF_STAT"
[[ -n "$STAGED_STAT" ]] && SUMMARY="${SUMMARY:+$SUMMARY; }staged: $STAGED_STAT"

if [[ -n "$SUMMARY" ]]; then
    echo "HINT: Post-session diff: $SUMMARY"

    # Also append to WAL if available
    for candidate in "${CWD}/.claude/wal.jsonl" "${HOME}/.claude/wal.jsonl"; do
        if [[ -f "$candidate" ]]; then
            echo "{\"ts\":\"$TS\",\"kind\":\"action\",\"session_id\":\"$SESSION_ID\",\"body\":\"post-turn-diff: $SUMMARY\",\"source\":\"claudew\"}" \
                >> "$candidate" 2>/dev/null || true
            break
        fi
    done
fi
