#!/bin/bash
# SessionStart hook: give every Claude Code session its own agent-browser.
#
# agent-browser isolates browsers by session name (`--session` or the
# AGENT_BROWSER_SESSION env var, default "default"), so without this every
# session and subagent on the box would drive one shared Chrome and fight over
# its tabs. Claude Code runs the file at $CLAUDE_ENV_FILE as a preamble before
# each Bash command, for the session and its subagents alike, and re-applies it
# on --resume; writing the export there keys the browser on the session id,
# which is also what CLAUDE_CODE_SESSION_ID carries. A session name may only
# contain letters, digits, hyphens and underscores; a UUID qualifies.
#
# The daemon behind each session exits after an hour without commands, so a
# session that ends without `agent-browser close` leaks nothing for long.
#
# SessionStart fires again on /clear, --resume and compaction, against the
# same env file, so the line is only appended when it is not already there.
# Always exits 0: a missing env file (older harness) just leaves the default.
set -uo pipefail
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
sid=$(jq -r '.session_id // empty')
case "$sid" in
    *[!A-Za-z0-9_-]*|"") exit 0 ;;
esac
line="export AGENT_BROWSER_SESSION=$sid"
[ -f "$CLAUDE_ENV_FILE" ] && grep -qxF -- "$line" "$CLAUDE_ENV_FILE" || echo "$line" >> "$CLAUDE_ENV_FILE"
exit 0
