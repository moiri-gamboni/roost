#!/bin/bash
# Run a Claude Code task in the current directory. Called by scheduled-task.sh.
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/_hook-env.sh"

TASKFILE="$1"; PROJECT="$2"
TASK=$(<"$TASKFILE"); rm -f "$TASKFILE"
cd "$PROJECT" || exit 1

logger -t "$_HOOK_TAG" "Starting task in $PROJECT: ${TASK:0:100}"
if claude -p "$TASK" 2>&1 | tee >(logger -t "$_HOOK_TAG"); then
    logger -t "$_HOOK_TAG" "Task succeeded: ${TASK:0:100}"
    ntfy_send -t "Task complete" "${TASK:0:100}"
else
    logger -t "$_HOOK_TAG" -p user.err "Task failed: ${TASK:0:100}"
    ntfy_send -t "Task failed" -p "high" "Failed (may need re-auth): ${TASK:0:100}"
fi
