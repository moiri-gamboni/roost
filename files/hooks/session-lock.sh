#!/bin/bash
source "$(dirname "$0")/_hook-env.sh"

SESSION_ID=$(hook_json '.session_id')
[ -z "$SESSION_ID" ] && exit 0

LOCKDIR="$CLAUDE_CONFIG_DIR/locks"
mkdir -p "$LOCKDIR"
LOCKFILE="$LOCKDIR/${SESSION_ID}.lock"

# Write lock metadata to temp file first, then atomic replace
TMPLOCK=$(mktemp "$LOCKDIR/.lock-XXXXXX")

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
    > "$TMPLOCK"

# Warn if lock exists from another machine (best-effort, read before atomic replace)
if [ -f "$LOCKFILE" ]; then
    OWNER=$(jq -r '.hostname // empty' "$LOCKFILE" 2>/dev/null)
    [ -n "$OWNER" ] && [ "$OWNER" != "$(hostname)" ] && \
        echo "WARNING: Session may be active on $OWNER. Use aichat search for safe handoff."
fi

# Atomic replace (same filesystem guarantees rename(2))
mv "$TMPLOCK" "$LOCKFILE"
