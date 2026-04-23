#!/usr/bin/env bash
# 20-pre-turn-wal: on_exit.sh
#
# When claude exits, write a session_end WAL entry.

set -euo pipefail

EVENT=$(cat)
SESSION_ID=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
CWD=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
EXIT_CODE=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',0))" 2>/dev/null || echo "0")
CLASS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('class',''))" 2>/dev/null || echo "")
TS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")

# Find WAL
WAL=""
for candidate in "${CWD}/.claude/wal.jsonl" "${HOME}/.claude/wal.jsonl"; do
    if [[ -f "$candidate" ]]; then
        WAL="$candidate"
        break
    fi
done

[[ -z "$WAL" ]] && exit 0

echo "{\"ts\":\"$TS\",\"kind\":\"session_end\",\"session_id\":\"$SESSION_ID\",\"exit_code\":$EXIT_CODE,\"class\":\"$CLASS\",\"source\":\"claudew\"}" \
    >> "$WAL" 2>/dev/null || true
