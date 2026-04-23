#!/usr/bin/env bash
# 10-session-rehydrate: pre_spawn.sh
#
# Before claude spawns, reads the last WAL checkpoint and emits it as
# a HINT so the new session starts with prior context awareness.

set -euo pipefail

EVENT=$(cat)
CWD=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

# Look for WAL in the target CWD first, then global
WAL_JSONL=""
for candidate in "${CWD}/.claude/wal.jsonl" "${HOME}/.claude/wal.jsonl"; do
    if [[ -f "$candidate" ]]; then
        WAL_JSONL="$candidate"
        break
    fi
done

if [[ -z "$WAL_JSONL" ]]; then
    # Try markdown WAL fallback
    for candidate in "${CWD}/.claude/wal.md" "${HOME}/.claude/wal.md"; do
        if [[ -f "$candidate" ]]; then
            # Extract last session header + a few lines
            local_context=$(tail -30 "$candidate" | head -20)
            if [[ -n "$local_context" ]]; then
                echo "HINT: Prior session context (from WAL): $(echo "$local_context" | head -5 | tr '\n' ' ')"
            fi
            exit 0
        fi
    done
    exit 0
fi

# Extract last checkpoint from JSONL WAL
LAST_CHECKPOINT=$(grep '"checkpoint"' "$WAL_JSONL" 2>/dev/null | tail -1 || true)
if [[ -z "$LAST_CHECKPOINT" ]]; then
    exit 0
fi

# Extract goal and current fields
GOAL=$(echo "$LAST_CHECKPOINT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('goal','unknown'))" 2>/dev/null || echo "")
CURRENT=$(echo "$LAST_CHECKPOINT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current',''))" 2>/dev/null || echo "")
SESSION=$(echo "$LAST_CHECKPOINT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo "")

if [[ -n "$GOAL" ]]; then
    echo "HINT: Prior session (${SESSION}): goal was '${GOAL}'."
fi
if [[ -n "$CURRENT" ]]; then
    echo "HINT: Last checkpoint: ${CURRENT}"
fi
