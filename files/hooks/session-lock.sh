#!/bin/bash
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0

mkdir -p ~/.claude/locks
LOCKFILE="$HOME/.claude/locks/${SESSION_ID}.lock"

# Warn if lock exists from another machine
if [ -f "$LOCKFILE" ]; then
    OWNER=$(jq -r '.hostname // empty' "$LOCKFILE")
    [ -n "$OWNER" ] && [ "$OWNER" != "$(hostname)" ] && \
        echo "WARNING: Session may be active on $OWNER. Use aichat search for safe handoff."
fi

jq -n \
    --arg hostname "$(hostname)" \
    --arg tmux_session "$(tmux display-message -p '#S' 2>/dev/null || echo '')" \
    --arg tmux_window "$(tmux display-message -p '#I' 2>/dev/null || echo '')" \
    --arg tmux_pane "$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo '')" \
    --arg pid "$PPID" \
    --arg cwd "$PWD" \
    --arg started "$(date -Iseconds)" \
    '{hostname: $hostname, tmux_session: $tmux_session, tmux_window: $tmux_window,
      tmux_pane: $tmux_pane, pid: ($pid | tonumber), cwd: $cwd, started: $started}' \
    > "$LOCKFILE"
