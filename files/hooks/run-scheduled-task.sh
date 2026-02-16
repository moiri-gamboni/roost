#!/bin/bash
TASKFILE="$1"; PROJECT="$2"
TASK=$(<"$TASKFILE"); rm -f "$TASKFILE"
NTFY="http://localhost:2586/claude-$(whoami)"
cd "$PROJECT" || exit 1
if claude -p "$TASK"; then
    curl -s "$NTFY" -H "Title: Task complete" -d "${TASK:0:100}"
else
    curl -s "$NTFY" -H "Title: Task failed" -H "Priority: high" \
        -d "Failed (may need re-auth): ${TASK:0:100}"
fi
