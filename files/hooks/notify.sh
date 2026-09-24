#!/bin/bash
source "$(dirname "$0")/../lib/_hook-env.sh"

# Read stdin in this shell: hook_input caches it in variables, which a first
# call inside $(...) would set only in that subshell.
hook_input >/dev/null
MESSAGE=$(hook_json '.message // "Input needed"')
SID=$(hook_json '.session_id')

rate_limit_ok || exit 0

# The session's title (/rename or the auto-title), which is how the session is
# known in tmux and ListAgents; the directory name until the session has one.
TITLE=""
[ -n "$SID" ] && TITLE=$(CLAUDE_CODE_SESSION_ID=$SID session whoami --name)

ntfy_send -t "${TITLE:-$(basename "$PWD")}" "$MESSAGE"
