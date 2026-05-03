#!/bin/bash

TASK="$1"
PROJECT="${2:-$HOME/${ROOST_DIR_NAME}/code/life}"
TASKFILE=$(mktemp /tmp/claude-task-XXXXXX.txt)
printf '%s' "$TASK" > "$TASKFILE"
WIN="cron-$(date +%H%M)"
CMD="$CLAUDE_CONFIG_DIR/hooks/run-scheduled-task.sh \"$TASKFILE\" \"$PROJECT\""
# Create the session WITH the task window directly. `new-session -d -s cron`
# alone would attach a default `bash` window, which persists after the task
# window exits — leaving an idle cron session forever (visible at the top of
# `agents`/choose-window). Creating the session via `new-session -n WIN CMD`
# ties the session's only window to the task; when the task ends and the
# window closes, the session is destroyed automatically.
if tmux has-session -t cron 2>/dev/null; then
    tmux new-window -t cron -n "$WIN" "$CMD"
else
    tmux new-session -d -s cron -n "$WIN" "$CMD"
fi
