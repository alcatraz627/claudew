#!/usr/bin/env bash
# 40-recent-dir-context: pre_spawn.sh
#
# Inject recent file changes (last 1h) from git log in CWD as context.

set -euo pipefail

EVENT=$(cat)
CWD=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

[[ -z "$CWD" ]] && exit 0
cd "$CWD" 2>/dev/null || exit 0

# Must be in a git repo
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Get recent changes
RECENT=$(git log --oneline --since="1 hour ago" --no-merges 2>/dev/null || true)
if [[ -z "$RECENT" ]]; then
    exit 0
fi

COUNT=$(echo "$RECENT" | wc -l | tr -d ' ')
FILES=$(git diff --stat HEAD~${COUNT}..HEAD 2>/dev/null | tail -1 || true)

echo "HINT: Recent activity in CWD (last 1h): ${COUNT} commits. ${FILES}"
