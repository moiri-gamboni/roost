#!/bin/bash
source "$(dirname "$0")/../lib/_hook-env.sh"

# Read stdin in this shell: hook_input caches it in variables, which a first
# call inside $(...) would set only in that subshell.
hook_input >/dev/null
MESSAGE=$(hook_json '.message // "Input needed"')
SID=$(hook_json '.session_id')

rate_limit_ok || exit 0

# What the prompt asks, left by permission-summary.sh as the prompt opened; the payload's own
# message names no tool. A file older than two minutes belongs to a prompt that was answered
# before this notification could fire.
if [ -n "$SID" ]; then
    SUMMARY_NAME="perm-summary-$SID"
    if [ -n "$(find "$HOOK_RUNTIME_DIR" -maxdepth 1 -name "$SUMMARY_NAME" -newermt '2 minutes ago')" ]; then
        SUMMARY=$(<"$HOOK_RUNTIME_DIR/$SUMMARY_NAME")
        [ -n "$SUMMARY" ] && MESSAGE=$SUMMARY
    fi
    rm -f "$HOOK_RUNTIME_DIR/$SUMMARY_NAME"
fi

# The session's title (/rename or the auto-title), which is how the session is
# known in tmux and ListAgents; the directory name until the session has one.
TITLE=""
[ -n "$SID" ] && TITLE=$(CLAUDE_CODE_SESSION_ID=$SID session whoami --name)

ntfy_send -t "${TITLE:-$(basename "$PWD")}" "$MESSAGE"
