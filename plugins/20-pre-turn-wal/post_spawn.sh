#!/usr/bin/env bash
# 20-pre-turn-wal: post_spawn.sh
#
# After claude spawns, write a session_start WAL entry so /catchup
# can find session boundaries.

set -euo pipefail

EVENT=$(cat)
SESSION_ID=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
CWD=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
TS=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")

# Write to project WAL if it exists, otherwise global
WAL=""
for candidate in "${CWD}/.claude/wal.jsonl" "${HOME}/.claude/wal.jsonl"; do
    if [[ -f "$candidate" ]] || [[ -d "$(dirname "$candidate")" ]]; then
        WAL="$candidate"
        break
    fi
done

[[ -z "$WAL" ]] && exit 0

echo "{\"ts\":\"$TS\",\"kind\":\"session_start\",\"session_id\":\"$SESSION_ID\",\"source\":\"claudew\"}" \
    >> "$WAL" 2>/dev/null || true
