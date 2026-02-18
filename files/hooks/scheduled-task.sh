#!/bin/bash
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/roost/claude}"

TASK="$1"
PROJECT="${2:-$HOME/roost/code/life}"
TASKFILE=$(mktemp /tmp/claude-task-XXXXXX.txt)
printf '%s' "$TASK" > "$TASKFILE"
tmux has-session -t cron 2>/dev/null || tmux new-session -d -s cron
tmux new-window -t cron -n "cron-$(date +%H%M)" \
    "$CLAUDE_CONFIG_DIR/hooks/run-scheduled-task.sh \"$TASKFILE\" \"$PROJECT\""
