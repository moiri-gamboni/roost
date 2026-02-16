#!/bin/bash
TASK="$1"
PROJECT="${2:-$HOME/agents/life}"
TASKFILE=$(mktemp /tmp/claude-task-XXXXXX.txt)
printf '%s' "$TASK" > "$TASKFILE"
tmux has-session -t cron 2>/dev/null || tmux new-session -d -s cron
tmux new-window -t cron -n "cron-$(date +%H%M)" \
    "$HOME/.claude/hooks/run-scheduled-task.sh '$TASKFILE' '$PROJECT'"
