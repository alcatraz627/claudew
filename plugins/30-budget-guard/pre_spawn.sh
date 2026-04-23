#!/usr/bin/env bash
# 30-budget-guard: pre_spawn.sh
#
# Before spawn, check rate limit budget from the widget cache file.
# Warn if 5h usage is high; optionally block if at 100%.

set -euo pipefail

EVENT=$(cat)
LIMITS_FILE="${HOME}/.claude/widgets/.limits.json"

if [[ ! -f "$LIMITS_FILE" ]]; then
    exit 0
fi

# Read 5h percentage
PCT_5H=$(python3 -c "import json; d=json.load(open('$LIMITS_FILE')); print(d.get('5h',{}).get('pct',0))" 2>/dev/null || echo "0")

if [[ "$PCT_5H" -ge 95 ]]; then
    echo "HINT: WARNING — 5h rate limit at ${PCT_5H}%. Session may be interrupted by rate limiting."
elif [[ "$PCT_5H" -ge 80 ]]; then
    echo "HINT: Rate limit usage at ${PCT_5H}% of 5h window. Consider shorter prompts."
fi
