#!/bin/bash
# Run a Claude Code task in the current directory. Called by scheduled-task.sh.
source "$(dirname "$0")/_hook-env.sh"

TASKFILE="$1"; PROJECT="$2"
TASK=$(<"$TASKFILE"); rm -f "$TASKFILE"
cd "$PROJECT" || exit 1
if claude -p "$TASK"; then
    ntfy_send -t "Task complete" "${TASK:0:100}"
else
    ntfy_send -t "Task failed" -p "high" "Failed (may need re-auth): ${TASK:0:100}"
fi
